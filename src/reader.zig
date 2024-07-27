const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils.zig");
const ini = @import("ini");
const Child = std.meta.Child;

const is_12 = builtin.zig_version.minor == 12;

const bool_string = .{
    .{ "true", true },
    .{ "false", false },
    .{ "1", true },
    .{ "0", false },
};

const boolStringMap = if (is_12)
    std.ComptimeStringMap(bool, bool_string)
else
    std.StaticStringMap(bool).initComptime(bool_string);

pub const HandlerResult = struct {
    changed: enum { key, value },
    str: []const u8,
};

pub fn Ini(comptime T: type) type {
    return struct {
        const Self = @This();
        const HandleIncorrectFieldFn = fn ([]const u8, []const u8) ?HandlerResult;

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

        fn free_field(self: *Self, data: anytype, field: anytype) void {
            const val = @field(data, field.name);
            comptime var field_type = field.type;
            comptime var t_info = @typeInfo(field_type);
            if (t_info == .Optional) {
                if (val == null) return;
                field_type = Child(field_type);
                t_info = @typeInfo(field_type);
            }

            if (t_info == .Pointer and !utils.isDefaultValue(field, val))
                self.allocator.free(utils.unwrapIfOptional(field.type, val));
        }

        pub fn readFileToStruct(self: *Self, path: []const u8, comptime handle_incorrect_field_fn: ?HandleIncorrectFieldFn) !T {
            const file = try std.fs.cwd().openFile(path, .{});
            defer file.close();
            return self.readToStruct(file.reader(), handle_incorrect_field_fn);
        }

        pub fn readToStruct(self: *Self, reader: anytype, comptime handle_incorrect_field_fn: ?HandleIncorrectFieldFn) !T {
            var parser = ini.parse(self.allocator, reader);
            defer parser.deinit();

            var ns: []u8 = &.{};
            defer self.allocator.free(ns);

            while (try parser.next()) |record| {
                switch (record) {
                    .section => |heading| {
                        ns = try self.allocator.realloc(ns, heading.len);
                        @memcpy(ns, heading);
                    },
                    .property => |kv| {
                        try self.setStructVal(T, &self.data, kv, ns, handle_incorrect_field_fn);
                    },
                    .enumeration => {},
                }
            }

            return self.data;
        }

        fn setStructVal(
            self: *Self,
            comptime T1: type,
            data: *T1,
            kv: ini.KeyValue,
            ns: []const u8,
            comptime handle_incorrect_field_fn: ?HandleIncorrectFieldFn,
        ) !void {
            inline for (std.meta.fields(T1)) |field| {
                const field_info = @typeInfo(field.type);
                const is_opt_struct = field_info == .Optional and @typeInfo(Child(field.type)) == .Struct;

                if (field_info == .Struct or is_opt_struct) {
                    if (ns.len != 0) {
                        var namespace = ns;

                        if (handle_incorrect_field_fn) |handle_incorrect_field| {
                            const maybe_new_ns = @call(.always_inline, handle_incorrect_field, .{ ns, "" });
                            if (maybe_new_ns) |new_ns| {
                                namespace = new_ns.str;
                            }
                        }

                        if (std.ascii.eqlIgnoreCase(field.name, namespace)) {
                            comptime var field_type = field.type;
                            if (field_info == .Optional) {
                                field_type = Child(field_type);
                                if (@field(data, field.name) == null)
                                    @field(data, field.name) = field_type{};
                            }
                            var inner_struct = utils.unwrapIfOptional(field.type, @field(data, field.name));
                            try self.setStructVal(field_type, &inner_struct, kv, "", handle_incorrect_field_fn);
                            @field(data, field.name) = inner_struct;
                        }
                    }
                } else if (ns.len == 0) {
                    var key: []const u8 = kv.key;
                    var key_changed = false;

                    if (handle_incorrect_field_fn) |handle_incorrect_field| {
                        const maybe_new_key = @call(.always_inline, handle_incorrect_field, .{ kv.key, kv.value });
                        if (maybe_new_key) |new_key| {
                            if (new_key.changed == .key) {
                                key = new_key.str;
                                key_changed = true;
                            }
                        }
                    }

                    if (std.ascii.eqlIgnoreCase(field.name, key)) {
                        var value: []const u8 = kv.value;

                        if (!key_changed) {
                            if (handle_incorrect_field_fn) |handle_incorrect_field| {
                                const maybe_new_value = @call(.always_inline, handle_incorrect_field, .{ kv.key, kv.value });
                                if (maybe_new_value) |new_value| value = new_value.str;
                            }
                        }

                        const conv_value = try self.convert(field.type, value);
                        if (!utils.isDefaultValue(field, @field(data, field.name))) self.free_field(data, field);
                        @field(data, field.name) = conv_value;
                    }
                }
            }
        }

        fn convert(self: Self, comptime T1: type, val: []const u8) !T1 {
            return switch (@typeInfo(T1)) {
                .Int => {
                    if (val.len == 1) {
                        const char = val[0];
                        if (std.ascii.isASCII(char) and !std.ascii.isDigit(char))
                            return char;
                    }
                    return std.fmt.parseInt(T1, val, 0) catch return error.InvalidValue;
                },
                .Float => try std.fmt.parseFloat(T1, val),
                .Bool => boolStringMap.get(val) orelse error.InvalidValue,
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
