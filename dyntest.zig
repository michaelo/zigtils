const std = @import("std");
const testing = std.testing;
const print = std.debug.print;

pub const ParseError = error{
    NotFound,
    InvalidFormat,
    LowerBoundBreach,
    UpperBoundBreach,
};

// Extract the actual data type, even given error unions or optionals
fn coreTypeOf(comptime typevalue: type) type {
    var typeInfo = @typeInfo(typevalue);
    var coreType = switch (typeInfo) {
        .ErrorUnion => |v| v.payload, // What if error+optional?
        .Optional => |v| v.child,
        else => typevalue,
    };

    typeInfo = @typeInfo(typevalue);
    if (typeInfo == .ErrorUnion or typeInfo == .Optional)
        return coreTypeOf(coreType);

    return coreType;
}

fn returnTypeOf(comptime func: anytype) type {
    const typeInfo = @typeInfo(@TypeOf(func));
    if (typeInfo != .Fn) @compileError("Argument must be a function");
    return typeInfo.Fn.return_type.?;
}

// Creates a parser supertype, which will be derived into field/type-specific parsers using .createFieldParser
// This allows us to register a set of parsers, regardless of their return-types and allows us (hopefully) type-safe
// argument parsing later on.
pub fn ParserForResultType(comptime ResultT: type) type {
    return struct {
        const Self = @This();
        __v: *const VTable,
        pub usingnamespace Methods(Self);

        pub fn Methods(comptime T: type) type {
            return extern struct {
                pub inline fn parse(self: *const T, raw: []const u8, result: *ResultT) ParseError!void {
                    try self.__v.parse(@ptrCast(*const ParserForResultType(ResultT), self), raw, result);
                }
            };
        }

        pub const VTable = extern struct {
            parse: *const fn(self: *const ParserForResultType(ResultT), []const u8, *ResultT) ParseError!void,
        };

        // Creates a concrete parser for a particular field
        pub fn createFieldParser(comptime field: []const u8, comptime funcImpl: anytype) type {
            // Assert valid type-combo
            comptime {
                // Find field with corresponding name:
                var structField = blk: inline for (@typeInfo(ResultT).Struct.fields) |f| {
                    if(std.mem.eql(u8, field, f.name)) {
                        break :blk f;
                    }
                } else {
                    @compileError("no such field: " ++ @typeName(ResultT) ++ "." ++ field);
                };

                // Verify type-equality
                const coreTypeOfFunc = coreTypeOf(returnTypeOf(funcImpl));
                if(structField.type != coreTypeOfFunc) {
                    @compileError("Incompatible types: field is " ++ @typeName(structField.type) ++ ", parse function returns " ++ @typeName(coreTypeOfFunc));
                }
            }

            // Return the subtype
            return struct {
                usingnamespace Self.Methods(@This());
                __v: *const Self.VTable = &vtable,

                const vtable = Self.VTable {
                    .parse = parseImpl,
                };

                pub fn parseImpl(iself: *const ParserForResultType(ResultT), raw: []const u8, result: *ResultT) ParseError!void {
                    _ = @ptrCast(*const @This(), iself);
                    @field(result, field) = try funcImpl(raw);
                }
            };
        }
    };
}

// Parses value as base-10 (ten)
pub inline fn parseInt(val: []const u8) ParseError!usize {
    return std.fmt.parseInt(usize, val, 10) catch {
        return ParseError.InvalidFormat;
    };
}

// Passthrough
pub inline fn parseString(val: []const u8) ParseError![]const u8 {
    return val;
}

// Always true
pub inline fn _true(_: []const u8)  ParseError!bool {
    return true;
}

// Returns a function which returns error if string outside of provided bounds
pub fn lengthedString(comptime min: usize, comptime max: usize) fn([]const u8)ParseError![]const u8 {
    return struct {
        pub fn func(val: []const u8) ParseError![]const u8 {
            if(val.len < min) return error.LowerBoundBreach;
            if(val.len > max) return error.UpperBoundBreach;
            return val;
        }
    }.func;
}

// Returns a function to parse the provided enum type
pub fn parseEnum(comptime enum_type: type) fn ([]const u8) ParseError!enum_type {
    return struct {
        fn func(raw: []const u8) !enum_type {
            return std.meta.stringToEnum(enum_type, raw) orelse ParseError.InvalidFormat;
        }
    }.func;
}

