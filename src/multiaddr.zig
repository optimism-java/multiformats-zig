const std = @import("std");
const testing = std.testing;
const uvarint = @import("unsigned_varint.zig");

pub const Error = error{
    DataLessThanLen,
    InvalidMultiaddr,
    InvalidProtocolString,
    InvalidUvar,
    ParsingError,
    UnknownProtocolId,
    UnknownProtocolString,
};

// Protocol code constants
const DCCP: u32 = 33;
const DNS: u32 = 53;
const DNS4: u32 = 54;
const DNS6: u32 = 55;
const DNSADDR: u32 = 56;
const HTTP: u32 = 480;
const HTTPS: u32 = 443;
const IP4: u32 = 4;
const IP6: u32 = 41;
const TCP: u32 = 6;
const UDP: u32 = 273;
const UTP: u32 = 302;
const UNIX: u32 = 400;
const P2P: u32 = 421;
const ONION: u32 = 444;
const ONION3: u32 = 445;
const QUIC: u32 = 460;
const WS: u32 = 477;
const WSS: u32 = 478;

pub const Protocol = union(enum) {
    Dccp: u16,
    Dns: []const u8,
    Dns4: []const u8,
    Dns6: []const u8,
    Dnsaddr: []const u8,
    Http,
    Https,
    Ip4: std.net.Ip4Address,
    Ip6: std.net.Ip6Address,
    Tcp: u16,
    Udp: u16, // Added UDP protocol

    pub fn tag(self: Protocol) []const u8 {
        return switch (self) {
            .Dccp => "dccp",
            .Dns => "dns",
            .Dns4 => "dns4",
            .Dns6 => "dns6",
            .Dnsaddr => "dnsaddr",
            .Http => "http",
            .Https => "https",
            .Ip4 => "ip4",
            .Ip6 => "ip6",
            .Tcp => "tcp",
            .Udp => "udp",
        };
    }

    pub fn fromBytes(bytes: []const u8) !struct { proto: Protocol, rest: []const u8 } {
        if (bytes.len < 1) return Error.DataLessThanLen;

        const decoded = try uvarint.decode(u32, bytes);
        const id = decoded.value;
        var rest = decoded.remaining;

        return switch (id) {
            4 => { // IP4
                if (rest.len < 4) return Error.DataLessThanLen;
                const addr = std.net.Ip4Address.init(rest[0..4].*, 0);
                return .{ .proto = .{ .Ip4 = addr }, .rest = rest[4..] };
            },
            6 => { // TCP
                if (rest.len < 2) return Error.DataLessThanLen;
                const port = std.mem.readInt(u16, rest[0..2], .big);
                return .{ .proto = .{ .Tcp = port }, .rest = rest[2..] };
            },
            else => Error.UnknownProtocolId,
        };
    }
    pub fn writeBytes(self: Protocol, writer: anytype) !void {
        switch (self) {
            .Ip4 => |addr| {
                _ = try uvarint.encode_stream(writer, u32, IP4);
                const bytes = std.mem.asBytes(&addr.sa.addr);
                try writer.writeAll(bytes);
            },
            .Tcp => |port| {
                _ = try uvarint.encode_stream(writer, u32, TCP);
                var port_bytes: [2]u8 = undefined;
                std.mem.writeInt(u16, &port_bytes, port, .big);
                try writer.writeAll(&port_bytes);
            },
            .Udp => |port| {
                _ = try uvarint.encode_stream(writer, u32, UDP);
                var port_bytes: [2]u8 = undefined;
                std.mem.writeInt(u16, &port_bytes, port, .big);
                try writer.writeAll(&port_bytes);
            },
            // Temporary catch-all case
            else => {},
        }
    }

    pub fn toString(self: Protocol) []const u8 {
        return switch (self) {
            .Dccp => "dccp",
            .Dns => "dns",
            .Dns4 => "dns4",
            .Dns6 => "dns6",
            .Dnsaddr => "dnsaddr",
            .Http => "http",
            .Https => "https",
            .Ip4 => "ip4",
            .Ip6 => "ip6",
            .Tcp => "tcp",
            .Udp => "udp",
        };
    }
};

pub const Onion3Addr = struct {
    hash: [35]u8,
    port: u16,

    pub fn init(hash: [35]u8, port: u16) Onion3Addr {
        return .{
            .hash = hash,
            .port = port,
        };
    }
};

