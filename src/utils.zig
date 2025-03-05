const std = @import("std");
const Child = std.meta.Child;

pub fn isDefaultValue(field: anytype, field_value: field.type) bool {
    const default_value = getDefaultValue(field) catch return false;

    return std.meta.eql(default_value, field_value);
}

fn getDefaultValue(comptime field: anytype) !field.type {
    const default_value = field.defaultValue();

    return default_value orelse error.NoDefaultValue;
}

fn RemoveOptional(comptime T: type) type {
    if (@typeInfo(T) == .optional) return Child(T);
    return T;
}

pub fn unwrapIfOptional(comptime T: type, val: T) RemoveOptional(T) {
    if (@typeInfo(T) == .optional) return val.?;
    return val;
}
