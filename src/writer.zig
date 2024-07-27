const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils.zig");
const Child = std.meta.Child;

const is_12 = builtin.zig_version.minor == 12;

pub fn writeFromStruct(data: anytype, writer: anytype, namespace: ?[]const u8, write_all_fields: bool, comptime map: anytype) !void {
    const string_map: ?if (is_12) type else std.StaticStringMap([:0]const u8) = if (map.len > 0) blk: {
        break :blk if (is_12) std.ComptimeStringMap([:0]const u8, map) else std.StaticStringMap([:0]const u8).initComptime(map);
    } else null;

    var should_write_ns = namespace != null and namespace.?.len != 0;
    comptime var struct_fields: []std.builtin.Type.StructField = &.{};

    inline for (std.meta.fields(@TypeOf(data))) |field| {
        switch (@typeInfo(field.type)) {
            .Struct => struct_fields = @constCast(struct_fields ++ .{field}),
            else => |t_info| {
                if (t_info == .Optional and @typeInfo(Child(field.type)) == .Struct) {
                    struct_fields = @constCast(struct_fields ++ .{field});
                    continue;
                }
                const value = @field(data, field.name);

                if (!utils.isDefaultValue(field, value) or write_all_fields) {
                    if (should_write_ns) {
                        var mapped_ns = namespace.?;
                        if (string_map) |sm| {
                            mapped_ns = sm.get(mapped_ns) orelse mapped_ns;
                        }
                        try writer.print("[{s}]\n", .{mapped_ns});
                        should_write_ns = false;
                    }

                    comptime var field_name = field.name;
                    comptime if (string_map) |sm| {
                        field_name = sm.get(field_name) orelse field_name;
                    };

                    if (t_info == .Optional and value == null) {
                        try writeProperty(writer, field_name, "null");
                    } else {
                        try writeProperty(writer, field_name, utils.unwrapIfOptional(field.type, value));
                    }
                }
            },
        }
    }

    if (namespace == null or namespace.?.len == 0) {
        inline for (struct_fields) |field| {
            if (@typeInfo(field.type) == .Struct) {
                try writeFromStruct(@field(data, field.name), writer, field.name, write_all_fields, map);
            } else if (@field(data, field.name)) |inner_data| {
                try writeFromStruct(inner_data, writer, field.name, write_all_fields, map);
            }
        }
    }
}

fn writeProperty(writer: anytype, field_name: []const u8, val: anytype) !void {
    switch (@typeInfo(@TypeOf(val))) {
        .Bool => {
            try writer.print("{s}={s}\n", .{ field_name, if (val) "true" else "false" });
        },
        .Int, .ComptimeInt, .Float, .ComptimeFloat => {
            try writer.print("{s}={d}\n", .{ field_name, val });
        },
        .Enum => {
            try writer.print("{s}={s}\n", .{ field_name, @tagName(val) });
        },
        else => {
            try writer.print("{s}={s}\n", .{ field_name, val });
        },
    }
}
