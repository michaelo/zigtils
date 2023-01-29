const std = @import("std");
const testing = std.testing;
const print = std.debug.print;

// pub const IntParser = struct {
//     usingnamespace Parser.Methods(IntParser);
//     __v: *const Parser.VTable = &vtable,

//     const vtable = Parser.VTable { .parse = parseImpl };

//     fn parseImpl(itself: *const Parser) void {
//         const self = @ptrCast(*const IntParser, itself);
//         print("intparse!\n", .{});
//         _ = self;
//     }
// };

pub const Parser = struct {
    __v: *const VTable,
    pub usingnamespace Methods(Parser);

    pub fn Methods(comptime T: type) type {
        return extern struct {
            pub inline fn parse(self: *const T) void {
                self.__v.parse();
            }
        };
    }

    pub const VTable = extern struct {
        parse: *const fn() void,
    };
};


pub fn createParserType(comptime funcImpl: fn () void) type {
    return struct {
        usingnamespace Parser.Methods(@This());
        __v: *const Parser.VTable = &vtable,

        const vtable = Parser.VTable { .parse = funcImpl };
    };
}

fn intParseImpl() void {
    print("intparse!\n", .{});
}

fn stringParseImpl() void {
    print("stringparse!\n", .{});
}

test "2dyn" {
    var allocator = std.testing.allocator;
    var intparser = createParserType(intParseImpl){};
    var stringparser = createParserType(stringParseImpl){};
    // var intparser = try allocator.create(createParserType(intParseImpl));
    // defer allocator.destroy(intparser);
    // intparser.* = .{};

    
    var list = std.ArrayList(*Parser).init(allocator);
    defer list.deinit();

    try list.append(@ptrCast(*Parser, &intparser));
    try list.append(@ptrCast(*Parser, &stringparser));

    for (list.items) |entry| {
        entry.parse();
    }

    // Can I store them in a map, dynamically look up and utilize to populate a struct?
}