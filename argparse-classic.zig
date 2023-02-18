// STATUS: FUNCTIONING
const std = @import("std");
const testing = std.testing;
const print = std.debug.print;

pub const ArgparseError = error{
    NotFound,
    InvalidFormat,
    InvalidValue,
    LowerBoundBreach,
    UpperBoundBreach,
};

/// Extract the actual data type, even given error unions or optionals
fn coreTypeOf(comptime typevalue: type) type {
    var typeInfo = @typeInfo(typevalue);
    return switch (typeInfo) {
        .ErrorUnion => |v| coreTypeOf(v.payload),
        .Optional => |v| coreTypeOf(v.child),
        else => typevalue,
    };
}

test "coreTypeOf" {
    try testing.expectEqual(usize, coreTypeOf(usize));
    try testing.expectEqual(usize, coreTypeOf(?usize));
    try testing.expectEqual(usize, coreTypeOf(ArgparseError!usize));
    try testing.expectEqual(usize, coreTypeOf(ArgparseError!?usize));
}

/// Extract the return_type of a function. Results in compilation error if anything but a function is passed.
fn returnTypeOf(comptime func: anytype) type {
    const typeInfo = @typeInfo(@TypeOf(func));
    if (typeInfo != .Fn) @compileError("Argument must be a function");
    return typeInfo.Fn.return_type.?;
}

test "returnTypeOf" {
    try testing.expectEqual(type, returnTypeOf(returnTypeOf));
}

/// Creates a parser supertype, which will be derived into field/type-specific parsers using .createFieldParser
/// This allows us to register a set of parsers, regardless of their return-types and allows us (hopefully) type-safe
/// argument parsing later on.
pub fn ParserForResultType(comptime ResultT: type) type {
    return struct {
        const Self = @This();
        __v: *const VTable,
        pub usingnamespace Methods(Self);

        pub fn Methods(comptime T: type) type {
            return extern struct {
                pub inline fn parse(self: *const T, raw: []const u8, result: *ResultT) ArgparseError!void {
                    try self.__v.parse(@ptrCast(*const ParserForResultType(ResultT), self), raw, result);
                }
            };
        }

        pub const VTable = extern struct {
            parse: *const fn (self: *const ParserForResultType(ResultT), []const u8, *ResultT) ArgparseError!void,
        };

        // Creates a concrete parser for a particular field
        pub fn createFieldParser(comptime field: []const u8, comptime funcImpl: anytype) type {
            // Assert valid type-combo
            comptime {
                // Find field with corresponding name:
                var structField = blk: inline for (@typeInfo(ResultT).Struct.fields) |f| {
                    if (std.mem.eql(u8, field, f.name)) {
                        break :blk f;
                    }
                } else {
                    @compileError("no such field: " ++ @typeName(ResultT) ++ "." ++ field);
                };

                // Verify type-equality
                const coreTypeOfFunc = coreTypeOf(returnTypeOf(funcImpl));
                if (structField.type != coreTypeOfFunc) {
                    @compileError("Incompatible types: field is " ++ @typeName(structField.type) ++ ", parse function returns " ++ @typeName(coreTypeOfFunc));
                }
            }

            // Return the subtype
            return struct {
                usingnamespace Self.Methods(@This());
                __v: *const Self.VTable = &vtable,

                const vtable = Self.VTable{
                    .parse = parseImpl,
                };

                pub fn parseImpl(iself: *const ParserForResultType(ResultT), raw: []const u8, result: *ResultT) ArgparseError!void {
                    _ = @ptrCast(*const @This(), iself);
                    @field(result, field) = try funcImpl(raw);
                }
            };
        }
    };
}

//////////////////////////////
// Parsing helper-functions
//////////////////////////////

/// Parses value as base-10 (ten)
pub inline fn parseInt(val: []const u8) ArgparseError!usize {
    return std.fmt.parseInt(usize, val, 10) catch {
        return ArgparseError.InvalidFormat;
    };
}

pub inline fn parseFloat(val: []const u8) ArgparseError!f64 {
    return std.fmt.parseFloat(f64, val) catch {
        return ArgparseError.InvalidFormat;
    };
}

