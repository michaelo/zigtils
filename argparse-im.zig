// "immediate mode"-argparse exploration
// Currently requiring arguments to be comptile time known

const std = @import("std");
const testing = std.testing;
const print = std.debug.print;

pub fn expectStringContains(actual: []const u8, expected_contains: []const u8) !void {
    if (std.mem.indexOf(u8, actual, expected_contains) != null)
        return;

    print("\n======= expected to contain: =========\n", .{});
    print("{s}\n", .{expected_contains});
    print("\n======== actual contents: ============\n", .{});
    print("{s}\n", .{actual});
    print("\n======================================\n", .{});

    return error.TestExpectedContains;
}

const ParseError = error {
    InvalidFormat
};

const Entry = struct {
    long: ?[]const u8,
    short: ?[]const u8,
    help: []const u8,
};

// Common parser functions

pub inline fn parseInt(val: []const u8) ParseError!usize {
    return std.fmt.parseInt(usize, val, 10) catch {
        return .InvalidFormat;
    };
}

pub inline fn parseString(val: []const u8) ParseError![]const u8 {
    return val;
}

// Main struct
// TODO: Might store the arg-list so we better can keep track of state over time (e.g. consumption of position-dependent parameters)
const Argparse = struct {
    const Self = @This();

    name: []const u8,
    versionTag: []const u8,
    errors: std.BoundedArray([]const u8, 32),
    gotHelp: bool = false,

    discoveredParams: std.BoundedArray(Entry, 128),

    fn init(name: []const u8, versionTag: []const u8) Self {
        return Self{
            .name = name,
            .versionTag = versionTag,
            .errors = std.BoundedArray([]const u8, 32).init(0) catch unreachable,
            .discoveredParams = std.BoundedArray(Entry, 128).init(0) catch unreachable
        };
    }

    fn checkHelp(self: *Self, args: []const []const u8) void {
        if(self.optionalFlag(args, "--help", "-h", "Prints help")) {
            self.gotHelp = true;
        }
    }

    // Returns true/false wether or not a given flag is encountered
    fn optionalFlag(self: *Self, args: []const []const u8, comptime long: ?[]const u8, comptime short: ?[]const u8, help: []const u8) bool {
        // TODO: verify no dupes
        self.discoveredParams.append(.{
            .long = long,
            .short = short,
            .help = help
        }) catch {};

        for(args) |arg| {
            if(short) |key| {
                if(std.mem.eql(u8, arg, key)) {
                    return true;
                }
            }

            if(long) |key| {
                if(std.mem.eql(u8, arg, key)) {
                    return true;
                }
            }
        }

        return false;
    }

    fn optionalParam(self: *Self, args: []const []const u8, comptime long: ?[]const u8, comptime short: ?[]const u8, help: []const u8) ?[]const u8 {
        // TODO: verify no dupes
        self.discoveredParams.append(.{
            .long = long,
            .short = short,
            .help = help
        }) catch {};

        if(long == null and short == null) {
            @compileError("both long and short variant can't be null");
        }

        var maybe_idx = for(args) |arg, i| {
            if(short) |key| {
                if(std.mem.startsWith(u8, arg, key ++ "=")) {
                    break i;
                }
            }

            if(long) |key| {
                if(std.mem.startsWith(u8, arg, key ++ "=")) {
                    break i;
                }
            }
        } else null;

        if(maybe_idx) |idx| {
            // Extract value
            var field = args[idx];
            if(std.mem.indexOf(u8, field, "=")) |eql| {
                var value = field[eql+1..];
                if(value.len > 0) {
                    return value;
                } else {
                    self.errors.append("Expected value for param: " ++ (long orelse short)) catch {};
                }
            }
        }

        return null;
    }

    // fn requiredFlag() <- automatically adds error

    // TODO: prettify
    fn showHelp(self: *const Self, writer: anytype) void {
        writer.print("{s} {s}\n\n", .{self.name, self.versionTag}) catch {};

        for(self.discoveredParams.slice()) |param| {
            var help = param.help;

            // padding
            writer.print("  ", .{}) catch {};
            if(param.short) |key| {
                writer.print("{s}", .{key}) catch {};
            }
            if(param.short != null and param.long != null) {
                writer.print(",", .{}) catch {};
            }
            if(param.long) |key| {
                writer.print("{s}", .{key}) catch {};
            }      

            writer.print("\t{s}\n", .{help}) catch {};
        }
    }

    // Final step, will return true/false according to validations + print all 
    fn conclude(self: *const Self, writer: anytype) bool {
        // Check for any errors, print them, and if any: return false. Otherwise OK
        var allOk: bool = !self.gotHelp and self.errors.len == 0;

        if (!self.gotHelp) for(self.errors.slice()) |err| {
            writer.print("ERROR: {s}", .{err}) catch {};
        };

        if(!allOk) {
            self.showHelp(writer);
        }

        return allOk;
    }
};

test "argparse with no args is OK" {
    var outputbuffer = std.ArrayList(u8).init(std.testing.allocator);
    defer outputbuffer.deinit();

    var argparse = Argparse.init("My app", "v1.0-test");
    try testing.expect(argparse.conclude(outputbuffer.writer()));
    
    try testing.expectEqualStrings(outputbuffer.items, "");
}

test "argparse shall show help with -h/--help" {
    var outputbuffer = std.ArrayList(u8).init(std.testing.allocator);
    defer outputbuffer.deinit();

    var argparse = Argparse.init("My app", "v1.0-test");
    argparse.checkHelp(&.{"--help"});
    try testing.expect(!argparse.conclude(outputbuffer.writer()));
    
    try expectStringContains(outputbuffer.items, "My app");
    try expectStringContains(outputbuffer.items, "v1.0-test");
}

test "argparse help shall print all introduced flags/params" {
    var outputbuffer = std.ArrayList(u8).init(std.testing.allocator);
    defer outputbuffer.deinit();

    var args = &.{"--help"};

    var argparse = Argparse.init("My app", "v1.0-test");
    argparse.checkHelp(args);

    _ = argparse.optionalFlag(args, "--verbose", "-v", "Prints lots more debug info");
    try testing.expect(!argparse.conclude(outputbuffer.writer()));

    try expectStringContains(outputbuffer.items, "-h");
    try expectStringContains(outputbuffer.items, "--help");
    try expectStringContains(outputbuffer.items, "Prints help");

    try expectStringContains(outputbuffer.items, "--verbose");
}

test "argparse shall provide argument values" {
    var args = &.{"--key=value"};

    var outputbuffer = std.ArrayList(u8).init(std.testing.allocator);
    defer outputbuffer.deinit();

    var argparse = Argparse.init("My app", "v1.0-test");

    try testing.expectEqualStrings(argparse.optionalParam(args, "--key", null, "Some key, out there").?, "value");

    // debug
    argparse.showHelp(std.io.getStdErr().writer());
}

test "full waxels inputset" {
    var argparse = Argparse.init("Waxels", "0.0.1-testbuild");
    defer {
        if(!argparse.conclude()) {
            std.process.exit(1);
        }
    }

    // TBD: have default and type-info as param-set to optionalParam(), or as a separate fine-grained method?
    var bitdepth = argparse.paramWithDefault(args, "--bitdepth", null, 16);
}

// notes
//   - subcommand() can return a slice with only the subcommand-specific arguments
//   - get arg can take argument re type to convert to (or a converter-function)