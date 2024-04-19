const std = @import("std");
const Child = std.meta.Child;

pub fn isDefaultValue(field: anytype, field_value: field.type) bool {
    const default_value = getDefaultValue(field) catch return false;

    return std.meta.eql(default_value, field_value);
}

fn getDefaultValue(comptime field: anytype) !field.type {
    if (field.default_value) |default_value| {
        const def_val: *align(field.alignment) const anyopaque = @alignCast(default_value);
        return @as(*const field.type, @ptrCast(def_val)).*;
    }
    return error.NoDefaultValue;
}

fn RemoveOptional(comptime T: type) type {
    if (@typeInfo(T) == .Optional) return Child(T);
    return T;
}

pub fn unwrapIfOptional(comptime T: type, val: T) RemoveOptional(T) {
    if (@typeInfo(T) == .Optional) return val.?;
    return val;
}
