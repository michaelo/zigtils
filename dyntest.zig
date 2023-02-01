const std = @import("std");
const testing = std.testing;
const print = std.debug.print;

pub fn ParserForResultType(comptime ResultT: type) type {
    return struct {
        const Self = @This();
        __v: *const VTable,
        pub usingnamespace Methods(Self);

        pub fn Methods(comptime T: type) type {
            return extern struct {
                pub inline fn parse(self: *const T, raw: []const u8, result: *ResultT) void {
                    self.__v.parse(@ptrCast(*const ParserForResultType(ResultT), self), raw, result);
                }
                // pub inline fn fieldName(self: *const T) comptime []const u8 {

                // }
            };
        }

        pub const VTable = extern struct {
            parse: *const fn(self: *const ParserForResultType(ResultT), []const u8, *ResultT) void,
        };

        pub fn createParserType(comptime dataType: type, comptime field: []const u8, comptime funcImpl: fn ([]const u8) dataType) type {
            return struct {
                usingnamespace Self.Methods(@This());
                __v: *const Self.VTable = &vtable,

                const vtable = Self.VTable {
                    .parse = actualParse,
                };

                // Make this the .parse of .VTable
                pub fn actualParse(iself: *const ParserForResultType(ResultT), raw: []const u8, result: *ResultT) void {
                    _ = @ptrCast(*const @This(), iself);
                    @field(result, field) = funcImpl(raw);
                }
            };
        }
    };
}


const Result = struct { a: usize, b: []const u8 };

fn intParseImpl(raw: []const u8) usize {
    _ = raw;
    // _ = result;
    print("intparse!\n", .{});
    return 321;
}

fn stringParseImpl(raw: []const u8) []const u8 {
    _ = raw;
    print("stringparse!\n", .{});
    return "321";
}

test "2dyn" {
    var allocator = std.testing.allocator;

    const Parser = ParserForResultType(Result);

    var intparser = Parser.createParserType(usize, "a", intParseImpl){};
    var stringparser = Parser.createParserType([]const u8, "b", stringParseImpl){};

    
    var list = std.ArrayList(*Parser).init(allocator);
    defer list.deinit();

    try list.append(@ptrCast(*Parser, &intparser));
    try list.append(@ptrCast(*Parser, &stringparser));


    var result: Result = undefined;
    for (list.items) |entry| {
        entry.parse("321", &result);
    }

    try testing.expect(result.a == 321);
    try testing.expectEqualStrings("321", result.b);

    // Can I store them in a map, dynamically look up and utilize to populate a struct?
}

// Plan:
// If all good: Implement error-handling