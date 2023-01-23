// STATUS: Work in progress, not functioning
const std = @import("std");
const testing = std.testing;
const print = std.debug.print;

const Severity = enum { all, critical };
const Subcommand = enum { init, update };

const string = []const u8;

// TODO: How can I store the different type-parsers? By the -im approach with comptime handled functions this didn't require any storage. But for this approach this must be solved.
//       Can we create an indexable register/lookup? Or pass in generator-functions with a known interface that returns the proper parsers?
const Entry = struct {
    result_type: type,
    parser: ?fn(string)ParseError!@This().result_type,
    long: ?[]const u8,
    short: ?[]const u8,
    help: []const u8,
};

test "Entry" {
    var entry = Entry{
        .result_type = string,
        .parser = parseString,
        .long = "--key",
        .short = "-k",
        .help = "..."
    };

    try testing.expectEqualStrings("value", try entry.parser("value"));
}

test "parser list" {
    
}

pub fn Argparse(comptime result_type: type, comptime title: []const u8, comptime config: struct { default_required: bool = true, subcommand_enum: ?type = null }) type {
    _ = title;

    return struct {
        alloc: std.mem.Allocator,

        const Self = @This();

        pub fn init(alloc: std.mem.Allocator) Self {
            return Self{ .alloc = alloc };
        }

        // If set: field for flag is considered 'true', otherwise 'false'
        // flags are optional by design
        pub fn flag(self: *Self, comptime long: string, comptime short: ?string, comptime help: string) void {
            _ = self;
            _ = long;
            _ = short;
            _ = help;
        }

        // Parameters differs from flags in that they have values which can be of arbitrary types and needs to be parsed accordingly.
        // Params can be optional: default value can either be null or a predefined value of target data type
        pub fn param(self: *Self, comptime parser: anytype, long: string, short: ?string, help: string,
            param_config: struct {
                required: bool = config.default_required,
                default: ?coreTypeOf(returnTypeOf(parser)) = null
            }
        ) void {
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

            return Self{
                .alloc = self.alloc,
            };
        }

        pub fn printHelp(self: *Self) void {
            _ = self;
        }

        pub fn conclude(self: *Self, args: []const string) error{ missing_arguments, got_help }!result_type {
            _ = self;
            _ = args;

            var result: result_type = undefined;
            // Parse all registered params into result_type{}
            // Is it possible to guarantee a well-defined target struct based on this? Or do we need to make all non-default argments nullable?
            // TODO: Can we comptime create a routine that iterates over all struct-fields, and attempts setting them based on parse-results?
            //       Will at least need to store all flag/param-entries comptime

            // Use "long"-variant (required then) to map fields
            //            optionally; provide a separate "field"-argument, but rather not
            // Step 1: verify that all fields are configured

            // Stop 2: parse args and
            // result.verbose = false;

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
            return result;
        }

        pub fn deinit(self: *Self) void {
            // cleanup
            _ = self;
        }
    };
}

test "argparse shall parse flag and set corresponding field to true if found, otherwise false" {
    const Type = struct { myflag: bool };
    var parser = Argparse(Type, "app", .{}).init(testing.allocator);
    parser.flag("--myflag", "-m", "...");
    var result1 = try parser.conclude(&.{"--myflag"});
    var result2 = try parser.conclude(&.{"--f"});
    var result3 = try parser.conclude(&.{});

    try testing.expect(result1.myflag);
    try testing.expect(result2.myflag);
    try testing.expect(!result3.myflag);
}



fn maybeOptional(comptime is_optional: bool, comptime return_type: type) type {
    if (is_optional) {
        return ?return_type;
    } else {
        return return_type;
    }
}

fn returnTypeOf(comptime func: anytype) type {
    const typeInfo = @typeInfo(@TypeOf(func));
    if (typeInfo != .Fn) @compileError("Argument must be a function");
    return typeInfo.Fn.return_type.?;
}

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

const Result = struct {
    verbose: bool,
    logsev: Severity,

    // "Automagic" name?
    subcommand: union(Subcommand) { init: struct {
        force: bool,
        file: []const u8,
    }, update: struct { force: bool } },
};

