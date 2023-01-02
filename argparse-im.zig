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

const ArgList = []const []const u8;

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

    fn checkHelp(self: *Self, args: ArgList) void {
        if(self.optionalFlag(args, "--help", "-h", "Prints help")) {
            self.gotHelp = true;
        }
    }

    // Returns true/false wether or not a given flag is encountered
    fn optionalFlag(self: *Self, args: ArgList, comptime long: ?[]const u8, comptime short: ?[]const u8, help: []const u8) bool {
        // TODO: verify no dupes
        self.discoveredParams.append(.{
            .long = long,
            .short = short,
            .help = help
        }) catch {};

        for(args) |arg| {
            // If we encounter something not flag/param-like: abort. Assumes it's a subcommand
            // TODO: This is not enough if we are to support positional arguments, or space-separated arg-values
            if(arg.len > 0 and arg[0] != '-') break;

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

    fn optionalParam(self: *Self, args: ArgList, comptime long: ?[]const u8, comptime short: ?[]const u8, help: []const u8) ?[]const u8 {
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
            // If we encounter something not flag/param-like: abort. Assumes it's a subcommand
            // TODO: This is not enough if we are to support positional arguments, or space-separated arg-values
            if(arg.len > 0 and arg[0] != '-') break null;

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

    fn subcommand(self: *const Self, args: ArgList, comptime command: []const u8) ?ArgList {
        _ = self;
        // Return the tail-slice after the subcommand-arg, if found. Otherwise null.
        return for(args) |arg, i| {
            if(std.mem.indexOf(u8, arg, command) != null) {
                break args[i+1..];
            }
        } else null;
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

test "subcommand" {
    var argparse = Argparse.init("Waxels", "0.0.1-testbuild");

    // --all is a subcommand-specific flag, and should not be "picked up" by the global flag extraction
    var args = &.{"-v", "update","--all", "--input=file"};

    // global flag
    try testing.expect(argparse.optionalFlag(args, null, "-v", ""));

    // sc-specific flag and param
    try testing.expect(!argparse.optionalFlag(args, "--all", null, ""));
    try testing.expect(argparse.optionalParam(args, "--input", null, "") == null);

    var maybe_sc_update_args = argparse.subcommand(args, "update");
    try testing.expect(maybe_sc_update_args != null);

    var sc_update_args = maybe_sc_update_args.?;
    try testing.expect(!argparse.optionalFlag(sc_update_args, null, "-v", ""));
    try testing.expect(argparse.optionalFlag(sc_update_args, "--all", null, ""));
    try testing.expectEqualStrings("file", argparse.optionalParam(sc_update_args, "--input", null, "").?);
    
    // try testing.expectEqualStrings("update", sc_update.)
    // Every arg-check now belongs to the subcommand?
    // TODO: Att! The main help needs to list all subcommands

}

// test "full waxels inputset" {
//     var argparse = Argparse.init("Waxels", "0.0.1-testbuild");
//     defer {
//         if(!argparse.conclude()) {
//             std.process.exit(1);
//         }
//     }

//     var args = &.{"--bitdepth=16"};

//     // TBD: have default and type-info as param-set to optionalParam(), or as a separate fine-grained method?
//     var bitdepth = argparse.paramWithDefault(args, "--bitdepth", "-b", usize, 16);
//     var bitdepth = argparse.paramWithDefault(args, "--bitdepth", "-b", usize, 16);
//     _ = bitdepth;
// }


// notes
//   - subcommand() can return a slice with only the subcommand-specific arguments
//   - get arg can take argument re type to convert to (or a converter-function)