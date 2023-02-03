const std = @import("std");
const testing = std.testing;
const print = std.debug.print;

const ParseError = error{
    NotFound,
    InvalidFormat,
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
                    @compileError("Incompatible types: " ++ @typeName(structField.type) ++ " vs " ++ coreTypeOfFunc);
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


const Result = struct { a: usize, b: []const u8 };

pub inline fn parseInt(val: []const u8) ParseError!usize {
    return std.fmt.parseInt(usize, val, 10) catch {
        return ParseError.InvalidFormat;
    };
}

pub inline fn parseString(val: []const u8) ParseError![]const u8 {
    return val;
}

test "2dyn" {
    var allocator = std.testing.allocator;

    const Parser = ParserForResultType(Result);

    var intparser = Parser.createFieldParser("a", parseInt){};
    var stringparser = Parser.createFieldParser("b", parseString){};

    
    var list = std.ArrayList(*Parser).init(allocator);
    defer list.deinit();

    try list.append(@ptrCast(*Parser, &intparser));
    try list.append(@ptrCast(*Parser, &stringparser));


    var result: Result = undefined;
    for (list.items) |entry| {
        try entry.parse("321", &result);
    }

    try testing.expect(result.a == 321);
    try testing.expectEqualStrings("321", result.b);

    // Can I store them in a map, dynamically look up and utilize to populate a struct?
}

fn ArgparseEntry(comptime result_type: type) type {
    return struct {
        parser: *ParserForResultType(result_type),
    };
}

fn  Argparse(comptime result_type: type) type {
    return struct {
        const Self = @This();
        const Parser = ParserForResultType(result_type);

        argument_list: std.StringHashMap(ArgparseEntry(result_type)),

        allocator: std.mem.Allocator,

        fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .argument_list = std.StringHashMap(ArgparseEntry(result_type)).init(allocator)
            };
        }

        fn deinit(self: *Self) void {
            var it = self.argument_list.valueIterator();
            while(it.next()) |field| {
                self.allocator.destroy(field.parser);
            }

            self.argument_list.deinit();
        }
        
        fn areAllFieldsConfigured(self: *Self) bool {
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
                            print("error: Field {s}.{s} is not configured\n", .{@typeName(result_type), field.name});
                            result = false;
                        }
                    }
                }
            }
        
            return result;
        }

        fn conclude(self: *Self, result: *result_type, args: []const []const u8) bool {
            // Phase 1: Evaluate that all fields are configured
            if(!self.areAllFieldsConfigured()) return false;

            // Phase 2: Attempt parse to result
            for(args) |arg| {
                if(arg.len < 3) {
                    print("error: invalid argument format. Too short.\n", .{});
                    return false;
                }
                if(!std.mem.startsWith(u8, arg, "--")) {
                    print("error: invalid argument format. Should start with --.\n", .{});
                    return false;
                }

                // Check if flag or argument (has = or not)
                if(std.mem.indexOf(u8, arg, "=")) |eql_idx| {
                    var key = arg[2..eql_idx];
                    var val = arg[eql_idx+1..];

                    if(self.argument_list.get(key)) |field_def| {
                        field_def.parser.parse(val, result) catch |e| {
                            print("error: got error parsing value: {s}\n", .{@errorName(e)});
                        };
                    } else {
                        print("error: field not supported.\n", .{});
                    }
                } else {
                    // TODO: handle seems-to-be-flag
                }
            }

            return true;
        }

        fn argument(self: *Self, comptime long: []const u8, comptime parseFunc: anytype) !void {
            if(!(long[0] == '-' and long[1] == '-')) @compileError("Invalid argument format. It must start with '--'. Found: " ++ long);
            const field = long[2..];
            
            // Assume long starts with --, and derive fieldname from this. TODO: support override via param-struct.
            // This will also verify that field exists in struct
            const field_parser_type = Parser.createFieldParser(field, parseFunc);
            
            var ptr = try self.allocator.create(field_parser_type);
            ptr.* = .{};

            try self.argument_list.put(field, .{
                .parser = @ptrCast(*Parser, ptr)
            });
        }
    };
}

test "exploration" {
    var parser = Argparse(Result).init(std.testing.allocator);
    defer parser.deinit();

    try parser.argument("--a", parseInt);
    try parser.argument("--b", parseString);

    var result: Result = undefined;
    try testing.expect(parser.conclude(&result, &.{"--a=123", "--b=321"}));
    try testing.expect(result.a == 123);
    try testing.expectEqualStrings("321", result.b);
}

// Plan:
// Incorporate this into argparse, which will handle allocations, and final evaluations
// ... including verifications that all fields are configured at time of .conclude()