pub const Multiaddr = struct {
    bytes: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Multiaddr {
        return .{
            .bytes = std.ArrayList(u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn withCapacity(allocator: std.mem.Allocator, capacity: usize) Multiaddr {
        var ma = Multiaddr.init(allocator);
        ma.bytes.ensureTotalCapacity(capacity) catch unreachable;
        return ma;
    }

    // Create from slice of protocols
    pub fn fromProtocols(allocator: std.mem.Allocator, protocols: []const Protocol) !Multiaddr {
        var ma = Multiaddr.init(allocator);
        for (protocols) |p| {
            try ma.push(p);
        }
        return ma;
    }

    pub fn deinit(self: *const Multiaddr) void {
        self.bytes.deinit();
    }

    pub fn iterator(self: Multiaddr) ProtocolIterator {
        return .{ .bytes = self.bytes.items };
    }

    pub fn protocolStack(self: Multiaddr) ProtocolStackIterator {
        return .{ .iter = self.iterator() };
    }

    pub fn with(self: Multiaddr, allocator: std.mem.Allocator, p: Protocol) !Multiaddr {
        var new_ma = Multiaddr.init(allocator);
        try new_ma.bytes.appendSlice(self.bytes.items);
        try new_ma.push(p);
        return new_ma;
    }

    pub fn len(self: Multiaddr) usize {
        return self.bytes.items.len;
    }

    pub fn isEmpty(self: Multiaddr) bool {
        return self.bytes.items.len == 0;
    }

    pub fn toSlice(self: Multiaddr) []const u8 {
        return self.bytes.items;
    }

    pub fn startsWith(self: Multiaddr, other: Multiaddr) bool {
        if (self.bytes.items.len < other.bytes.items.len) return false;
        return std.mem.eql(u8, self.bytes.items[0..other.bytes.items.len], other.bytes.items);
    }

    pub fn endsWith(self: Multiaddr, other: Multiaddr) bool {
        if (self.bytes.items.len < other.bytes.items.len) return false;
        const start = self.bytes.items.len - other.bytes.items.len;
        return std.mem.eql(u8, self.bytes.items[start..], other.bytes.items);
    }

    pub fn push(self: *Multiaddr, p: Protocol) !void {
        try p.writeBytes(self.bytes.writer());
    }

    pub fn pop(self: *Multiaddr) !?Protocol {
        if (self.bytes.items.len == 0) return null;

        // Find the start of the last protocol
        var offset: usize = 0;
        var last_start: usize = 0;
        var rest: []const u8 = self.bytes.items;

        while (rest.len > 0) {
            const decoded = try Protocol.fromBytes(rest);
            if (decoded.rest.len == 0) {
                // This is the last protocol
                const result = decoded.proto;
                self.bytes.shrinkRetainingCapacity(last_start);
                return result;
            }
            last_start = offset + (rest.len - decoded.rest.len);
            offset += rest.len - decoded.rest.len;
            rest = decoded.rest;
        }

        return Error.InvalidMultiaddr;
    }

    pub fn replace(self: Multiaddr, allocator: std.mem.Allocator, at: usize, new_proto: Protocol) !?Multiaddr {
        var new_ma = Multiaddr.init(allocator);
        errdefer new_ma.deinit();

        var count: usize = 0;
        var replaced = false;

        var iter = self.iterator();
        while (try iter.next()) |p| {
            if (count == at) {
                try new_ma.push(new_proto);
                replaced = true;
            } else {
                try new_ma.push(p);
            }
            count += 1;
        }

        if (!replaced) {
            new_ma.deinit();
            return null;
        }
        return new_ma;
    }

    pub fn toString(self: Multiaddr, allocator: std.mem.Allocator) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();

        var rest_bytes: []const u8 = self.bytes.items;
        while (rest_bytes.len > 0) {
            const decoded = try Protocol.fromBytes(rest_bytes);
            switch (decoded.proto) {
                .Ip4 => |addr| {
                    const bytes = @as([4]u8, @bitCast(addr.sa.addr));
                    try result.writer().print("/ip4/{}.{}.{}.{}", .{ bytes[0], bytes[1], bytes[2], bytes[3] });
                },
                .Tcp => |port| try result.writer().print("/tcp/{}", .{port}),
                else => try result.writer().print("/{s}", .{@tagName(@as(@TypeOf(decoded.proto), decoded.proto))}),
            }
            rest_bytes = decoded.rest;
        }

        return result.toOwnedSlice();
    }

    pub fn fromString(allocator: std.mem.Allocator, s: []const u8) !Multiaddr {
        var ma = Multiaddr.init(allocator);
        errdefer ma.deinit();

        var parts = std.mem.splitScalar(u8, s, '/');
        const first = parts.first();
        if (first.len != 0) return Error.InvalidMultiaddr;

        while (parts.next()) |part| {
            if (part.len == 0) continue;

            const proto = try parseProtocol(&parts, part);
            try ma.push(proto);
        }

        return ma;
    }

    fn parseProtocol(parts: *std.mem.SplitIterator(u8, .scalar), proto_name: []const u8) !Protocol {
        return switch (std.meta.stringToEnum(enum { ip4, tcp, udp, dns, dns4, dns6, http, https, ws, wss, p2p, unix }, proto_name) orelse return Error.UnknownProtocolString) {
            .ip4 => blk: {
                const addr_str = parts.next() orelse return Error.InvalidProtocolString;
                var addr: [4]u8 = undefined;
                try parseIp4(addr_str, &addr);
                break :blk Protocol{ .Ip4 = std.net.Ip4Address.init(addr, 0) };
            },
            .tcp, .udp => blk: {
                const port_str = parts.next() orelse return Error.InvalidProtocolString;
                const port = try std.fmt.parseInt(u16, port_str, 10);
                break :blk if (proto_name[0] == 't')
                    Protocol{ .Tcp = port }
                else
                    Protocol{ .Udp = port };
            },
            // Add other protocol parsing as needed
            else => Error.UnknownProtocolString,
        };
    }

    fn parseIp4(s: []const u8, out: *[4]u8) !void {
        var it = std.mem.splitScalar(u8, s, '.');
        var i: usize = 0;
        while (it.next()) |num_str| : (i += 1) {
            if (i >= 4) return Error.InvalidProtocolString;
            out[i] = try std.fmt.parseInt(u8, num_str, 10);
        }
        if (i != 4) return Error.InvalidProtocolString;
    }
};

test "multiaddr push and pop" {
    var ma = Multiaddr.init(testing.allocator);
    defer ma.deinit();

    const ip4 = Protocol{ .Ip4 = std.net.Ip4Address.init([4]u8{ 127, 0, 0, 1 }, 0) };
    const tcp = Protocol{ .Tcp = 8080 };

    try ma.push(ip4);
    std.debug.print("\nAfter IP4 push, buffer: ", .{});
    for (ma.bytes.items) |b| {
        std.debug.print("{x:0>2} ", .{b});
    }

    try ma.push(tcp);
    std.debug.print("\nAfter TCP push, buffer: ", .{});
    for (ma.bytes.items) |b| {
        std.debug.print("{x:0>2} ", .{b});
    }

    const popped_tcp = try ma.pop();
    std.debug.print("\nAfter TCP pop, buffer: ", .{});
    for (ma.bytes.items) |b| {
        std.debug.print("{x:0>2} ", .{b});
    }
    std.debug.print("\nPopped TCP: {any}", .{popped_tcp});

    const popped_ip4 = try ma.pop();
    std.debug.print("\nAfter IP4 pop, buffer: ", .{});
    for (ma.bytes.items) |b| {
        std.debug.print("{x:0>2} ", .{b});
    }
    std.debug.print("\nPopped IP4: {any}", .{popped_ip4});

    try testing.expectEqual(tcp, popped_tcp.?);
    try testing.expectEqual(ip4, popped_ip4.?);
    try testing.expectEqual(@as(?Protocol, null), try ma.pop());
}

test "basic multiaddr creation" {
    var ma = Multiaddr.init(testing.allocator);
    defer ma.deinit();

    try testing.expect(ma.bytes.items.len == 0);
}

test "onion3addr basics" {
    const hash = [_]u8{1} ** 35;
    const addr = Onion3Addr.init(hash, 1234);

    try testing.expectEqual(@as(u16, 1234), addr.port);
    try testing.expectEqualSlices(u8, &hash, &addr.hash);
}

test "multiaddr empty" {
    var ma = Multiaddr.init(testing.allocator);
    defer ma.deinit();

    try testing.expect(ma.bytes.items.len == 0);
}

test "protocol encoding/decoding" {
    var buf: [100]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    const ip4 = Protocol{ .Ip4 = std.net.Ip4Address.init([4]u8{ 127, 0, 0, 1 }, 0) };
    try ip4.writeBytes(writer);

    const decoded = try Protocol.fromBytes(fbs.getWritten());
    try testing.expect(decoded.proto == .Ip4);
}

test "multiaddr from string" {
    const cases = .{
        "/ip4/127.0.0.1/tcp/8080",
        "/ip4/127.0.0.1",
        "/tcp/8080",
    };

    inline for (cases) |case| {
        var ma = try Multiaddr.fromString(testing.allocator, case);
        defer ma.deinit();

        const str = try ma.toString(testing.allocator);
        defer testing.allocator.free(str);

        try testing.expectEqualStrings(case, str);
    }
}

test "debug protocol bytes" {
    var ma = Multiaddr.init(testing.allocator);
    defer ma.deinit();

    const ip4 = Protocol{ .Ip4 = std.net.Ip4Address.init([4]u8{ 127, 0, 0, 1 }, 0) };
    try ma.push(ip4);

    std.debug.print("\nBuffer contents: ", .{});
    for (ma.bytes.items) |b| {
        std.debug.print("{x:0>2} ", .{b});
    }
    std.debug.print("\n", .{});
}

test "debug tcp write" {
    var buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const tcp = Protocol{ .Tcp = 8080 };
    try tcp.writeBytes(fbs.writer());

    std.debug.print("\nTCP write buffer: ", .{});
    for (buf[0..fbs.pos]) |b| {
        std.debug.print("{x:0>2} ", .{b});
    }
    std.debug.print("\n", .{});
}

test "multiaddr basic operations" {
    var ma = Multiaddr.init(testing.allocator);
    defer ma.deinit();
    try testing.expect(ma.isEmpty());
    try testing.expectEqual(@as(usize, 0), ma.len());

    var ma_cap = Multiaddr.withCapacity(testing.allocator, 32);
    defer ma_cap.deinit();
    try testing.expect(ma_cap.isEmpty());

    const ip4 = Protocol{ .Ip4 = std.net.Ip4Address.init([4]u8{ 127, 0, 0, 1 }, 0) };
    try ma_cap.push(ip4);
    try testing.expect(!ma_cap.isEmpty());

    const vec = ma_cap.toSlice();
    try testing.expectEqualSlices(u8, ma_cap.bytes.items, vec);
}

test "multiaddr starts and ends with" {
    var ma1 = Multiaddr.init(testing.allocator);
    defer ma1.deinit();
    var ma2 = Multiaddr.init(testing.allocator);
    defer ma2.deinit();

    const ip4 = Protocol{ .Ip4 = std.net.Ip4Address.init([4]u8{ 127, 0, 0, 1 }, 0) };
    const tcp = Protocol{ .Tcp = 8080 };

    try ma1.push(ip4);
    try ma1.push(tcp);
    try ma2.push(ip4);

    try testing.expect(ma1.startsWith(ma2));
    try ma2.push(tcp);
    try testing.expect(ma1.endsWith(ma2));
}

test "protocol tag strings" {
    const p1 = Protocol{ .Dccp = 1234 };
    try testing.expectEqualStrings("Dccp", @tagName(@as(@TypeOf(p1), p1)));

    const p2 = Protocol.Http;
    try testing.expectEqualStrings("Http", @tagName(@as(@TypeOf(p2), p2)));
}

// Iterator over protocols
pub const ProtocolIterator = struct {
    bytes: []const u8,

    pub fn next(self: *ProtocolIterator) !?Protocol {
        if (self.bytes.len == 0) return null;
        const decoded = try Protocol.fromBytes(self.bytes);
        self.bytes = decoded.rest;
        return decoded.proto;
    }
};

// Add PeerId if not present at end
// pub fn withP2p(self: Multiaddr, peer_id: PeerId) !Multiaddr {
//     var iter = self.iterator();
//     while (try iter.next()) |p| {
//         if (p == .P2p) {
//             if (p.P2p == peer_id) return self;
//             return error.DifferentPeerId;
//         }
//     }
//     return try self.with(.{ .P2p = peer_id });
// }

test "multiaddr iterator" {
    var ma = Multiaddr.init(testing.allocator);
    defer ma.deinit();

    const ip4 = Protocol{ .Ip4 = std.net.Ip4Address.init([4]u8{ 127, 0, 0, 1 }, 0) };
    const tcp = Protocol{ .Tcp = 8080 };
    try ma.push(ip4);
    try ma.push(tcp);

    var iter = ma.iterator();
    const first = try iter.next();
    try testing.expect(first != null);
    try testing.expectEqual(ip4, first.?);

    const second = try iter.next();
    try testing.expect(second != null);
    try testing.expectEqual(tcp, second.?);

    try testing.expectEqual(@as(?Protocol, null), try iter.next());
}

test "multiaddr with" {
    var ma = Multiaddr.init(testing.allocator);
    defer ma.deinit();

    const ip4 = Protocol{ .Ip4 = std.net.Ip4Address.init([4]u8{ 127, 0, 0, 1 }, 0) };
    const tcp = Protocol{ .Tcp = 8080 };

    var ma2 = try ma.with(testing.allocator, ip4);
    defer ma2.deinit();
    var ma3 = try ma2.with(testing.allocator, tcp);
    defer ma3.deinit();

    var iter = ma3.iterator();
    try testing.expectEqual(ip4, (try iter.next()).?);
    try testing.expectEqual(tcp, (try iter.next()).?);
}

pub const ProtocolStackIterator = struct {
    iter: ProtocolIterator,

    pub fn next(self: *ProtocolStackIterator) !?[]const u8 {
        if (try self.iter.next()) |proto| {
            return proto.tag();
        }
        return null;
    }
};

test "multiaddr protocol stack" {
    var ma = Multiaddr.init(testing.allocator);
    defer ma.deinit();

    const ip4 = Protocol{ .Ip4 = std.net.Ip4Address.init([4]u8{ 127, 0, 0, 1 }, 0) };
    const tcp = Protocol{ .Tcp = 8080 };
    try ma.push(ip4);
    try ma.push(tcp);

    var stack = ma.protocolStack();
    const first = try stack.next();
    try testing.expect(first != null);
    try testing.expectEqualStrings("ip4", first.?);

    const second = try stack.next();
    try testing.expect(second != null);
    try testing.expectEqualStrings("tcp", second.?);

    try testing.expectEqual(@as(?[]const u8, null), try stack.next());
}

test "multiaddr as bytes" {
    var ma = Multiaddr.init(testing.allocator);
    defer ma.deinit();

    const ip4 = Protocol{ .Ip4 = std.net.Ip4Address.init([4]u8{ 127, 0, 0, 1 }, 0) };
    const tcp = Protocol{ .Tcp = 8080 };
    try ma.push(ip4);
    try ma.push(tcp);

    const bytes = ma.toSlice();
    try testing.expectEqualSlices(u8, ma.bytes.items, bytes);
}

test "multiaddr from protocols" {
    const protocols = [_]Protocol{
        .{ .Ip4 = std.net.Ip4Address.init([4]u8{ 127, 0, 0, 1 }, 0) },
        .{ .Tcp = 8080 },
    };

    var ma = try Multiaddr.fromProtocols(testing.allocator, &protocols);
    defer ma.deinit();

    var iter = ma.iterator();
    try testing.expectEqual(protocols[0], (try iter.next()).?);
    try testing.expectEqual(protocols[1], (try iter.next()).?);
    try testing.expectEqual(@as(?Protocol, null), try iter.next());
}

test "multiaddr replace" {
    var ma = Multiaddr.init(testing.allocator);
    defer ma.deinit();

    const ip4 = Protocol{ .Ip4 = std.net.Ip4Address.init([4]u8{ 127, 0, 0, 1 }, 0) };
    const tcp = Protocol{ .Tcp = 8080 };
    const new_tcp = Protocol{ .Tcp = 9090 };

    try ma.push(ip4);
    try ma.push(tcp);

    // Replace TCP port
    if (try ma.replace(testing.allocator, 1, new_tcp)) |*replaced| {
        defer replaced.deinit();
        var iter = replaced.iterator();
        try testing.expectEqual(ip4, (try iter.next()).?);
        try testing.expectEqual(new_tcp, (try iter.next()).?);
    } else {
        try testing.expect(false);
    }

    // Try replace at invalid index
    if (try ma.replace(testing.allocator, 5, new_tcp)) |*replaced| {
        defer replaced.deinit();
        try testing.expect(false);
    }
}

test "multiaddr deinit mutable and const" {
    // Test mutable instance
    var ma_mut = Multiaddr.init(testing.allocator);
    const ip4 = Protocol{ .Ip4 = std.net.Ip4Address.init([4]u8{ 127, 0, 0, 1 }, 0) };
    try ma_mut.push(ip4);
    ma_mut.deinit();

    // Test const instance
    var ma = Multiaddr.init(testing.allocator);
    try ma.push(ip4);
    const ma_const = ma;
    ma_const.deinit();
}
