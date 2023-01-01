const std = @import("std");
const print = std.debug.print;

pub fn bench(comptime func: anytype, params: struct {
    warmup_iterations: usize = 0, num_iterations: usize = 10
}) !void {
    const NS_PR_MS = 1000_000;

    print("Starting benchmark\n", .{});
    print("  warmup: {}\n", .{params.warmup_iterations});
    print("  iterations: {}\n", .{params.num_iterations});
    const func_return_type = @typeInfo(@typeInfo(@TypeOf(func)).Fn.return_type.?);


    // Warmup
    var i:usize = 0;
    while(i < params.warmup_iterations): (i += 1) {
        if(func_return_type == .ErrorUnion) {
            try func();
        } else {
            func();
        }
    }

    // Stats variables
    var total_time_ns: u64 = 0;
    var max_time_ns: u64 = 0;
    var min_time_ns: u64 = std.math.maxInt(u64);

    // Bench-time!
    i = 0;
    var timer = try std.time.Timer.start();
    while(i < params.num_iterations): (i += 1) {
        if(func_return_type == .ErrorUnion) {
            try func();
        } else {
            func();
        }

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

    print("Finished benchmark\n", .{});
}