const ParseError = error{
    NotFound,
    InvalidFormat,
};

fn enumParser(comptime enum_type: type) fn ([]const u8) ParseError!enum_type {
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
    var argparse = Argparse(Result, "MyApp v1.0.0", .{ .default_required = false, .subcommand_enum = Subcommand })
        .init(testing.allocator);
    defer argparse.deinit();

    // Global flags
    argparse.flag("--verbose", "-v", "Set verbose");
    argparse.param(enumParser(Severity), "--logsev", null, "help me", .{ .default = .all });

    // Subcommand: init
    var sc_init = argparse.subcommand("init", "Initialize a new something");
    sc_init.flag("--force", "-f", "Never stop initing");
    sc_init.param(parseString, "--file", null, "Input-file", .{ .required = true });

    // Subcommand: update
    var sc_update = argparse.subcommand("update", "Update something");
    sc_update.flag("--force", "-f", "Never stop updating");

    // Upon errors; print errors + help, then abort
    var result: Result = try argparse.conclude(&.{ "init", "--file=some.txt" });
    _ = result;
}

test "typeplay" {
    if (true) return error.SkipZigTest;

    const MyType = struct { a: usize };

    var a = MyType{ .a = 0 };

    var b: MyType = blk: {
        var result = .{
            // .a = try parseInt("0"),
        };
        @field(result, "a") = 0;
        break :blk result;
    };

    try testing.expectEqual(a.a, b.a);
}


test "field match" {
    const Data = struct { fieldA: u8, fieldB: u8 };

    var list = std.StringHashMap(u8).init(std.testing.allocator);
    defer list.deinit();

    try list.put("fieldA", 'A');
    try list.put("fieldB", 'B');

    var result: Data = undefined;

    // Find if all the fields in the struct also exists in the list and set values
    const info = @typeInfo(Data);
    inline for (info.Struct.fields) |field| {
        // print("{s}\n", .{field.name});
        if (list.get(field.name)) |value| {
            // print("got field\n", .{});
            @field(result, field.name) = value;
        } else {
            // print("no such field\n", .{});
        }
    }

    try testing.expectEqual(@as(u8, 'A'), result.fieldA);
    try testing.expectEqual(@as(u8, 'B'), result.fieldB);
}

// Simply check if all fields are defined in lookup_list, including for all permutations of unions
// TBD: Shall it also evaluate that there are no _other_ definitions in lookup_list that does not exist?
fn evaluate(comptime result_type: type, lookup_list: *const std.StringHashMap(u8), comptime prefix: []const u8) bool {
    var result = true;
    const info = @typeInfo(result_type);

    inline for (info.Struct.fields) |field| {
        switch(@typeInfo(field.type)) {
            .Union => |value|{
                inline for(value.fields) |union_field| {
                    if(!evaluate(union_field.type, lookup_list, prefix ++ field.name ++ "." ++ union_field.name ++ ".")) {
                        result = false;
                    }
                }
            },
            else => {
                if (lookup_list.get(prefix ++ field.name) == null){
                    print("no such field: {s}\n", .{prefix ++ field.name});
                    result = false;
                }
            }
        }
    }


    return result;
}

test "evaluate" {
    const DataSubtype = enum {A,B};
    const Data = struct {
        fieldA: u8,
        fieldB: u8,
        sub: union(DataSubtype) {
            A: struct {
                aField: u8,
            },
            B: struct {
                bField: u8
            }
        }
    };
    
    var list = std.StringHashMap(u8).init(std.testing.allocator);
    defer list.deinit();

    try list.put("fieldA", 'A');
    try list.put("fieldB", 'B');
    try list.put("sub.A.aField", 'a');
    try testing.expect(evaluate(Data, &list, "") == false);
    try list.put("sub.B.bField", 'b');
    try testing.expect(evaluate(Data, &list, ""));
}

