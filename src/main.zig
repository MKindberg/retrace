const std = @import("std");
const Io = std.Io;

const Database = @import("database.zig").Database;

const Command = enum {
    Add,
    List,
    Help,
};

fn printHelp() void {}

pub fn main(init: std.process.Init) !u8 {
    var args = init.minimal.args.iterate();
    _ = args.skip();


    const command_str = args.next() orelse {
        printHelp();
        return 1;
    };
    const command = std.meta.stringToEnum(Command, command_str) orelse {
        std.debug.print("Invalid command {s}\n", .{command_str});
        printHelp();
        return 1;
    };

    const entry = args.next() orelse {
        printHelp();
        return 1;
    };

    var db = try Database.init("db.sqlite");
    defer db.deinit() catch unreachable;
    const dir = std.Io.Dir.cwd().realPathFileAlloc(init.io, ".", init.gpa) catch unreachable;
    defer init.gpa.free(dir);

    switch (command) {
        .Add => {
            try db.createTable(init.gpa, dir);
            try db.insert(init.gpa, dir, entry);
        },
        .List => {
             const res = try db.fetch(init.arena.allocator(), dir);
             for (res.items) |r| std.debug.print("{s}\n", .{r});

        },
        .Help => {
            printHelp();
            return 1;
        },
    }

    return 0;
}
