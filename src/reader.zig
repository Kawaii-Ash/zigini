const std = @import("std");
const utils = @import("utils.zig");
const ini = @import("ini");
const Child = std.meta.Child;

const trueOrFalse = std.ComptimeStringMap(bool, .{
    .{ "true", true },
    .{ "false", false },
    .{ "1", true },
    .{ "0", false },
});

pub fn Ini(comptime T: type) type {
    return struct {
        const Self = @This();

        data: T,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .data = T{},
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.free_allocated_fields(T, self.data);
        }

        fn free_allocated_fields(self: *Self, comptime T1: type, data: T1) void {
            inline for (std.meta.fields(T1)) |field| attempt_free: {
                const val = @field(data, field.name);
                comptime var field_type = field.type;
                comptime var t_info = @typeInfo(field.type);
                if (t_info == .Optional) {
                    if (val == null) break :attempt_free;
                    field_type = Child(field.type);
                    t_info = @typeInfo(field_type);
                }

                if (t_info == .Pointer and !utils.isDefaultValue(field, val)) {
                    self.allocator.free(utils.unwrapIfOptional(field.type, val));
                } else if (t_info == .Struct) {
                    const unwrapped_val = utils.unwrapIfOptional(field.type, @field(data, field.name));
                    self.free_allocated_fields(field_type, unwrapped_val);
                }
            }
        }

        pub fn readToStruct(self: *Self, path: []const u8) !T {
            const file = try std.fs.cwd().openFile(path, .{});
            defer file.close();
            var parser = ini.parse(self.allocator, file.reader());
            defer parser.deinit();

            var ns: []u8 = &.{};
            defer self.allocator.free(ns);

            while (try parser.next()) |record| {
                switch (record) {
                    .section => |heading| {
                        ns = try self.allocator.realloc(ns, heading.len);
                        _ = std.ascii.lowerString(ns, heading);
                        std.mem.replaceScalar(u8, ns, ' ', '_');
                    },
                    .property => |kv| {
                        try self.setStructVal(T, &self.data, kv, ns);
                    },
                    .enumeration => {},
                }
            }

            return self.data;
        }

        fn setStructVal(self: Self, comptime T1: type, data: *T1, kv: ini.KeyValue, ns: []const u8) !void {
            inline for (std.meta.fields(T1)) |field| {
                const field_info = @typeInfo(field.type);
                const is_opt_struct = field_info == .Optional and @typeInfo(Child(field.type)) == .Struct;
                if (field_info == .Struct or is_opt_struct) {
                    if (ns.len != 0 and std.ascii.eqlIgnoreCase(field.name, ns)) {
                        comptime var field_type = field.type;
                        if (field_info == .Optional) {
                            field_type = Child(field_type);
                            if (@field(data, field.name) == null)
                                @field(data, field.name) = field_type{};
                        }
                        var inner_struct = utils.unwrapIfOptional(field.type, @field(data, field.name));
                        try self.setStructVal(field_type, &inner_struct, kv, "");
                        @field(data, field.name) = inner_struct;
                    }
                } else if (ns.len == 0 and std.ascii.eqlIgnoreCase(field.name, kv.key)) {
                    const conv_value = try self.convert(field.type, kv.value);
                    if (utils.isDefaultValue(field, conv_value)) {
                        if (field_info == .Optional and @typeInfo(Child(field.type)) == .Pointer) {
                            if (conv_value != null) self.allocator.free(conv_value.?);
                        } else if (field_info == .Pointer) self.allocator.free(conv_value);
                    } else {
                        @field(data, field.name) = conv_value;
                    }
                }
            }
        }

        fn convert(self: Self, comptime T1: type, val: []const u8) !T1 {
            return switch (@typeInfo(T1)) {
                .Int => try std.fmt.parseInt(T1, val, 0),
                .Float => try std.fmt.parseFloat(T1, val),
                .Bool => trueOrFalse.get(val) orelse error.InvalidValue,
                .Enum => std.meta.stringToEnum(T1, val) orelse error.InvalidValue,
                .Optional => |opt| {
                    if (val.len == 0 or std.mem.eql(u8, val, "null")) return null;
                    return try self.convert(opt.child, val);
                },
                .Pointer => |p| {
                    if (p.child != u8) @compileError("Type Unsupported");
                    if (p.sentinel != null) return try self.allocator.dupeZ(u8, val);
                    return try self.allocator.dupe(u8, val);
                },
                else => @compileError("Type Unsupported"),
            };
        }
    };
}