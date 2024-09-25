const std = @import("std");
const zigini = @import("zigini");
const Config = @import("Config.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var config_reader = zigini.Ini(Config).init(allocator);
    defer config_reader.deinit();

    const config = try config_reader.readFileToStruct("example/config.ini", .{});

    std.debug.print("Writing ini file to stdout...\n\n", .{});

    const stdout = std.io.getStdOut();
    try zigini.writeFromStruct(config, stdout.writer(), null, .{ .renameHandler = writeRenameHandler, .write_default_values = false });
}

fn writeRenameHandler(comptime header: ?[]const u8, comptime field_name: ?[]const u8) ?[]const u8 {
    if (field_name == null) {
        // We can rename the header here
        if (std.mem.eql(u8, header.?, "colors")) return "better-colors";

        return null; // null = keep the same
    }

    // Here, we are renaming field_name.
    //
    // Note: renaming the header above only renames it in the output
    // so make sure to compare the header with the original name
    // rather than what you renamed it to.
    if (header != null and std.mem.eql(u8, header.?, "colors")) {
        if (std.mem.eql(u8, field_name.?, "bg")) return "new-bg";
    }

    // returning null removes the field from the output
    if (std.mem.eql(u8, field_name.?, "is_a_puppet")) return null;

    return field_name;
}
