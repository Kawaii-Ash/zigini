const std = @import("std");
const utils = @import("utils.zig");
const Child = std.meta.Child;

pub fn writeFromStruct(data: anytype, writer: anytype, namespace: ?[]const u8) !void {
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

                if (!utils.isDefaultValue(field, value)) {
                    if (should_write_ns) {
                        try writer.print("[{s}]\n", .{namespace.?});
                        should_write_ns = false;
                    }
                    if (t_info == .Optional and value == null) {
                        try writeProperty(writer, field.name, "");
                    } else {
                        try writeProperty(writer, field.name, utils.unwrapIfOptional(field.type, value));
                    }
                }
            },
        }
    }

    if (namespace == null or namespace.?.len == 0) {
        inline for (struct_fields) |field| {
            if (@typeInfo(field.type) == .Struct) {
                try writeFromStruct(@field(data, field.name), writer, field.name);
            } else if (@field(data, field.name)) |inner_data| {
                try writeFromStruct(inner_data, writer, field.name);
            }
        }
    }
}

fn writeProperty(writer: anytype, field_name: []const u8, val: anytype) !void {
    switch (@typeInfo(@TypeOf(val))) {
        .Bool => {
            try writer.print("{s}={d}\n", .{ field_name, @intFromBool(val) });
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
