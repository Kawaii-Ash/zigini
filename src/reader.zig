const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils.zig");
const ini = @import("ini");
const Child = std.meta.Child;

// Temporary Compatibility with 0.12.0 and 0.13.0
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

pub const IniField = struct {
    header: []const u8 = "",
    key: []const u8,
    value: []const u8,
    allocated: struct { header: bool = false, key: bool = false, value: bool = false } = .{},
};

pub fn Ini(comptime T: type) type {
    return struct {
        const Self = @This();
        const FieldHandlerFn = fn (allocator: std.mem.Allocator, field: IniField) ?IniField;
        const ReadOptions = struct {
            fieldHandler: ?FieldHandlerFn = null,
            comment_characters: []const u8 = ";#",
        };

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

        pub fn readFileToStruct(self: *Self, path: []const u8, comptime opts: ReadOptions) !T {
            const file = try std.fs.cwd().openFile(path, .{});
            defer file.close();
            return self.readToStruct(file.reader(), opts);
        }

        pub fn readToStruct(self: *Self, reader: anytype, comptime opts: ReadOptions) !T {
            var parser = ini.parse(self.allocator, reader, opts.comment_characters);
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
                        var ini_hkv_opt: ?IniField = .{ .key = kv.key, .value = kv.value, .header = ns };
                        if (opts.fieldHandler) |handler| ini_hkv_opt = @call(.always_inline, handler, .{ self.allocator, ini_hkv_opt.? });
                        if (ini_hkv_opt) |ini_hkv| {
                            try self.setStructVal(T, &self.data, ini_hkv);

                            // Check if they were allocated by the handler fn and free if needed
                            if (ini_hkv.allocated.header) self.allocator.free(ini_hkv.header);
                            if (ini_hkv.allocated.key) self.allocator.free(ini_hkv.key);
                            if (ini_hkv.allocated.value) self.allocator.free(ini_hkv.value);
                        }
                    },
                    .enumeration => {},
                }
            }

            return self.data;
        }

        fn setStructVal(self: *Self, comptime T1: type, data: *T1, ini_hkv: IniField) !void {
            inline for (std.meta.fields(T1)) |field| {
                const field_info = @typeInfo(field.type);
                const is_opt_struct = field_info == .Optional and @typeInfo(Child(field.type)) == .Struct;
                if (field_info == .Struct or is_opt_struct) {
                    if (ini_hkv.header.len != 0 and std.ascii.eqlIgnoreCase(field.name, ini_hkv.header)) {
                        comptime var field_type = field.type;
                        if (field_info == .Optional) {
                            field_type = Child(field_type);
                            if (@field(data, field.name) == null)
                                @field(data, field.name) = field_type{};
                        }
                        var inner_struct = utils.unwrapIfOptional(field.type, @field(data, field.name));
                        try self.setStructVal(field_type, &inner_struct, .{ .key = ini_hkv.key, .value = ini_hkv.value });
                        @field(data, field.name) = inner_struct;
                    }
                } else if (ini_hkv.header.len == 0 and std.ascii.eqlIgnoreCase(field.name, ini_hkv.key)) {
                    const conv_value = try self.convert(field.type, ini_hkv.value);
                    if (!utils.isDefaultValue(field, @field(data, field.name))) self.free_field(data, field);
                    @field(data, field.name) = conv_value;
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
                    return try std.fmt.parseInt(T1, val, 0);
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
