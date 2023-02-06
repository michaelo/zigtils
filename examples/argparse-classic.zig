const std = @import("std");
const argparse = @import("../argparse-classic.zig");

const Loglevel = enum { ALL, NONE };

const MyArgs = struct {
    output: []const u8,
    loglevel: Loglevel,
    force: bool,
};

pub fn main() !void {
    // Get an allocator
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var alloc = arena.allocator();

    // Initiate parser
    var parser = argparse.Argparse(MyArgs).init(alloc, .{
        .help_head = "My application v1.0",
        .help_tail = "(c) Michael Odden"
    });
    defer parser.deinit();

    try parser.param("--output", argparse.lengthedString(3,1024), "Specify file to write results to", .{});
    try parser.param("--loglevel", argparse.parseEnum(Loglevel), "Level of logging: " ++ argparse.enumValues(Loglevel), .{.default=.NONE});
    try parser.flag("--force", "Will never give up!");

    // Get command-line argaments list
    // TODO: support using process.argsWithAllocator directly?
    var cli_args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, cli_args);

    // Allocate and parse. If .conclude() succeeds, the args shall be assumed well defined
    var args: MyArgs = undefined;
    parser.conclude(&args, cli_args[1..], std.io.getStdErr().writer()) catch {
        // If you want to automatically print errors upon invalid input:
        // try parser.printHelp(std.io.getStdErr().writer());
        std.process.exit(1);
    };

    std.debug.print("We're good to go!\n", .{});
    std.debug.print("  params: output={s}, loglevel={s}, force={}\n", .{args.output, @tagName(args.loglevel), args.force});
}
