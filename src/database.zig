const std = @import("std");

const c = @cImport({
    @cInclude("sqlite3.h");
});

const SqliteError = error{
    SQLITE_ERROR,
    SQLITE_INTERNAL,
    SQLITE_PERM,
    SQLITE_ABORT,
    SQLITE_BUSY,
    SQLITE_LOCKED,
    SQLITE_NOMEM,
    SQLITE_READONLY,
    SQLITE_INTERRUPT,
    SQLITE_IOERR,
    SQLITE_CORRUPT,
    SQLITE_NOTFOUND,
    SQLITE_FULL,
    SQLITE_CANTOPEN,
    SQLITE_PROTOCOL,
    SQLITE_EMPTY,
    SQLITE_SCHEMA,
    SQLITE_TOOBIG,
    SQLITE_CONSTRAINT,
    SQLITE_MISMATCH,
    SQLITE_MISUSE,
    SQLITE_NOLFS,
    SQLITE_AUTH,
    SQLITE_FORMAT,
    SQLITE_RANGE,
    SQLITE_NOTADB,
    SQLITE_NOTICE,
    SQLITE_WARNING,
    SQLITE_ROW,
    SQLITE_DONE,
};

pub const Database = struct {
    db: *c.sqlite3,

    fn codeToError(code: c_int) SqliteError!c_int {
        if (code == 0 or code == 100 or code == 101) return code;

        inline for (@typeInfo(SqliteError).error_set.?) |e| {
            if (code == @field(c, e.name)) return @field(SqliteError, e.name);
        }
        unreachable;
    }

    const Self = @This();
    pub fn init(db_file: [:0]const u8) !Self {
        var db: ?*c.sqlite3 = null;
        _ = try codeToError(c.sqlite3_open(db_file, &db));

        return .{ .db = db.? };
    }

    pub fn deinit(self: *Self) !void {
        _ = try codeToError(c.sqlite3.close(self.db));
    }

    pub fn createTable(self: *Self, allocator: std.mem.Allocator, name: []const u8) !void {
        // The risk of injections through the name of a path feels low enough to be acecptable
        // since bind cannot be used for table names.
        const query = std.fmt.allocPrintSentinel(allocator, "CREATE TABLE IF NOT EXISTS \"{s}\" (id INTEGER PRIMARY KEY, command TEXT NOT NULL, timestamp DEFAULT (datetime('now')));", .{name}, 0) catch unreachable;
        defer allocator.free(query);
        _ = try codeToError(c.sqlite3_exec(self.db, query, null, null, null));
    }

    pub fn insert(self: *Self, allocator: std.mem.Allocator, table: []const u8, command: [:0]const u8) !void {
        const query = std.fmt.allocPrintSentinel(allocator, "INSERT INTO \"{s}\" (command) VALUES (?);", .{table}, 0) catch unreachable;
        defer allocator.free(query);

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, query, -1, &stmt, null) != 0) return;
        defer _ = c.sqlite3_finalize(stmt);
        _ = try codeToError(c.sqlite3_bind_text(stmt, 1, command.ptr, @intCast(command.len), null));

        _ = try codeToError(c.sqlite3_step(stmt));
    }

    pub fn fetch(self: Self, allocator: std.mem.Allocator, table: [:0]const u8) !std.ArrayList([]const u8) {
        var list = std.ArrayList([]const u8).empty;
        errdefer {
            for (list.items) |item| allocator.free(item);
            list.deinit(allocator);
        }

        const query = std.fmt.allocPrintSentinel(allocator, "SELECT command FROM \"{s}\";", .{table}, 0) catch unreachable;
        defer allocator.free(query);

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, query, -1, &stmt, null) != 0) return list;
        defer _ = c.sqlite3_finalize(stmt);

        while (try codeToError(c.sqlite3_step(stmt)) == 100) {
            const text_ptr = c.sqlite3_column_text(stmt, 0);
            const text_len = c.sqlite3_column_bytes(stmt, 0);
            if (text_ptr == null) continue;

            const text_slice = text_ptr[0..@intCast(text_len)];
            const owned = allocator.dupe(u8, text_slice) catch continue;
            list.append(allocator, owned) catch {
                allocator.free(owned);
                continue;
            };
        }

        return list;
    }

    pub fn pruneNum(self: *Self, allocator: std.mem.Allocator, table: []const u8, max_commands: usize) !void {
        const count_query = std.fmt.allocPrintSentinel(allocator, "SELECT COUNT(*) FROM \"{s}\";", .{table}, 0) catch unreachable;
        defer allocator.free(count_query);

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, count_query, -1, &stmt, null) != 0) return;
        defer _ = c.sqlite3_finalize(stmt);

        const step_result = try codeToError(c.sqlite3_step(stmt));
        if (step_result != 100) return;

        const count: usize = @intCast(c.sqlite3_column_int(stmt, 0));
        if (count <= max_commands) return;

        const to_delete = count - max_commands;
        const delete_query = std.fmt.allocPrintSentinel(allocator, "DELETE FROM \"{s}\" WHERE id IN (SELECT id FROM \"{s}\" ORDER BY timestamp ASC, id ASC LIMIT {d});", .{ table, table, to_delete }, 0) catch unreachable;
        defer allocator.free(delete_query);

        _ = try codeToError(c.sqlite3_exec(self.db, delete_query, null, null, null));
    }

    pub fn pruneAge(self: *Self, allocator: std.mem.Allocator, table: []const u8, max_age_days: usize) !void {
        const query = std.fmt.allocPrintSentinel(allocator, "DELETE FROM \"{s}\" WHERE timestamp < datetime('now', '-{d} days');", .{ table, max_age_days }, 0) catch unreachable;
        defer allocator.free(query);

        _ = try codeToError(c.sqlite3_exec(self.db, query, null, null, null));
    }

    pub fn deleteCommand(self: *Self, allocator: std.mem.Allocator, command: [:0]const u8) !void {
        const list_query = "SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%';";

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, list_query, -1, &stmt, null) != 0) return;
        defer _ = c.sqlite3_finalize(stmt);

        var tables = std.ArrayList([]const u8).empty;
        defer {
            for (tables.items) |name| allocator.free(name);
            tables.deinit(allocator);
        }

        while (try codeToError(c.sqlite3_step(stmt)) == 100) {
            const name_ptr = c.sqlite3_column_text(stmt, 0);
            const name_len = c.sqlite3_column_bytes(stmt, 0);
            if (name_ptr == null) continue;

            const name = allocator.dupe(u8, name_ptr[0..@intCast(name_len)]) catch continue;
            tables.append(allocator, name) catch {
                allocator.free(name);
                continue;
            };
        }

        for (tables.items) |name| {
            const delete_query = std.fmt.allocPrintSentinel(allocator, "DELETE FROM \"{s}\" WHERE command = ?;", .{name}, 0) catch continue;
            defer allocator.free(delete_query);

            var del_stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, delete_query, -1, &del_stmt, null) != 0) continue;
            defer _ = c.sqlite3_finalize(del_stmt);

            _ = try codeToError(c.sqlite3_bind_text(del_stmt, 1, command.ptr, @intCast(command.len), null));
            _ = try codeToError(c.sqlite3_step(del_stmt));
        }
    }
};
