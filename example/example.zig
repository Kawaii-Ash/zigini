const std = @import("std");
const zigini = @import("zigini");
const Config = @import("Config.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var config_reader = zigini.Ini(Config).init(allocator);
    defer config_reader.deinit();

    var config = try config_reader.readFileToStruct("example/config.ini");

    std.debug.print("Writing ini file to stdout...\n\n", .{});

    const stdout = std.io.getStdOut();
    try zigini.writeFromStruct(config, stdout.writer(), null);
}