/// Passthrough
pub inline fn parseString(val: []const u8) ArgparseError![]const u8 {
    return val;
}

/// Always true
pub inline fn _true(_: []const u8) ArgparseError!bool {
    return true;
}

/// Returns a function which returns error if string outside of provided bounds
pub fn lengthedString(comptime min: usize, comptime max: usize) fn ([]const u8) ArgparseError![]const u8 {
    return struct {
        pub fn func(val: []const u8) ArgparseError![]const u8 {
            if (val.len < min) return error.LowerBoundBreach;
            if (val.len > max) return error.UpperBoundBreach;
            return val;
        }
    }.func;
}

/// Returns a function to parse the provided enum type
pub fn parseEnum(comptime enum_type: type) fn ([]const u8) ArgparseError!enum_type {
    return struct {
        fn func(raw: []const u8) !enum_type {
            return std.meta.stringToEnum(enum_type, raw) orelse ArgparseError.InvalidValue;
        }
    }.func;
}

/// Generate a comptime, comma-separated string of all values in an enum
pub fn enumValues(comptime enumType: type) []const u8 {
    comptime {
        const typeInfo = @typeInfo(enumType).Enum;

        // Get required len to be able to store all enum field-names
        var required_len: usize = 0;
        for (typeInfo.fields) |field| {
            required_len += field.name.len + 1; // incl trailing comma
        }

        // Generate comma-separated string of all enum field-names
        var result: [required_len]u8 = undefined;
        var len: usize = 0;

        for (typeInfo.fields) |field| {
            var added_chunk = field.name ++ ",";
            std.mem.copy(u8, result[len..], added_chunk);
            len += added_chunk.len;
        }

        // Trim trailing comma and return:
        return result[0 .. len - 1];
    }
}

/// Generates a function which always will return the specified value
pub fn constant(comptime value: anytype) fn ([]const u8) ArgparseError!@TypeOf(value) {
    return struct {
        fn func(_: []const u8) ArgparseError!@TypeOf(value) {
            return value;
        }
    }.func;
}

const ArgumentType = enum { param, flag };

fn ArgparseEntry(comptime result_type: type) type {
    return struct {
        arg_type: ArgumentType,
        parser: *ParserForResultType(result_type),
        default_provider: ?*ParserForResultType(result_type),
        default_string: ?[]const u8 = null, // A pregenerated string-representation to be used in printHelp
        long: []const u8,
        help: []const u8,
        visited: bool = false, // Used to verify which fields we have processed
    };
}

