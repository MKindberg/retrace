const std = @import("std");
const Io = std.Io;

const Database = @import("database.zig").Database;

const Command = enum {
    add,
    list,
    remove,
    help,
};

const Config = struct {
    max_commands_per_dir: usize = 0,
    max_age_days: usize = 0,
    database_location: [:0]const u8 = ".",

    const Self = @This();

    const Error = error{
        InvalidConfig,
    };

    fn init(gpa: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !Self {
        var res = Self{};

        if (environ.getPosix("XDG_CONFIG_HOME")) |database_home| {
            res.database_location = std.fmt.allocPrintSentinel(gpa, "{s}/retrace/retrace.sqlite", .{database_home}, 0) catch unreachable;
        } else if (environ.getPosix("HOME")) |home| {
            res.database_location = std.fmt.allocPrintSentinel(gpa, "{s}/.config/retrace/retrace.sqlite", .{home}, 0) catch unreachable;
        }

        const config_path = config_path: {
            if (environ.getPosix("XDG_CONFIG_HOME")) |config_home| {
                break :config_path std.fmt.allocPrint(gpa, "{s}/retrace/config", .{config_home}) catch unreachable;
            } else if (environ.getPosix("HOME")) |home| {
                break :config_path std.fmt.allocPrint(gpa, "{s}/.config/retrace/config", .{home}) catch unreachable;
            } else {
                return res;
            }
        };
        defer gpa.free(config_path);

        const config_data = std.Io.Dir.cwd().readFileAlloc(io, config_path, gpa, .unlimited) catch |e| {
            switch (e) {
                error.FileNotFound => return Self{},
                else => return e,
            }
        };
        defer gpa.free(config_data);
        var it = std.mem.splitScalar(u8, config_data, '\n');

        while (it.next()) |line| {
            const l = std.mem.trimStart(u8, line, &std.ascii.whitespace);
            if (std.mem.startsWith(u8, l, "//")) continue;
            if (l.len == 0) continue;
            const eq_idx = std.mem.findScalar(u8, l, '=') orelse return Error.InvalidConfig;

            const key = std.mem.trim(u8, l[0..eq_idx], " ");
            const value = std.mem.trim(u8, l[eq_idx + 1 ..], " ");

            if (std.mem.eql(u8, key, "max_commands_per_dir")) {
                res.max_commands_per_dir = std.fmt.parseInt(usize, value, 10) catch return Error.InvalidConfig;
            } else if (std.mem.eql(u8, key, "max_age_days")) {
                res.max_age_days = std.fmt.parseInt(usize, value, 10) catch return Error.InvalidConfig;
            } else if (std.mem.eql(u8, key, "database_location")) {
                res.database_location = std.fmt.allocPrintSentinel(gpa, "{s}", .{key}, 0) catch unreachable;
            } else {
                return Error.InvalidConfig;
            }
        }
        return res;
    }
};

fn printHelp() void {}

pub fn main(init: std.process.Init) !u8 {
    var args = init.minimal.args.iterate();
    _ = args.skip();

    const config = try Config.init(init.gpa, init.io, init.minimal.environ);

    const command_str = args.next() orelse {
        printHelp();
        return 1;
    };
    const command = std.meta.stringToEnum(Command, command_str) orelse {
        std.debug.print("Invalid command {s}\n", .{command_str});
        printHelp();
        return 1;
    };

    var db = try Database.init(config.database_location);
    defer db.deinit() catch unreachable;
    const dir = std.Io.Dir.cwd().realPathFileAlloc(init.io, ".", init.gpa) catch unreachable;
    defer init.gpa.free(dir);

    switch (command) {
        .add => {
            const entry = args.next() orelse {
                printHelp();
                return 1;
            };

            try db.createTable(init.gpa, dir);
            try db.insert(init.gpa, dir, entry);
            if (config.max_commands_per_dir != 0)
                try db.pruneNum(init.gpa, dir, config.max_commands_per_dir);
            if (config.max_age_days != 0)
                try db.pruneAge(init.gpa, dir, config.max_age_days);
        },
        .list => {
            const res = try db.fetch(init.arena.allocator(), dir);
            for (res.items) |r| std.debug.print("{s}\n", .{r});
        },
        .remove => {
            const entry = args.next() orelse {
                printHelp();
                return 1;
            };
            try db.deleteCommand(init.gpa, entry);
        },
        .help => {
            printHelp();
            return 1;
        },
    }

    return 0;
}
