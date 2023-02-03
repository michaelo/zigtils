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
                    @compileError("no such field: " ++ field);
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

fn  Argparse(comptime result_type: type) type {

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,

        fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator
            };
        }

        fn deinit(self: *Self) void {
            _ = self;
        }

        fn conclude(_: *Self, result: *result_type, args: []const []const u8) bool {
            _ = result;
            _ = args;

            return true;
        }

        fn argument(_: *Self, comptime long: []const u8, comptime parser: anytype) void {
            if(!(long[0] == '-' and long[1] == '-')) @compileError("Invalid flag format. It must start with '--'. Found: " ++ long);
            _ = parser;
            // Verify that field exists in struct
            // Assume long starts with --, and derive fieldname from this. TODO: support override via param-struct.
            const field = long[2..];
            _  = field;

        }
    };
}

test "exploration" {
    var parser = Argparse(Result).init(std.testing.allocator);
    defer parser.deinit();

    parser.argument("--a", parseInt);

    var result: Result = undefined;
    try testing.expect(parser.conclude(&result, &.{"--a=1"}));
    try testing.expect(result.a == 1);
}

// Plan:
// Incorporate this into argparse, which will handle allocations, and final evaluations
// ... including verifications that all fields are configured at time of .conclude()