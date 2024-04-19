const Config = @This();

const Status = enum {
    happy,
    bored,
    sad,
    sleepy,
};

const Colors = struct {
    bg: u8 = 0,
    fg: u8 = 0,
};

name: []const u8 = "Ash",
status: Status = .happy,
is_a_puppet: bool = true,
colors: ?Colors = null,
bio: [:0]const u8 = "",
hrs_slept: f64 = 8,
@"alt/colors": ?Colors = Colors{},