fn parse(comptime result_type: type, lookup_list: *const std.StringHashMap(u8), comptime prefix: []const u8) !result_type {
    // Iterate over args-list
    // if start with -: check for flag
    //  if followed by -: check for long flag
    //  if followed by alphanum: check for short flag
    //    for params: support both "--key=value" and "--key value"
    // if shart with alphanum: check for subcommand
    //   if subcommand: evaluate all following arguments as part of subcommand, not global. Recurse?
    // TBD: Support positional arguments? 

    

    const info = @typeInfo(result_type);
    var result: result_type = undefined;

    // 1) Ensure all fields are defined
    // 2) Lookup field values and set them - later replace this step with argparse-logic
    // 3) If encounter union: recurse, add to prefix (incl ".")
    inline for (info.Struct.fields) |field| {
        switch(@typeInfo(field.type)) {
            .Union => |value|{
                // @field(result, field.name) = parse(field.type)
                // TODO:
                // 1: We need to evaluate that all fields are defined in list
                // 2: We only want to set the one version that shall be active
                inline for(value.fields) |union_field| {
                    print(" -> unionfield {s}\n", .{union_field.name});
                    print( " -> {any}\n", .{union_field});
                }
            },
            else => {
                if (lookup_list.get(prefix ++ field.name)) |value| {
                    print("got field\n", .{});
                    @field(result, field.name) = value;
                } else {
                    // print("no such field\n", .{});
                }
            }
        }
    }

    return result;
}

test "field defined advanced" {
    const DataSubtype = enum {
            A,B
        };
    const Data = struct {
        fieldA: u8,
        fieldB: u8,
        sub: union(DataSubtype) {
            A: struct {
                aField: u8,
            },
            B: struct {
                bField: u8
            }
        }
    };

    var list = std.StringHashMap(u8).init(std.testing.allocator);
    defer list.deinit();

    try list.put("fieldA", 'A');
    try list.put("fieldB", 'B');
    try list.put("sub.A.aField", 'a');
    try list.put("sub.B.bField", 'b');

    var result: Data = undefined;

    // TODO: Wrap as function that returns a struct with fields evaluated (and eventually set), and upon encounters of unions; recurse
    // Find if all the fields in the struct also exists in the list and set values
    const info = @typeInfo(Data);
    inline for (info.Struct.fields) |field| {
        print("type: {any} - value: {any}\n", .{field.type, field.name});
        switch(@typeInfo(field.type)) {
            .Union => |value|{
                // Step 1: for each subcommand variant; ensure there are configured up handlers
                // Step 2: Verify that we are able to set the appropriate enum tag type

                // print("{any}\n", .{value.fields});
                inline for(value.fields) |union_field| {
                    print(" -> unionfield {s}\n", .{union_field.name});
                    print( " -> {any}\n", .{union_field});
                }

                // Fuck yeah!
                var un = @unionInit(field.type, "A", undefined);
                // @field(@field(un,"A"), "aField") = 'a';
                @field(@field(un,"A"), "aField") = list.get(field.name ++ "." ++ "A" ++ "." ++ "aField").?;
                @field(result, field.name) = un;
                // @field(result, field.name)
                // @field(result, field.name) = @unionInit(field.type, "A", .{.aField='a'});
            },
            //     print("{any}\n", .{value});
            //     // print(" - {any}\n", .{@typeInfo(field.type)});
            //     // inline for(field.type) |union_type| {
            //     //     print(" - {any}\n", .{union_type});
            //     // }
            //     // print("union: {any}\n", .{unionType});
            //     // inline for(unionType) |union_variant| {
            //     //     print("variant: {any}\n", .{union_variant});
            //     // }
            //     // print("{any} {any}\n", .{field, @typeInfo(field.type)});
            //     // TODO: Can I iterate over all variants of the tagged union?
            // },
            else => {
                print("{any}\n", .{field});

                if (list.get(field.name)) |value| {
                    print("got field\n", .{});
                    @field(result, field.name) = value;
                } else {
                    // print("no such field\n", .{});
                }
            }
        }

        
    }
    // _ = result;

    try testing.expectEqual(@as(u8, 'A'), result.fieldA);
    try testing.expectEqual(@as(u8, 'B'), result.fieldB);
    try testing.expectEqual(@as(u8, 'a'), result.sub.A.aField);

    var result2 = try parse(Data, &list, "");
    try testing.expectEqual(@as(u8, 'A'), result2.fieldA);
    try testing.expectEqual(@as(u8, 'B'), result2.fieldB);
}