// Generate a comptime, comma-separated string of all values in an enum
pub fn enumValues(comptime enumType: type) []const u8 {
    comptime {
        const typeInfo = @typeInfo(enumType).Enum;

        // Get required len to be able to store all enum field-names
        var required_len: usize = 0;
        for(typeInfo.fields) |field| {
            required_len += field.name.len+1; // incl trailing comma
        }

        // Generate comma-separated string of all enum field-names
        var result: [required_len]u8 = undefined;
        var len: usize = 0;

        for(typeInfo.fields) |field| {
            var added_chunk = field.name ++ ",";
            std.mem.copy(u8, result[len..], added_chunk);
            len += added_chunk.len;
        }

        // Trim trailing comma and return:
        return result[0..len-1];
    }
}

pub fn constant(comptime value: anytype) fn([]const u8)ParseError!@TypeOf(value) {
    return struct {
        fn func(_: []const u8) ParseError!@TypeOf(value) {
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
        long: []const u8,
        help: []const u8,
        visited: bool = false, // Used to verify which fields we have processed
    };
}

// Argparse - basic, type-safe argument parser.
// The design goal is to provide a minimal-overhead solution with regards to amount of configuration required, while still 
// resulting in a "safe" state if .conclude() succeeds.
// 
// Att! when using .parseString to parse string-arguments, it will simply store the slice-reference, and thus require the 
//      corresponding input argument to stay in the same memory as long as it's accessed. A solution to parse to array is 
//      on the way (TODO)
//
// Supported features:
//    flag: --longform
//    parameter: --longform=value
// 
// Planned features:
//    subcommand
//    shortform flag and parameter: -s 
//    positional arguments? TBD. Not a priority
//    space-separated parameters in addition to =-separated? TBD. Not a priority.
//
// Main API:
//   .init()
//   .deinit()
//   
//   .param() - Register a new argument-config corresponding to a field in the destination struct. All fields in struct must be configure, .{}d.
//                 Currently, the long-form name of the argument must be 1:1 (without the dashes) with the corresponding struct-field.
//   .conclude() - Ensures that all struct-fields have a matching argument-configuration, as well as executes all parsers.
//                 If this succeeds, then you shall be safe that the result-struct is well-defined and ready to use.
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
            while(it.next()) |field| {
                self.allocator.destroy(field.parser);
                if(field.default_provider) |default| {
                    self.allocator.destroy(default);
                }
            }

            self.argument_list.deinit();
            self.visited_list.deinit();
        }

        fn areAllFieldsConfigured(self: *Self, writer: anytype) bool {
            var result = true;
            const info = @typeInfo(result_type);
        
            inline for (info.Struct.fields) |field| {
                switch(@typeInfo(field.type)) {
                    .Union => {
                        @compileError("Subcommands not yet supported");
                        // inline for(value.fields) |union_field| {
                        //     if(!evaluate(union_field.type, lookup_list, prefix ++ field.name ++ "." ++ union_field.name ++ ".")) {
                        //         result = false;
                        //     }
                        // }
                    },
                    .Struct => {
                        @compileError("Nonsensical. No logic idea of what structs should represent here.");
                    },
                    else => {
                        if (self.argument_list.get(field.name) == null){
                            // TODO: Can we solve this comptime? Assume we must pass the entire config-struct in one pass though.
                            writer.print("error: Field {s}.{s} is not configured\n", .{@typeName(result_type), field.name}) catch {};
                            result = false;
                        }
                    }
                }
            }
        
            return result;
        }

        fn evaluateParam() void {

        }

        fn evaluateFlag() void {

        }

        pub fn conclude(self: *Self, result: *result_type, args: []const []const u8, writer: anytype) !void {
            // Phase 1: Evaluate that all fields are configured
            if(!self.areAllFieldsConfigured(writer)) return error.IncompleteConfiguration;

            // Resetting visited-list
            self.visited_list.clearAndFree();

            // Phase 2: Attempt parse to result
            for(args) |arg| {
                if(arg.len < 3) {
                    writer.print("error: invalid argument format. Expected '--argname', got {s}.\n", .{arg}) catch {};
                    return error.InvalidFormat;
                }
                if(!std.mem.startsWith(u8, arg, "--")) {
                    writer.print("error: invalid argument format. Should start with --, got {s}.\n", .{arg}) catch {};
                    return error.InvalidFormat;
                }

                if(std.mem.eql(u8, arg, "--help")) {
                    try self.printHelp(writer);
                    return error.GotHelp;
                }

                // Check if flag or argument (has = or not)
                if(std.mem.indexOf(u8, arg, "=")) |eql_idx| {
                    var key = arg[2..eql_idx];
                    var val = arg[eql_idx+1..];

                    if(self.argument_list.get(key)) |field_def| {
                        if(self.visited_list.get(key) != null) {
                            writer.print("error: '{s}' already processed\n", .{key}) catch {};
                            return error.InvalidFormat;
                        }
                        try self.visited_list.put(key, true);

                        // Expect param-definiton
                        if(field_def.arg_type != .param) {
                            writer.print("error: got parameter-style for non-parameter '{s}'\n", .{key}) catch {};
                            return error.InvalidFormat;
                        }

                        // 
                        field_def.parser.parse(val, result) catch |e| {
                            writer.print("error: got error parsing {s}-value '{s}': {s}\n", .{key,val, @errorName(e)}) catch {};
                            return error.InvalidFormat;
                        };
                    } else {
                        writer.print("error: argument '{s}' not supported.\n", .{key}) catch {};
                        return error.NoSuchArgument;
                    }
                } else {
                    // TODO: handle seems-to-be-flag
                    var key = arg[2..];
                    if(self.argument_list.get(key)) |field_def| {
                        if(self.visited_list.get(key) != null) {
                            writer.print("error: '{s}' already processed\n", .{key}) catch {};
                            return error.InvalidFormat;
                        }
                        try self.visited_list.put(key, true);

                        if(field_def.arg_type != .flag) {
                            writer.print("error: got flag-style for non-flag '{s}'\n", .{key}) catch {};
                            return error.InvalidFormat;
                        }

                        field_def.parser.parse("", result) catch |e| {
                            writer.print("error: got error storing value for flag '{s}': {s}\n", .{key, @errorName(e)}) catch {};
                            return error.InvalidFormat;
                        };
                        // TOOD: evaluate flag action
                    } else {
                        writer.print("error: argument '{s}' not supported.\n", .{key}) catch {};
                        return error.NoSuchArgument;
                    }
                }
            }

            // Phase 3: check all unvisited, handle eventual defaults
            // TODO: Iterate struct fields, comptime!
            // var it = self.argument_list.iterator();
            // while(it.next()) |entry| {
            //     if(self.visited_list.get(entry.key_ptr.*) != null) continue;

            //     // TODO: How can we assign default-values to fields? Shall we rather iterate the struct comptime here, rather than argument_list? Yes!
            //     switch(entry.value_ptr.arg_type) {
            //         .flag => {
            //             // Optional by design, set to false
            //         },
            //         .param => {
            //             // Check for required or default
            //         }
            //     }
            // }

            const info = @typeInfo(result_type);
        
            inline for (info.Struct.fields) |field| {
                switch(@typeInfo(field.type)) {
                    .Union => {
                        @compileError("Subcommands not yet supported");
                    },
                    .Struct => {
                        @compileError("Nonsensical. No logic idea of what structs should represent here.");
                    },
                    else => {
                        // Visited? (e.g. handled)
                        if (self.visited_list.get(field.name) == null) {
                            // Get entry, and evaluate optional/required and eventual default
                            if (self.argument_list.get(field.name)) |arg_entry| {
                                switch(arg_entry.arg_type) {
                                    .flag => {
                                        // Optional by design, set to false
                                        // For some reason we have to check the type here, as seemingly all branches are evaluated during compile-time
                                        if(@TypeOf(@field(result, field.name)) == bool) {
                                            @field(result, field.name) = false;
                                        }
                                    },
                                    .param => {
                                        // Check for required or default
                                        if(arg_entry.default_provider) |default_provider| {
                                            // @field(result, field.name) = default_value; <-- test this approach if we can store the actual type
                                            try default_provider.parse("", result);
                                        } else {
                                            writer.print("error: missing required argument '{s}'\n", .{arg_entry.long}) catch {};
                                            return error.InvalidFormat;
                                        }
                                        // if required: error
                                        // if default: set default
                                    }
                                }
                            } else {
                                // TODO: Can we solve this comptime? Assume we must pass the entire config-struct in one pass though.
                                writer.print("error: Field {s}.{s} is not configured\n", .{@typeName(result_type), field.name}) catch {};
                            }
                        } else {
                        }
                    }
                }
            }
        }

        // TODO: pub fn argument() <- general variant backing both param() and flag()

        // Main function to configure params to check for.
        // TODO: Have parseFunc be optional, and look up based on field-type?
        pub fn param(self: *Self, comptime long: []const u8, comptime parseFunc: anytype, comptime help_text: []const u8, comptime params: struct {
            default: ?coreTypeOf(returnTypeOf(parseFunc)) = null
        }) !void {
            if(!(long[0] == '-' and long[1] == '-')) @compileError("Invalid argument format. It must start with '--'. Found: " ++ long);
            const field = long[2..];
            
            // Assume long starts with --, and derive fieldname from this. TODO: support override via param-struct.
            // Parser.createFieldParser will also verify that field exists in struct

            var parser_func_ptr = try self.allocator.create(Parser.createFieldParser(field, parseFunc));
            parser_func_ptr.* = .{};

            // If default-value provided; Generate a "parser" that always returns the default-value
            var default_func_ptr = blk: {
                if(params.default) |default| {
                    var ptr = try self.allocator.create(Parser.createFieldParser(field, constant(default)));
                    ptr.* = .{};
                    break :blk ptr;
                } else {
                    break :blk null;
                }
            };

            try self.argument_list.put(field, .{
                .arg_type = .param,
                .parser = @ptrCast(*Parser, parser_func_ptr),
                .default_provider = @ptrCast(*Parser, default_func_ptr),
                .long = long,
                .help = help_text,
            });
        }

        pub fn flag(self: *Self, comptime long: []const u8, comptime help_text: []const u8) !void {
            if(!(long[0] == '-' and long[1] == '-')) @compileError("Invalid argument format. It must start with '--'. Found: " ++ long);
            const field = long[2..];

            const field_parser_type = Parser.createFieldParser(field, _true);

            var ptr = try self.allocator.create(field_parser_type);
            ptr.* = .{};

            try self.argument_list.put(field, .{
                .arg_type = .flag,
                .parser = @ptrCast(*Parser, ptr),
                .default_provider = null,
                .long = long,
                .help = help_text,
            });
        }

        pub fn printHelp(self: *Self, writer: anytype) !void {
            if(!self.areAllFieldsConfigured(writer)) return error.IncompleteDefinition;


            if(self.help_head) |text| writer.print("{s}\n", .{text}) catch {};

            // List all arguments
            if(self.argument_list.count() > 0) {
                var it = self.argument_list.iterator();
                writer.print("\nArguments:\n", .{}) catch {};

                while(it.next()) |field| {
                    writer.print("  {s}=<val> {s}\n", .{field.value_ptr.long, field.value_ptr.help}) catch {};
                }

                writer.print("\n", .{}) catch {};
            }

            if(self.help_tail) |text| writer.print("{s}\n", .{text}) catch {};
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
    try parser.conclude(&result, &.{"--a=123", "--b=321"}, std.io.getStdErr().writer());
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
    const MyResult = struct {a: usize};

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
    var parser = Argparse(MyResult).init(std.testing.allocator, .{.help_head="Help-test"});
    defer parser.deinit();

    var output_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer output_buf.deinit();

    var result: MyResult = undefined;
    try testing.expectError(error.GotHelp, parser.conclude(&result, &.{"--help"}, output_buf.writer()));

    try mtest.expectStringContains(output_buf.items, "Help-test");
}

test "argparse shall support value-less bool-backed parameters, i.e. flags. True if set, otherwise false." {
    // Initiate
    const MyResult = struct {myflag: bool};

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
    const MyResult = struct {severity: Severity};

    var parser = Argparse(MyResult).init(std.testing.allocator, .{});
    defer parser.deinit();

    try parser.param("--severity", parseEnum(Severity), "Valid values=" ++ enumValues(Severity), .{});

    var result: MyResult = undefined;
    try parser.conclude(&result, &.{"--severity=WARNING"}, std.io.getStdErr().writer());

    try testing.expect(result.severity == .WARNING);
}

test "argparse shall support optional arguments via default values" {
    const MyResult = struct {a: usize};

    var parser = Argparse(MyResult).init(std.testing.allocator, .{});
    defer parser.deinit();

    try parser.param("--a", parseInt, "Optional argument, default=21", .{.default=21});
    
    var result: MyResult = undefined;
    try parser.conclude(&result, &.{}, std.io.getStdErr().writer());
    try testing.expect(result.a == 21);

    try parser.conclude(&result, &.{"--a=84"}, std.io.getStdErr().writer());
    try testing.expect(result.a == 84);

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