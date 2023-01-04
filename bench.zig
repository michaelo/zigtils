const std = @import("std");
const print = std.debug.print;

// Simple benchmarking of function - including any arguments. Writes to stderr.
pub fn bench(comptime func: anytype, comptime func_args: anytype, params: struct {
    warmup_iterations: usize = 0, num_iterations: usize = 10
}) !void {
    const NS_PR_MS = 1000_000;

    print("Starting benchmark\n", .{});
    print("  warmup: {}\n", .{params.warmup_iterations});
    print("  iterations: {}\n", .{params.num_iterations});
    const func_typeinfo = @typeInfo(@TypeOf(func));
    if(func_typeinfo != .Fn) @compileError("argument 'func' must be a function. Got '" ++ @tagName(func_typeinfo) ++ "'");
    const func_return_type = func_typeinfo.Fn.return_type.?;

    var result: func_return_type = undefined;

    // Warmup
    var i:usize = 0;

    while(i < params.warmup_iterations): (i += 1) {
        result = @call(.auto, func, func_args);
    }

    // Stats variables
    var total_time_ns: u64 = 0;
    var max_time_ns: u64 = 0;
    var min_time_ns: u64 = std.math.maxInt(u64);

    // Bench-time!
    i = 0;
    var timer = try std.time.Timer.start();
    while(i < params.num_iterations): (i += 1) {
        result = @call(.auto, func, func_args);

        const delta_ns = timer.lap();
        if (delta_ns > max_time_ns) max_time_ns = delta_ns;
        if (delta_ns < min_time_ns) min_time_ns = delta_ns;
        total_time_ns += delta_ns;
    }

    // Present results
    print("RESULTS:\n  min: {d:.3}ms, max: {d:.3}ms, avg: {d:.3}ms ({d} iterations, total: {d:.3}ms ({d:.3}ns))\n", .{
        @intToFloat(f64, min_time_ns) / NS_PR_MS, // min
        @intToFloat(f64, max_time_ns) / NS_PR_MS, // max
        (@intToFloat(f64, total_time_ns) / @intToFloat(f64, params.num_iterations)) / NS_PR_MS, // avg
        params.num_iterations, // iterations
        @intToFloat(f64, total_time_ns) / NS_PR_MS, // total ms
        total_time_ns}); // total ns

    // Print the output of the benched function - if any
    const maybe_result_format: ?[]const u8 = switch(@TypeOf(result)) {
        void => null,
        []const u8 => "{s}",
        else => "{any}"
    };

    if(maybe_result_format) |format| {
        print("  function output: " ++ format ++ "\n", .{result});
    }

    print("Finished benchmark\n", .{});
}

test "bench" {
    const Func = struct {
        fn func(intval: usize) void {
            print("DEBUG: intval: {d}\n", .{intval});
        }

        fn add(a: usize, b: usize) usize {
            return a+b;
        }

        fn hello() []const u8 {
            return "world";
        }

        fn maybe_error() !usize {
            return error.Woops;
        }
    };

    try bench(Func.func, .{21}, .{});
    try bench(Func.add, .{21, 84}, .{});
    try bench(Func.hello, .{}, .{});
    try bench(Func.maybe_error, .{}, .{});
    // try bench(123, .{}, .{}); // Won't compile as the first argument isn't a function
}