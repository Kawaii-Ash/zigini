const std = @import("std");
const Ini = @import("reader.zig").Ini;

const NestedConfig = struct {
    string: []const u8 = "",
    nt_string: [:0]const u8 = "",
    num: u8 = 0,
};

const Config = struct {
    opt_string: ?[]const u8 = "Default String",
    nt_string: [:0]const u8 = "",
    num: u8 = 1,
    UpcaseField: u8 = 0,
    @"nested/Config": NestedConfig = .{},
    @"Nested Config": NestedConfig = .{},
};

test "Read ini to struct" {
    var fbs = std.io.fixedBufferStream(
        \\opt_string=One String
        \\nt_string=Another String
        \\UpcaseField=9
        \\[nested/Config]
        \\string=Nested String
        \\num=3
        \\[Nested Config]
        \\string=Another Nested String
    );

    var ini_conf = Ini(Config).init(std.testing.allocator);
    defer ini_conf.deinit();
    const config = try ini_conf.readToStruct(fbs.reader());

    try std.testing.expectEqualStrings("One String", config.opt_string.?);
    try std.testing.expectEqualSentinel(u8, 0, "Another String", config.nt_string);
    try std.testing.expect(config.num == 1);

    try std.testing.expect(config.@"nested/Config".num == 3);
    try std.testing.expectEqualStrings("Nested String", config.@"nested/Config".string);
    try std.testing.expectEqualStrings("Another Nested String", config.@"Nested Config".string);

    try std.testing.expect(config.UpcaseField == 9);
}
