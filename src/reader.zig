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
};

pub fn Ini(comptime T: type) type {
    return struct {
        const Self = @This();
        const FieldHandlerFn = fn (arena: std.mem.Allocator, field: IniField) ?IniField;
        const ErrorHandlerFn = fn (type_name: []const u8, key: []const u8, value: []const u8, err: anyerror) void;
        const ReadOptions = struct {
            fieldHandler: ?FieldHandlerFn = null,
            errorHandler: ?ErrorHandlerFn = null,
            comment_characters: []const u8 = ";#",
        };

        arena: std.heap.ArenaAllocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .arena = std.heap.ArenaAllocator.init(allocator),
            };
        }

        pub fn reset(self: *Self) void {
            _ = self.arena.reset(.retain_capacity);
        }

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
        }

        pub fn readFileToStruct(self: *Self, path: []const u8, comptime opts: ReadOptions) !T {
            const file = try std.fs.cwd().openFile(path, .{});
            defer file.close();

            var buf: [4096]u8 = undefined;
            var reader = file.reader(&buf);
            return self.readToStruct(&reader.interface, opts);
        }

        pub fn readToStruct(self: *Self, reader: *std.Io.Reader, comptime opts: ReadOptions) !T {
            var data: T = .{};
            const ch_allocator = self.arena.child_allocator;
            var parser = ini.parse(ch_allocator, reader, opts.comment_characters);
            defer parser.deinit();

            var ns: []u8 = &.{};
            defer ch_allocator.free(ns);

            while (try parser.next()) |record| {
                switch (record) {
                    .section => |heading| {
                        ns = try ch_allocator.realloc(ns, heading.len);
                        @memcpy(ns, heading);
                    },
                    .property => |kv| {
                        var ini_hkv_opt: ?IniField = .{ .key = kv.key, .value = kv.value, .header = ns };
                        var fh_arena = std.heap.ArenaAllocator.init(ch_allocator);
                        defer fh_arena.deinit();

                        if (opts.fieldHandler) |handler| {
                            ini_hkv_opt = @call(.auto, handler, .{ fh_arena.allocator(), ini_hkv_opt.? });
                        }

                        if (ini_hkv_opt) |ini_hkv| {
                            try self.setStructVal(T, &data, ini_hkv, opts.errorHandler);
                        }
                    },
                    .enumeration => {},
                }
            }

            return data;
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
                        if (error_handler) |handler| @call(.auto, handler, .{ @typeName(field.type), ini_hkv.key, ini_hkv.value, err });
                        return err;
                    };
                    @field(data, field.name) = conv_value;
                }
            }
        }

        fn convert(self: *Self, comptime T1: type, val: []const u8) !T1 {
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
                    const arena_allocator = self.arena.allocator();
                    if (p.sentinel_ptr != null) return try arena_allocator.dupeZ(u8, val);
                    return try arena_allocator.dupe(u8, val);
                },
                .void => return {},
                else => @compileError("Type Unsupported"),
            };
        }
    };
}
