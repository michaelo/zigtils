// Collection of test-helpers
const std = @import("std");
const print = std.debug.print;

pub fn expectStringContains(actual: []const u8, expected_contains: []const u8) !void {
    if (std.mem.indexOf(u8, actual, expected_contains) != null)
        return;

    print("\n======= expected to contain: =========\n", .{});
    print("{s}\n", .{expected_contains});
    print("\n======== actual contents: ============\n", .{});
    print("{s}\n", .{actual});
    print("\n======================================\n", .{});

    return error.TestExpectedContains;
}
