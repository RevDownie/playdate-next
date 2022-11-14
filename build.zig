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
    const c_sdk_path = try std.fs.path.join(allocator, &[_]string{ sdk_path, "C_API" });

    //Create simulator DLL
    const simulator = b.addSharedLibrary("pdex", "src/main.zig", .unversioned);
    simulator.addIncludePath(c_sdk_path);
    simulator.defineCMacro("TARGET_SIMULATOR", null);
    simulator.defineCMacro("TARGET_EXTENSION", null);
    simulator.defineCMacro("_WINDLL", null);
    simulator.linkLibC();
    simulator.setBuildMode(mode);
    simulator.setTarget(target);
    b.default_step.dependOn(&simulator.step);
    simulator.install();

    //Create empty bin folder needed to run pdc
    const empty_bin_step = b.step("sim-bin", "Create bin file for simulator");
    empty_bin_step.makeFn = createEmptyBin;
    b.getInstallStep().dependOn(empty_bin_step);

    //Copy assets ready for pdc
    const copy_assets_step = b.step("assets", "Copy the assets into the build folder to be pdc'd");
    copy_assets_step.makeFn = copyAssets;
    b.getInstallStep().dependOn(copy_assets_step);

    //pdc step to create pdx package
    const pdc_step = b.addSystemCommand(&.{ "pdc", "-k", "zig-out/lib", "zig-out/playdate_next.pdx" });
    pdc_step.step.dependOn(copy_assets_step);
    b.getInstallStep().dependOn(&pdc_step.step);
}

fn createEmptyBin(_: *std.build.Step) !void {
    std.debug.print("Creating simulator bin file\n", .{});
    if (std.fs.cwd().createFile("zig-out/lib/pdex.bin", .{})) |file| {
        file.close();
    } else |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    }
}

fn copyAssets(_: *std.build.Step) !void {
    std.debug.print("Copying assets...\n", .{});

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var output_dir = try std.fs.cwd().openDir("zig-out/lib", .{});
    defer output_dir.close();

    //pdxinfo
    try std.fs.cwd().copyFile("pdxinfo", output_dir, "pdxinfo", .{});

    //Images
    var image_dir = try std.fs.cwd().openIterableDir("images", .{});
    defer image_dir.close();

    var iter = image_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .File) {
            std.debug.print("Copying image: {s}\n", .{entry.name});
            const path = try std.fs.path.join(allocator, &[_]string{ "images", entry.name });
            try std.fs.cwd().copyFile(path, output_dir, entry.name, .{});
        }
    }
}
