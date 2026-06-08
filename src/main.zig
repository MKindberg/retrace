const std = @import("std");
const Io = std.Io;

const retrace = @import("retrace");

pub fn main(_: std.process.Init) !void {
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
}