/// Argparse - basic, type-safe argument parser.
/// The design goal is to provide a minimal-overhead solution with regards to amount of configuration required, while still
/// resulting in a "safe" state if .conclude() succeeds. The main way to achieve this, from a user perspective, is that as
/// part of registering any argument, you will have to provide a parser-function which takes a "string" (slice of u8s) and
/// returns a value of correct type, matching the corresponding struct field identified by the long-form. Some default
/// parsers, and parser-generators are provided; parseString, parseInt, parseEnum(enum_type), lengthedString(min,max)...
///
/// Att! when using .parseString to parse string-arguments, it will simply store the slice-reference, and thus require the
///      corresponding input argument to stay in the same memory as long as it's accessed. A solution to parse to array is
///      on the way (TODO)
///
/// Supported features:
///    flag: --longform
///    parameter: --longform=value
///
/// Planned features:
///    subcommand
///    shortform flag and parameter: -s
///    positional arguments? TBD. Not a priority
///    space-separated parameters in addition to =-separated? TBD. Not a priority.
///    Formalize default-value presentation in help
///
/// Main API:
///   .init()
///   .deinit()
///
///   .param() - Register a new argument-config corresponding to a field in the destination struct. All fields in struct must be configured.
///                 Currently, the long-form name of the argument must be 1:1 (without the dashes) with the corresponding struct-field.
///   .flag() - Register a value-less parameter. Will set accociated field to true if passed, otherwise false.
///   .conclude() - Ensures that all struct-fields have a matching argument-configuration, as well as executes all parsers.
///                 If this succeeds, then you shall be safe that the result-struct is well-defined and ready to use.
///
/// Concepts to explore: 
///   Initiate the entire argument_list comptime. Either using comptime-block for population, or devising an inline-structure that can be passed as a whole.
/// 
pub fn Argparse(comptime result_type: type) type {
    return struct {
        const Self = @This();
        const Parser = ParserForResultType(result_type);

        argument_list: std.StringHashMap(ArgparseEntry(result_type)),
        visited_list: std.StringHashMap(bool),

        allocator: std.mem.Allocator,
        help_head: ?[]const u8,
        help_tail: ?[]const u8,

        pub fn init(allocator: std.mem.Allocator, init_params: struct {
            help_head: ?[]const u8 = null,
            help_tail: ?[]const u8 = null
        }) Self {
            return .{
                .allocator = allocator,
                .argument_list = std.StringHashMap(ArgparseEntry(result_type)).init(allocator),
                .visited_list = std.StringHashMap(bool).init(allocator),
                .help_head = init_params.help_head,
                .help_tail = init_params.help_tail,
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.argument_list.valueIterator();
            while (it.next()) |field| {
                self.allocator.destroy(field.parser);
                if (field.default_provider) |default| {
                    self.allocator.destroy(default);
                }
            }

            self.argument_list.deinit();
            self.visited_list.deinit();
        }

        pub fn conclude(self: *Self, result: *result_type, args: []const []const u8, writer: anytype) !void {
            // Phase 1: Evaluate all input-arguments according to configurations

            // Resetting visited-list
            self.visited_list.clearAndFree();
            for (args) |arg| {
                if (arg.len < 3) {
                    writer.print("error: invalid argument format. Expected '--<argname>', got '{s}'.\n", .{arg}) catch {};
                    return error.InvalidFormat;
                }
                if (!std.mem.startsWith(u8, arg, "--")) {
                    writer.print("error: invalid argument format. Should start with '--', got '{s}'.\n", .{arg}) catch {};
                    return error.InvalidFormat;
                }

                if (std.mem.eql(u8, arg, "--help")) {
                    try self.printHelp(writer);
                    return error.GotHelp;
                }

                // Check if flag or argument (has = or not)
                if (std.mem.indexOf(u8, arg, "=")) |eql_idx| {
                    var key = arg[2..eql_idx];
                    var val = arg[eql_idx + 1 ..];

                    if (self.argument_list.get(key)) |field_def| {
                        if (self.visited_list.get(key) != null) {
                            writer.print("error: '{s}' already processed\n", .{key}) catch {};
                            return error.InvalidFormat;
                        }
                        try self.visited_list.put(key, true);

                        // Expect param-definiton
                        if (field_def.arg_type != .param) {
                            writer.print("error: got parameter-style for non-parameter '{s}'\n", .{key}) catch {};
                            return error.InvalidFormat;
                        }

                        //
                        field_def.parser.parse(val, result) catch |e| {
                            writer.print("error: got error parsing {s}-value '{s}': {s}\n", .{ key, val, @errorName(e) }) catch {};
                            return error.InvalidFormat;
                        };
                    } else {
                        writer.print("error: argument '{s}' not supported.\n", .{key}) catch {};
                        return error.NoSuchArgument;
                    }
                } else {
                    var key = arg[2..];
                    if (self.argument_list.get(key)) |field_def| {
                        if (self.visited_list.get(key) != null) {
                            writer.print("error: '{s}' already processed\n", .{key}) catch {};
                            return error.InvalidFormat;
                        }
                        try self.visited_list.put(key, true);

                        if (field_def.arg_type != .flag) {
                            writer.print("error: got flag-style for non-flag '{s}'\n", .{key}) catch {};
                            return error.InvalidFormat;
                        }

                        field_def.parser.parse("", result) catch |e| {
                            writer.print("error: got error storing value for flag '{s}': {s}\n", .{ key, @errorName(e) }) catch {};
                            return error.InvalidFormat;
                        };
                    } else {
                        writer.print("error: argument '{s}' not supported.\n", .{key}) catch {};
                        return error.NoSuchArgument;
                    }
                }
            }

            // Phase 2: check all unvisited, handle eventual defaults. Will also detect unconfigured fields.
            const info = @typeInfo(result_type);

            var conclusion: bool = true;

            inline for (info.Struct.fields) |field| {
                switch (@typeInfo(field.type)) {
                    .Union => {
                        @compileError("Unions are reserved for subcommands, which is not yet supported");
                    },
                    .Struct, .Fn => {
                        @compileError("Unsupported field type: " ++ @typeName(field.type));
                    },
                    else => {
                        // Visited? (e.g. handled)
                        if (self.visited_list.get(field.name) == null) {
                            // Get entry, and evaluate optional/required and eventual default
                            if (self.argument_list.get(field.name)) |arg_entry| {
                                switch (arg_entry.arg_type) {
                                    .flag => {
                                        // Optional by design, set to false
                                        // For some reason we have to check the type here, as seemingly all branches are evaluated during compile-time
                                        if (@TypeOf(@field(result, field.name)) == bool) {
                                            @field(result, field.name) = false;
                                        }
                                    },
                                    .param => {
                                        // Check for required or default
                                        if (arg_entry.default_provider) |default_provider| {
                                            // if provided default: set field to default
                                            // @field(result, field.name) = default_value; <-- test this approach if we can store the actual type
                                            try default_provider.parse("", result);
                                        } else {
                                            // if required: error
                                            writer.print("error: missing required argument '{s}'\n", .{arg_entry.long}) catch {};
                                            conclusion = false;
                                        }
                                    },
                                }
                            } else {
                                // TODO: Could we really solve this comptime? Assume we must pass the entire config-struct in one pass though.
                                // Found field in struct that is not configured - error
                                writer.print("error: Field {s}.{s} is not configured\n", .{ @typeName(result_type), field.name }) catch {};
                                return error.IncompleteConfiguration;
                            }
                        }
                    },
                }
            }

            if(!conclusion) return error.InvalidFormat;
        }

        // A parameter is an argument with a value (--key=value). If a default-value is provided in the params-struct, it will be considered optional.
        pub fn param(self: *Self, comptime long: []const u8, comptime parseFunc: anytype, comptime help_text: []const u8, comptime params: struct { default: ?coreTypeOf(returnTypeOf(parseFunc)) = null }) !void {
            if (!(long[0] == '-' and long[1] == '-')) @compileError("Invalid argument format. It must start with '--'. Found: " ++ long);
            const field = long[2..];

            // Require 'long' to start with --, and derive fieldname from this. TBD: support override via param-struct to allow disconnected names.
            // Parser.createFieldParser will also verify that field exists in struct

            const parser_func_ptr = try self.allocator.create(Parser.createFieldParser(field, parseFunc));
            parser_func_ptr.* = .{};

            var default_string: ?[]const u8 = null;
            comptime {
                if (params.default) |default| {
                    default_string = comptimeValueString(default);
                }
            }

            // If default-value provided; Generate a "parser" that always returns the default-value
            const default_func_ptr = blk: {
                if (params.default) |default| {
                    var ptr = try self.allocator.create(Parser.createFieldParser(field, constant(default)));
                    ptr.* = .{};
                    break :blk @ptrCast(*Parser, ptr);
                } else {
                    break :blk null;
                }
            };

            try self.argument_list.put(field, .{
                .arg_type = .param,
                .parser = @ptrCast(*Parser, parser_func_ptr),
                .default_provider = default_func_ptr,
                .default_string = default_string,
                .long = long,
                .help = help_text,
            });
        }

        // A flag is an argument without a value. If provided, the corresponding field will be set to true, otherwise to false.
        // It is by convention optional.
        pub fn flag(self: *Self, comptime long: []const u8, comptime help_text: []const u8) !void {
            if (!(long[0] == '-' and long[1] == '-')) @compileError("Invalid argument format. It must start with '--'. Found: " ++ long);
            const field = long[2..];

            // Flags don't have values, thus a function that always returns true is used            
            var parser_func_ptr = try self.allocator.create(Parser.createFieldParser(field, _true));
            parser_func_ptr.* = .{};

            try self.argument_list.put(field, .{
                .arg_type = .flag,
                .parser = @ptrCast(*Parser, parser_func_ptr),
                .default_provider = null,
                .long = long,
                .help = help_text,
            });
        }

        // Prints a pretty-formatted help of all the registered params and flags
        pub fn printHelp(self: *Self, writer: anytype) !void {
            if (self.help_head) |text| writer.print("{s}\n", .{text}) catch {};

            // Print usage-example:
            writer.print("\nUsage: \n", .{}) catch {};
            writer.print("waxels ", .{}) catch {};
            if (self.argument_list.count() > 0) {
                // All required parameters
                var it = self.argument_list.iterator();
                while (it.next()) |field| if (field.value_ptr.arg_type == .param and field.value_ptr.default_provider == null) {
                    print("{s}=... ", .{field.value_ptr.long});
                };

                // All optional parameters (has defaults)
                it = self.argument_list.iterator();
                while (it.next()) |field| if (field.value_ptr.arg_type == .param and field.value_ptr.default_provider != null) {
                    print("[{s}=...] ", .{field.value_ptr.long});
                };

                // All flags
                it = self.argument_list.iterator();
                while (it.next()) |field| if (field.value_ptr.arg_type == .flag) {
                    print("[{s}] ", .{field.value_ptr.long});
                };
            }
            writer.print("\n", .{}) catch {};

            // List all arguments
            if (self.argument_list.count() > 0) {
                writer.print("\nArguments/flags:\n", .{}) catch {};

                // TODO: Ordered? Split by param/flag?
                var scrap = try std.BoundedArray(u8, 128).init(0);
                var scrapwriter = scrap.writer();

                var it = self.argument_list.iterator();
                while (it.next()) |field| {
                    scrap.resize(0) catch {}; // resizing to 0 can't fail.
                    _ = scrapwriter.write(field.value_ptr.long) catch {};
                    
                    switch (field.value_ptr.arg_type) {
                        .param => {
                            _ = scrapwriter.write("=<val>") catch {};
                        },
                        .flag => {},
                    }
                    writer.print("  {s:<18} {s}", .{ scrap.slice(), field.value_ptr.help }) catch {};
                    
                    if(field.value_ptr.default_string) |default| {
                        writer.print(" (default={s})", .{default}) catch {};
                    }

                    writer.print("\n", .{}) catch {};
                }

                writer.print("\n", .{}) catch {};
            }

            if (self.help_tail) |text| writer.print("{s}\n", .{text}) catch {};
        }
    };
}

test "argparse shall support arbitrary argument types" {
    const Result = struct { a: usize, b: []const u8 };
    var parser = Argparse(Result).init(std.testing.allocator, .{});
    defer parser.deinit();

    try parser.param("--a", parseInt, "", .{});
    try parser.param("--b", parseString, "", .{});

    var result: Result = undefined;
    try parser.conclude(&result, &.{ "--a=123", "--b=321" }, std.io.getStdErr().writer());
    try testing.expect(result.a == 123);
    try testing.expectEqualStrings("321", result.b);
}

const mtest = @import("mtest.zig");

test "argparse.printHelp() shall print head and tail text, if provided" {
    const MyResult = struct {};

    var parser = Argparse(MyResult).init(std.testing.allocator, .{
        .help_head = "MyApp v1.0",
        .help_tail = "(c) Michael Odden"
    });
    defer parser.deinit();

    var output_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer output_buf.deinit();

    try parser.printHelp(output_buf.writer());

    try mtest.expectStringContains(output_buf.items, "MyApp v1.0");
    try mtest.expectStringContains(output_buf.items, "(c) Michael Odden");
}

test "argparse.printHelp() shall print help-text for all params" {
    const MyResult = struct { a: usize };

    var parser = Argparse(MyResult).init(std.testing.allocator, .{
        .help_head = "MyApp v1.0",
        .help_tail = "(c) Michael Odden"
    });
    defer parser.deinit();

    var output_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer output_buf.deinit();

    try parser.param("--a", parseInt, "help text for 'a'", .{});

    try parser.printHelp(output_buf.writer());

    try mtest.expectStringContains(output_buf.items, "--a");
    try mtest.expectStringContains(output_buf.items, "help text for 'a'");
}

test "argparse given '--help' shall show help and abort evaluation" {
    const MyResult = struct {};
    var parser = Argparse(MyResult).init(std.testing.allocator, .{ .help_head = "Help-test" });
    defer parser.deinit();

    var output_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer output_buf.deinit();

    var result: MyResult = undefined;
    try testing.expectError(error.GotHelp, parser.conclude(&result, &.{"--help"}, output_buf.writer()));

    try mtest.expectStringContains(output_buf.items, "Help-test");
}

test "argparse shall support value-less bool-backed parameters, i.e. flags. True if set, otherwise false." {
    // Initiate
    const MyResult = struct { myflag: bool };

    var parser = Argparse(MyResult).init(std.testing.allocator, .{});
    defer parser.deinit();

    try parser.flag("--myflag", "flag goes here");

    // Evaluate
    var result: MyResult = undefined;

    // Test without flag
    try parser.conclude(&result, &.{}, std.io.getStdErr().writer());
    try testing.expect(!result.myflag);

    // Test with flag
    try parser.conclude(&result, &.{"--myflag"}, std.io.getStdErr().writer());
    try testing.expect(result.myflag);

    // Test without flag
    try parser.conclude(&result, &.{}, std.io.getStdErr().writer());
    try testing.expect(!result.myflag);
}

test "argparse shall support enums" {
    const Severity = enum { INFO, WARNING, ERROR };
    const MyResult = struct { severity: Severity };

    var parser = Argparse(MyResult).init(std.testing.allocator, .{});
    defer parser.deinit();

    try parser.param("--severity", parseEnum(Severity), "Valid values=" ++ enumValues(Severity), .{});

    var result: MyResult = undefined;
    try parser.conclude(&result, &.{"--severity=WARNING"}, std.io.getStdErr().writer());

    try testing.expect(result.severity == .WARNING);
}

test "argparse shall support optional arguments via default values" {
    const MyResult = struct { a: usize };

    var parser = Argparse(MyResult).init(std.testing.allocator, .{});
    defer parser.deinit();

    try parser.param("--a", parseInt, "Optional argument, default=21", .{ .default = 21 });

    // Check for default
    var result: MyResult = undefined;
    try parser.conclude(&result, &.{}, std.io.getStdErr().writer());
    try testing.expect(result.a == 21);

    // Check for specific
    try parser.conclude(&result, &.{"--a=84"}, std.io.getStdErr().writer());
    try testing.expect(result.a == 84);
}

fn comptimeValueString(comptime value: anytype) []const u8 {
    const typeOf = @TypeOf(value);
    const typeInfo = @typeInfo(typeOf);

    return switch(typeInfo) {
        .ComptimeInt, .Int, .Float => std.fmt.comptimePrint("{d}", .{value}),
        .EnumLiteral, .Enum => std.fmt.comptimePrint("{s}", .{@tagName(value)}),
        else => std.fmt.comptimePrint("{s}", .{value}),
    };
}

test "valueString" {
    _ = comptimeValueString(1);
    _ = comptimeValueString(@as(usize, 2));
    _ = comptimeValueString(@as(f64, 3.123));
    _ = comptimeValueString("value");
    _ = comptimeValueString(.val1);
}

// test "comptime all the way?" {
//     Initiate the entire configuration in a comptime list/map, evaluated for completeness at comptime. Then only the actual parsing will finally be done runtime
//     var parser = Argparse(Result).init(&.{
//         .{}
//     });
// }

// Plan:
// Incorporate this into argparse, which will handle allocations, and final evaluations
// ... including verifications that all fields are configured at time of .conclude()
