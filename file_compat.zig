const std = @import("std");
const builtin = @import("builtin");

pub const is_0_16_or_newer = builtin.zig_version.major > 0 or
    (builtin.zig_version.major == 0 and builtin.zig_version.minor >= 16);
