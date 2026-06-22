const std = @import("std");
const Io = std.Io;

const Database = @import("database.zig").Database;

const Command = union(enum) {
    add: [:0]const u8,
    list,
    remove: [:0]const u8,
    help,
};

const Config = struct {
    max_commands_per_dir: usize = 0,
    max_age_days: usize = 0,
    database_location: [:0]const u8 = "retrace.sqlite",
    store_duplicates: bool = false,

    const Self = @This();

    const Error = error{
        InvalidConfig,
    };

    fn init(p: std.process.Init) !Self {
        var res = Self{};

        if (p.minimal.environ.getPosix("XDG_CONFIG_HOME")) |database_home| {
            res.database_location = std.fmt.allocPrintSentinel(p.arena.allocator(), "{s}/retrace/retrace.sqlite", .{database_home}, 0) catch unreachable;
        } else if (p.minimal.environ.getPosix("HOME")) |home| {
            res.database_location = std.fmt.allocPrintSentinel(p.arena.allocator(), "{s}/.config/retrace/retrace.sqlite", .{home}, 0) catch unreachable;
        }

        const config_path = config_path: {
            if (p.minimal.environ.getPosix("XDG_CONFIG_HOME")) |config_home| {
                break :config_path std.fmt.allocPrint(p.gpa, "{s}/retrace/config", .{config_home}) catch unreachable;
            } else if (p.minimal.environ.getPosix("HOME")) |home| {
                break :config_path std.fmt.allocPrint(p.gpa, "{s}/.config/retrace/config", .{home}) catch unreachable;
            } else {
                return res;
            }
        };
        defer p.gpa.free(config_path);

        const config_data = std.Io.Dir.cwd().readFileAlloc(p.io, config_path, p.gpa, .unlimited) catch |e| {
            switch (e) {
                error.FileNotFound => return res,
                else => return e,
            }
        };
        defer p.gpa.free(config_data);
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
                res.database_location = std.fmt.allocPrintSentinel(p.arena.allocator(), "{s}", .{key}, 0) catch unreachable;
            } else if (std.mem.eql(u8, key, "store_duplicates")) {
                if (std.mem.eql(u8, key, "true")) {
                    res.store_duplicates = true;
                } else if (std.mem.eql(u8, key, "false")) {
                    res.store_duplicates = false;
                } else return Error.InvalidConfig;
            } else {
                return Error.InvalidConfig;
            }
        }
        return res;
    }
};

fn printHelp() noreturn {
    std.debug.print(
        \\Store and view history per directory
        \\
        \\Usage: retrace [OPTIONS]
        \\
        \\Options:
        \\  --directory <DIR>           Directory to work with (defaults to $PWD)
        \\  --add <COMMAND>             Add <COMMAND> to history of selected dir
        \\  --remove <COMMAND>          Remove <COMMAND> from all histories
        \\  --list                      List history for selected directory (Default if no option is provided)
        \\  --help                      Show this help
    , .{});

    std.process.exit(1);
}

pub fn main(init: std.process.Init) !u8 {
    var args = init.minimal.args.iterate();
    _ = args.skip();

    const config = try Config.init(init);

    var command: ?Command = null;
    var directory: []const u8 = ".";
    while (args.next()) |arg_str| {
        if (!std.mem.startsWith(u8, arg_str, "--")) {
            printHelp();
        }
        const arg = arg_str[2..];
        if (std.mem.eql(u8, arg, "directory")) {
            directory = args.next() orelse printHelp();
            continue;
        }
        if (std.mem.eql(u8, arg, "help")) printHelp();
        if (command) |c| {
            if (std.mem.eql(u8, arg, @tagName(c))) {
                std.debug.print("Cannot use '--{s}' more than once\n", .{arg});
                printHelp();
            }
        }
        if (std.mem.eql(u8, arg, "add")) {
            if (command) |c| {
                std.debug.print("Cannot use both '--{s}' and '--add'\n", .{@tagName(c)});
                printHelp();
            }
            command = .{ .add = args.next() orelse printHelp() };
        } else if (std.mem.eql(u8, arg, "remove")) {
            if (command) |c| {
                std.debug.print("Cannot use both '--{s}' and '--remove'\n", .{@tagName(c)});
                printHelp();
            }
            command = .{ .remove = args.next() orelse printHelp() };
        } else if (std.mem.eql(u8, arg, "list")) {
            if (command) |c| {
                std.debug.print("Cannot use both '--{s}' and '--list'\n", .{@tagName(c)});
                printHelp();
            }
            command = .list;
        } else {
            std.debug.print("Invalid arg {s}\n", .{arg_str});
            printHelp();
        }
    }

    std.Io.Dir.cwd().createDirPath(init.io, std.fs.path.dirname(config.database_location).?) catch {};
    var db = try Database.init(config.database_location);
    defer db.deinit() catch unreachable;
    const dir = std.Io.Dir.cwd().realPathFileAlloc(init.io, directory, init.gpa) catch unreachable;
    defer init.gpa.free(dir);

    switch (command orelse .list) {
        .add => |entry| {
            if (std.mem.find(u8, entry, "retrace") != null and std.mem.find(u8, entry, "--remove") != null)
                return 0;
            try db.createTable(init.gpa, dir);
            try db.insert(init.gpa, dir, entry, config.store_duplicates);
            if (config.max_commands_per_dir != 0)
                try db.pruneNum(init.gpa, dir, config.max_commands_per_dir);
            if (config.max_age_days != 0)
                try db.pruneAge(init.gpa, dir, config.max_age_days);
        },
        .list => {
            const res = try db.fetch(init.arena.allocator(), dir);

            var stdout_buffer: [1024]u8 = undefined;
            var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
            const stdout_writer = &stdout_file_writer.interface;

            for (res.items) |r| try stdout_writer.print("{s}\n", .{r});

            try stdout_writer.flush();
        },
        .remove => |entry| {
            try db.deleteCommand(init.gpa, entry);
        },
        .help => {
            unreachable;
        },
    }

    return 0;
}
