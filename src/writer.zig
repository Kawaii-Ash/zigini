const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils.zig");
const Child = std.meta.Child;

const FieldHandlerFn = fn (comptime ns: ?[]const u8, comptime key: ?[]const u8) ?[]const u8;

const WriteOptions = struct {
    renameHandler: ?FieldHandlerFn = null,

    // Whether to write fields when they're the same as the default value
    write_default_values: bool = true,
};

pub fn writeFromStruct(data: anytype, writer: anytype, comptime namespace: ?[]const u8, comptime opts: WriteOptions) !void {
    comptime var should_write_ns = namespace != null and namespace.?.len != 0;
    comptime var struct_fields: []std.builtin.Type.StructField = &.{};

    inline for (std.meta.fields(@TypeOf(data))) |field| {
        switch (@typeInfo(field.type)) {
            .Struct => struct_fields = @constCast(struct_fields ++ .{field}),
            else => |t_info| {
                if (t_info == .Optional and @typeInfo(Child(field.type)) == .Struct) {
                    struct_fields = @constCast(struct_fields ++ .{field});
                    continue;
                }

                comptime var field_name: []const u8 = field.name;
                comptime if (opts.renameHandler) |handler| {
                    const new_field_name = @call(.always_inline, handler, .{ namespace, field_name });
                    if (new_field_name != null) {
                        field_name = new_field_name.?;
                    } else continue;
                };

                if (should_write_ns) {
                    comptime var mapped_ns: []const u8 = namespace.?;
                    comptime if (opts.renameHandler) |handler| {
                        mapped_ns = @call(.always_inline, handler, .{ namespace, null }) orelse mapped_ns;
                    };
                    try writer.print("[{s}]\n", .{mapped_ns});
                    should_write_ns = false;
                }

                const value = @field(data, field.name);
                if (opts.write_default_values or !utils.isDefaultValue(field, value)) {
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
                try writeFromStruct(@field(data, field.name), writer, field.name, opts);
            } else if (@field(data, field.name)) |inner_data| {
                try writeFromStruct(inner_data, writer, field.name, opts);
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
