const std = @import("std");
const string = []const u8;
const Builder = std.build.Builder;

pub fn build(b: *Builder) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    const sdk_path = try std.process.getEnvVarOwned(allocator, "PLAYDATE_SDK_PATH");
    const c_sdk_path = try std.fs.path.join(allocator, &[_]string{
        sdk_path,
        "C_API",
    });

    const output_path = try std.fs.path.join(b.allocator, &.{ b.install_path, "Source" });

    const simulator = b.addSharedLibrary("pdex", "src/main.zig", .unversioned);
    simulator.setOutputDir(output_path);
    simulator.addIncludeDir(c_sdk_path);
    simulator.defineCMacro("TARGET_SIMULATOR", null);
    simulator.defineCMacro("TARGET_EXTENSION", null);
    simulator.defineCMacro("_WINDLL", null);
    simulator.linkLibC();
    simulator.setBuildMode(mode);
    simulator.setTarget(target);
    b.default_step.dependOn(&simulator.step);
    simulator.install();
}
