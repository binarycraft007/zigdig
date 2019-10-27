// DNS protocol helpers, e.g starting a socket.
const std = @import("std");
const net = std.net;
const os = std.os;
const io = std.io;

const Allocator = std.mem.Allocator;

const packet = @import("packet.zig");
const resolv = @import("resolvconf.zig");
const main = @import("main.zig");
const DNSPacket = packet.DNSPacket;
const DNSHeader = packet.DNSHeader;

const DNSError = error{NetError};
const OutError = io.SliceOutStream.Error;
const InError = io.SliceInStream.Error;

/// Returns the socket file descriptor for an UDP socket.
pub fn openDNSSocket(addr: *net.Address) !i32 {
    var sockfd = try os.socket(
        os.AF_INET,
        os.SOCK_DGRAM,
        os.PROTO_udp,
    );

    if (std.event.Loop.instance) |_| {
        try os.connect_async(sockfd, &addr.os_addr, @sizeOf(os.sockaddr));
    } else {
        try os.connect(sockfd, &addr.os_addr, @sizeOf(os.sockaddr));
    }
    return sockfd;
}

pub fn sendDNSPacket(sockfd: i32, pkt: DNSPacket, buffer: []u8) !void {
    var out = io.SliceOutStream.init(buffer);
    var out_stream = &out.stream;
    var serializer = io.Serializer(.Big, .Bit, OutError).init(out_stream);

    try serializer.serialize(pkt);
    try serializer.flush();

    try os.write(sockfd, buffer);
}

fn base64Encode(data: []u8) void {
    var b64_buf: [0x100000]u8 = undefined;
    var encoded = b64_buf[0..std.base64.Base64Encoder.calcSize(data.len)];
    std.base64.standard_encoder.encode(encoded, data);
    std.debug.warn("b64 encoded: '{}'\n", encoded);
}

pub fn recvDNSPacket(sockfd: i32, allocator: *Allocator) !DNSPacket {
    var buffer = try allocator.alloc(u8, 512);
    var byte_count = try os.read(sockfd, buffer);
    if (byte_count == 0) return DNSError.NetError;

    var packet_slice = buffer[0..byte_count];
    var pkt = DNSPacket.init(allocator, packet_slice);

    //std.debug.warn("recv {} bytes for packet\n", byte_count);
    //base64Encode(packet_slice);

    var in = io.SliceInStream.init(packet_slice);
    var in_stream = &in.stream;
    var deserializer = io.Deserializer(.Big, .Bit, InError).init(in_stream);

    try deserializer.deserializeInto(&pkt);
    return pkt;
}

test "fake socket open/close" {
    var ip4addr = try std.net.parseIp4("127.0.0.1");
    var addr = std.net.Address.initIp4(ip4addr, 53);
    var sockfd = try openDNSSocket(&addr);
    defer os.close(sockfd);
}

test "fake socket open/close (ip6)" {
    var ip6addr = try std.net.parseIp6("0:0:0:0:0:0:0:1");
    var addr = std.net.Address.initIp6(&ip6addr, 53);

    //var sockfd = try openDNSSocket(&addr);
    //defer os.close(sockfd);
}

pub const AddressArrayList = std.ArrayList(std.net.Address);

pub const AddressList = struct {
    addrs: AddressArrayList,
    canon_name: ?[]u8,

    pub fn deinit(self: *@This()) void {
        self.addrs.deinit();
    }
};

pub fn getAddressList(allocator: *std.mem.Allocator, name: []const u8, port: u16) !*AddressList {
    var result = try allocator.create(AddressList);
    result.* = AddressList{
        .addrs = AddressArrayList.init(allocator),
        .canon_name = null,
    };

    var nameservers = try resolv.readNameservers(allocator);
    var fds = std.ArrayList(os.fd_t).init(allocator);
    for (nameservers.toSlice()) |nameserver| {
        var ns_addr = blk: {
            var addr: std.net.Address = undefined;
            var is_ipv4 = false;

            var ip4addr = std.net.parseIp4(nameserver) catch |err| {
                var ip6addr = try std.net.parseIp6(nameserver);
                addr = std.net.Address.initIp6(ip6addr, 53);
                break :blk addr;
            };

            addr = std.net.Address.initIp4(ip4addr, 53);
            break :blk addr;
        };

        var fd = try openDNSSocket(&ns_addr);
        try fds.append(fd);
    }

    std.debug.warn("nameserver fds:");
    for (fds.toSlice()) |fd| {
        std.debug.warn("{}, ", fd);
    }
    std.debug.warn("\n");

    var packet_a = try main.makeDNSPacket(allocator, name, "A");
    var packet_aaaa = try main.makeDNSPacket(allocator, name, "AAAA");

    var buf_a = try allocator.alloc(u8, packet_a.size());
    var buf_aaaa = try allocator.alloc(u8, packet_aaaa.size());

    for (fds.toSlice()) |fd| {
        try sendDNSPacket(fd, packet_a, buf_a);
        try sendDNSPacket(fd, packet_aaaa, buf_aaaa);
    }

    // TODO poll for response

    return result;
}
