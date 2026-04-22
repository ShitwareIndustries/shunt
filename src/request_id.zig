const std = @import("std");

pub fn generate(io: std.Io, buf: *[36]u8) void {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);

    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    const hex = "0123456789abcdef";
    buf[0] = hex[bytes[0] >> 4];
    buf[1] = hex[bytes[0] & 0x0f];
    buf[2] = hex[bytes[1] >> 4];
    buf[3] = hex[bytes[1] & 0x0f];
    buf[4] = hex[bytes[2] >> 4];
    buf[5] = hex[bytes[2] & 0x0f];
    buf[6] = hex[bytes[3] >> 4];
    buf[7] = hex[bytes[3] & 0x0f];
    buf[8] = '-';
    buf[9] = hex[bytes[4] >> 4];
    buf[10] = hex[bytes[4] & 0x0f];
    buf[11] = hex[bytes[5] >> 4];
    buf[12] = hex[bytes[5] & 0x0f];
    buf[13] = '-';
    buf[14] = hex[bytes[6] >> 4];
    buf[15] = hex[bytes[6] & 0x0f];
    buf[16] = hex[bytes[7] >> 4];
    buf[17] = hex[bytes[7] & 0x0f];
    buf[18] = '-';
    buf[19] = hex[bytes[8] >> 4];
    buf[20] = hex[bytes[8] & 0x0f];
    buf[21] = hex[bytes[9] >> 4];
    buf[22] = hex[bytes[9] & 0x0f];
    buf[23] = '-';
    buf[24] = hex[bytes[10] >> 4];
    buf[25] = hex[bytes[10] & 0x0f];
    buf[26] = hex[bytes[11] >> 4];
    buf[27] = hex[bytes[11] & 0x0f];
    buf[28] = hex[bytes[12] >> 4];
    buf[29] = hex[bytes[12] & 0x0f];
    buf[30] = hex[bytes[13] >> 4];
    buf[31] = hex[bytes[13] & 0x0f];
    buf[32] = hex[bytes[14] >> 4];
    buf[33] = hex[bytes[14] & 0x0f];
    buf[34] = hex[bytes[15] >> 4];
    buf[35] = hex[bytes[15] & 0x0f];
}

test "generate produces valid UUID v4 format" {
    var id_buf: [36]u8 = undefined;
    generate(std.testing.io, &id_buf);

    try std.testing.expect(id_buf[8] == '-');
    try std.testing.expect(id_buf[13] == '-');
    try std.testing.expect(id_buf[18] == '-');
    try std.testing.expect(id_buf[23] == '-');

    const version_nibble = std.fmt.parseInt(u4, id_buf[14..15], 16) catch 0;
    try std.testing.expect(version_nibble == 4);

    const variant_nibble = std.fmt.parseInt(u4, id_buf[19..20], 16) catch 0;
    try std.testing.expect(variant_nibble >= 8 and variant_nibble <= 0xb);
}

test "generate produces different UUIDs on successive calls" {
    var id1: [36]u8 = undefined;
    var id2: [36]u8 = undefined;
    generate(std.testing.io, &id1);
    generate(std.testing.io, &id2);
    try std.testing.expect(!std.mem.eql(u8, &id1, &id2));
}
