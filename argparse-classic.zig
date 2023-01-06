const std = @import("std");
const testing = std.testing;

const Severity = enum { all, critical };
const Subcommand = enum { init, update };

const string = []const u8;


pub fn Argparse(comptime result_type: type, comptime name: []const u8, comptime tag: []const u8, comptime config: struct {
    default_required: bool = true,
    subcommand_enum: ?type = null
}) type {
    _ = name;
    _ = tag;

    return struct {
        alloc: std.mem.Allocator,

        const Self = @This();

        pub fn init(alloc: std.mem.Allocator) Self {
            return Self{
                .alloc = alloc
            };
        }

        pub fn flag(self: *Self, long: ?string, short: ?string, help: string) void {
            _ = self;
            _ = long;
            _ = short;
            _ = help;
        }

        pub fn param(self: *Self, comptime parser: anytype, long: ?string, short: ?string, help: string, param_config: struct {
            required: bool = config.default_required,
            default: ?coreTypeOf(returnTypeOf(parser)) = null
        }) void {
            _ = self;
            _ = long;
            _ = short;
            _ = help;
            _ = param_config;
        }

        pub fn subcommand(self: *Self, comptime key: string, comptime help: string) Self {
            // TODO: comptime ensure key is parsable for enum
            // _ = self;
            _ = key;
            _ = help;

            return Self {
                .alloc = self.alloc,
            };
        }

        pub fn printHelp(self: *Self) void {
            _ = self;
        }

        pub fn conclude(self: *Self, result: *result_type, args: []const string) error{missing_arguments, got_help}!void {
            _ = self;
            _ = args;
            // Parse all registered params into result_type{}
            // Is it possible to guarantee a well-defined target struct based on this? Or do we need to make all non-default argments nullable?
            // TODO: Can we comptime create a routine that iterates over all struct-fields, and attempts setting them based on parse-results?
            //       Will at least need to store all flag/param-entries comptime
            result.verbose = false;

            // TODO: in undefined-scenario: Ensure all fields are assigned/set
            //       will put a lot of responsibility on this method to be thorough.
            // return result_type{
            //     .verbose = false,
            //     .logsev = .all,
            //     .subcommand = .{
            //         .update = .{
            //             .force = false
            //         }
            //     }
            // };
        }

        pub fn deinit(self: *Self) void {
            // cleanup
            _ = self;
        }
    };
}

fn maybeOptional(comptime is_optional: bool, comptime return_type: type) type {
    if(is_optional) {
        return ?return_type;
    } else {
        return return_type;
    }
}

fn returnTypeOf(comptime func: anytype) type {
    const typeInfo = @typeInfo(@TypeOf(func));
    if(typeInfo != .Fn) @compileError("Argument must be a function");
    return typeInfo.Fn.return_type.?;
}

// Extract the actual data type, even given error unions or optionals
fn coreTypeOf(comptime typevalue: type) type {
    var typeInfo = @typeInfo(typevalue);
    var coreType = switch(typeInfo) {
        .ErrorUnion => |v| v.payload, // What if error+optional?
        .Optional => |v| v.child,
        else => typevalue
    };

    typeInfo = @typeInfo(typevalue);
    if(typeInfo == .ErrorUnion or typeInfo == .Optional)
        return coreTypeOf(coreType);

    return coreType;
}

const Result = struct {
    verbose: bool,
    logsev: Severity,

    // "Automagic" name?
    subcommand: union(Subcommand) {
        init: struct {
            force: bool,
            file: []const u8,
        },
        update: struct {
            force: bool
        }
    }
};

const ParseError = error {
    NotFound,
    InvalidFormat,
};

fn enumParser(comptime enum_type: type) fn([]const u8) ParseError!enum_type {
    return struct {
        fn func(raw: []const u8) !enum_type {
            return std.meta.stringToEnum(enum_type, raw) orelse ParseError.InvalidFormat;
        }
    }.func;
}

pub inline fn parseInt(val: []const u8) ParseError!usize {
    return std.fmt.parseInt(usize, val, 10) catch {
        return ParseError.InvalidFormat;
    };
}

pub inline fn parseString(val: []const u8) ParseError![]const u8 {
    return val;
}

test "exploration" {
    var argparse = Argparse(
        Result,
        "MyApp", "v1.0.0",
        .{
            .default_required = false,
            .subcommand_enum = Subcommand
        })
        .init(testing.allocator);
    defer argparse.deinit();

    // Global flags
    argparse.flag("--verbose", "-v", "Set verbose");
    argparse.param(enumParser(Severity), "--logsev", null, "help me", .{.default=.all});

    // Subcommand: init
    var sc_init = argparse.subcommand("init", "Initialize a new something");
    sc_init.flag("--force", "-f", "Never stop initing");
    sc_init.param(parseString, "--file", null, "Input-file", .{.required=true});

    // Subcommand: update
    var sc_update = argparse.subcommand("update", "Update something");
    sc_update.flag("--force", "-f", "Never stop updating");

    // Upon errors; print errors + help, then abort
    var result: Result = undefined;
    try argparse.conclude(&result, &.{"init", "--file=some.txt"});
}


test "typeplay" {
    if (true) return error.SkipZigTest;

    const MyType = struct {
        a: usize
    };

    var a = MyType { .a = 0 };

    var b: MyType = blk: {
        var result = .{
            // .a = try parseInt("0"),
        };
        @field(result, "a") = 0;
        break :blk result;
    };

    try testing.expectEqual(a.a, b.a);
}