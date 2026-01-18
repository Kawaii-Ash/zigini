const std = @import("std");
const utils = @import("utils.zig");
const ini = @import("ini");
const Child = std.meta.Child;

const boolStringMap = std.StaticStringMap(bool).initComptime(.{
    .{ "true", true },
    .{ "false", false },
    .{ "1", true },
    .{ "0", false },
});

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
        const ErrorHandlerFn = fn (type_name: []const u8, key: []const u8, value: []const u8, err: anyerror) void;
        const ReadOptions = struct {
            fieldHandler: ?FieldHandlerFn = null,
            errorHandler: ?ErrorHandlerFn = null,
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
                if (t_info == .optional) {
                    if (val == null) break :attempt_free;
                    field_type = Child(field.type);
                    t_info = @typeInfo(field_type);
                }

                if (t_info == .pointer and !utils.isDefaultValue(field, val)) {
                    self.allocator.free(utils.unwrapIfOptional(field.type, val));
                } else if (t_info == .@"struct") {
                    const unwrapped_val = utils.unwrapIfOptional(field.type, @field(data, field.name));
                    self.free_allocated_fields(field_type, unwrapped_val);
                }
            }
        }

        fn free_field(self: *Self, data: anytype, field: anytype) void {
            const val = @field(data, field.name);
            comptime var field_type = field.type;
            comptime var t_info = @typeInfo(field_type);
            if (t_info == .optional) {
                if (val == null) return;
                field_type = Child(field_type);
                t_info = @typeInfo(field_type);
            }

            if (t_info == .pointer and !utils.isDefaultValue(field, val))
                self.allocator.free(utils.unwrapIfOptional(field.type, val));
        }

        pub fn readFileToStruct(self: *Self, path: []const u8, comptime opts: ReadOptions) !T {
            const file = try std.fs.cwd().openFile(path, .{});
            defer file.close();

            var buf: [4096]u8 = undefined;
            var reader = file.reader(&buf);
            return self.readToStruct(&reader.interface, opts);
        }

        pub fn readToStruct(self: *Self, reader: *std.Io.Reader, comptime opts: ReadOptions) !T {
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
                            try self.setStructVal(T, &self.data, ini_hkv, opts.errorHandler);

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

        fn setStructVal(self: *Self, comptime T1: type, data: *T1, ini_hkv: IniField, error_handler: ?ErrorHandlerFn) !void {
            inline for (std.meta.fields(T1)) |field| {
                const field_info = @typeInfo(field.type);
                const is_opt_struct = field_info == .optional and @typeInfo(Child(field.type)) == .@"struct";
                if (field_info == .@"struct" or is_opt_struct) {
                    if (ini_hkv.header.len != 0 and std.ascii.eqlIgnoreCase(field.name, ini_hkv.header)) {
                        comptime var field_type = field.type;
                        if (field_info == .optional) {
                            field_type = Child(field_type);
                            if (@field(data, field.name) == null)
                                @field(data, field.name) = field_type{};
                        }
                        var inner_struct = utils.unwrapIfOptional(field.type, @field(data, field.name));
                        try self.setStructVal(field_type, &inner_struct, .{ .key = ini_hkv.key, .value = ini_hkv.value }, error_handler);
                        @field(data, field.name) = inner_struct;
                    }
                } else if (ini_hkv.header.len == 0 and std.ascii.eqlIgnoreCase(field.name, ini_hkv.key)) {
                    const conv_value = self.convert(field.type, ini_hkv.value) catch |err| {
                        if (error_handler) |handler| @call(.always_inline, handler, .{ @typeName(field.type), ini_hkv.key, ini_hkv.value, err });
                        return err;
                    };
                    if (!utils.isDefaultValue(field, @field(data, field.name))) self.free_field(data, field);
                    @field(data, field.name) = conv_value;
                }
            }
        }

        fn convert(self: Self, comptime T1: type, val: []const u8) !T1 {
            return switch (@typeInfo(T1)) {
                .int => {
                    if (val.len == 1) {
                        const char = val[0];
                        if (std.ascii.isAscii(char) and !std.ascii.isDigit(char))
                            return char;
                    }
                    return try std.fmt.parseInt(T1, val, 0);
                },
                .float => try std.fmt.parseFloat(T1, val),
                .bool => boolStringMap.get(val) orelse error.InvalidValue,
                .@"enum" => std.meta.stringToEnum(T1, val) orelse error.InvalidValue,
                .optional => |opt| {
                    if (val.len == 0 or std.mem.eql(u8, val, "null")) return null;
                    return try self.convert(opt.child, val);
                },
                .pointer => |p| {
                    if (p.child != u8) @compileError("Type Unsupported");
                    if (p.sentinel_ptr != null) return try self.allocator.dupeZ(u8, val);
                    return try self.allocator.dupe(u8, val);
                },
                else => @compileError("Type Unsupported"),
            };
        }
    };
}
