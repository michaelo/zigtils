const std = @import("std");
const argparse = @import("../dyntest.zig");

const MyArgs = struct {
    output: []const u8,
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

    try parser.param("--output", argparse.lengthedString(3,1024), "Specify file to write results to");

    // Get command-line argaments list
    // TODO: support using process.argsWithAllocator directly?
    var cli_args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, cli_args);

    // Allocate and parse. If .conclude() succeeds, the args should 
    var args: MyArgs = undefined;
    parser.conclude(&args, cli_args[1..], std.io.getStdErr().writer()) catch {
        std.process.exit(1);
    };

    std.debug.print("We're good to go!\n", .{});
}
