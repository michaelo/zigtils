const std = @import("std");
const argparse = @import("../dyntest.zig");

const MyArgs = struct {

};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var alloc = arena.allocator();

    var parser = argparse.Argparse(MyArgs).init(alloc, .{
        .help_head = "My application v1.0",
        .help_tail = "(c) Michael Odden"
    });
    defer parser.deinit();

    // TODO: support using process.argsWithAllocator directly?
    var cli_args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, cli_args);

    var args: MyArgs = undefined;
    parser.conclude(&args, cli_args[1..]) catch {
        // try parser.help(std.io.getStdErr().writer());
        std.process.exit(1);
    };

    std.debug.print("We're good to go!\n", .{});
}