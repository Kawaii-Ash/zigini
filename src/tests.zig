const std = @import("std");
const ini = @import("main.zig");
const Ini = ini.Ini;

const NestedConfig = struct {
    string: []const u8 = "",
    num: u8 = 0,
};

const Config = struct {
    string: ?[]const u8 = "Default String",
    nt_string: [:0]const u8 = "",
    num: u8 = 1,
    nested_config: NestedConfig = .{},
    @"Other Config": ?NestedConfig = null,
};

fn handleField(_: std.mem.Allocator, field: ini.IniField) ?ini.IniField {
    var mapped_field = field;

    if (std.mem.eql(u8, field.header, "Nested Config")) mapped_field.header = "nested_config";
    if (std.mem.eql(u8, field.key, "other")) mapped_field.key = "num";

    return mapped_field;
}

test "Read ini without mapping" {
    var fbs = std.io.fixedBufferStream(
        \\string=A String
        \\string=Default String
        \\nt_string=Another String
        \\num=33
        \\[nested_config]
        \\string=Nested String
        \\num=62
        \\[Other Config]
        \\num=10
    );

    var ini_conf = Ini(Config).init(std.testing.allocator);
    defer ini_conf.deinit();
    const config = try ini_conf.readToStruct(fbs.reader(), ";#", null);

    try std.testing.expectEqualStrings("Default String", config.string.?);
    try std.testing.expectEqualStrings("Another String", config.nt_string);
    try std.testing.expectEqualStrings("Nested String", config.nested_config.string);
    try std.testing.expect(config.num == 33);
    try std.testing.expect(config.nested_config.num == 62);
    try std.testing.expect(config.@"Other Config".?.num == 10);
}

test "Read ini with mapping" {
    var fbs = std.io.fixedBufferStream(
        \\other=33
        \\[Nested Config]
        \\other=12
    );

    var ini_conf = Ini(Config).init(std.testing.allocator);
    defer ini_conf.deinit();

    const config = try ini_conf.readToStruct(fbs.reader(), ";#", handleField);

    try std.testing.expect(config.num == 33);
    try std.testing.expect(config.nested_config.num == 12);
}

test "Write without namespace" {
    const conf = Config{
        .num = 10,
        .string = "String!",
        .nested_config = .{ .num = 71, .string = "A Random String" },
    };

    var buf: [100]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try ini.writeFromStruct(conf, fbs.writer(), null, false, .{
        .{ "nested_config", "Nested Config" },
        .{ "string", "new_string" },
    });
    const ini_str = fbs.getWritten();

    const expected =
        \\new_string=String!
        \\num=10
        \\[Nested Config]
        \\new_string=A Random String
        \\num=71
        \\
    ;

    try std.testing.expect(ini_str.len == expected.len);
    try std.testing.expectEqualStrings(expected, ini_str);
}

test "Write with namespace" {
    const conf = Config{ .num = 98, .string = "Some String", .nested_config = .{ .num = 71 } };

    var buf: [100]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try ini.writeFromStruct(conf, fbs.writer(), "A Namespace", false, .{});
    const ini_str = fbs.getWritten();

    const expected =
        \\[A Namespace]
        \\string=Some String
        \\num=98
        \\
    ;
    try std.testing.expect(ini_str.len == expected.len);
    try std.testing.expectEqualStrings(expected, ini_str);
}
