const std = @import("std");
const string = []const u8;
const Builder = std.build.Builder;

const playdate_target = std.zig.CrossTarget{
    .cpu_arch = .thumb,
    .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m7 },
    .cpu_features_add = std.Target.arm.featureSet(&.{.v7em}),
    .os_tag = .freestanding,
    .abi = .eabihf,
};
const game_name = "playdate-next";
const arm_toolchain_version = "11.3.1";

pub fn build(b: *Builder) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const mode = b.standardReleaseOptions();

    const sdk_path = try std.process.getEnvVarOwned(allocator, "PLAYDATE_SDK_PATH");
    const c_sdk_path = try std.fs.path.join(allocator, &[_]string{ sdk_path, "C_API" });
    const arm_toolchain_path = try std.process.getEnvVarOwned(allocator, "ARM_TOOLKIT_PATH");
    const libc_txt_path = "playdate-libc.txt";

    //Create the device exe
    const device_lib = createDeviceLib(game_name, "src/main.zig", b, c_sdk_path, arm_toolchain_path, libc_txt_path);
    device_lib.setBuildMode(mode);
    device_lib.install();

    const game_elf = createElf(b, device_lib, c_sdk_path, arm_toolchain_path, libc_txt_path);
    game_elf.setBuildMode(mode);
    game_elf.install();

    //Create simulator DLL
    const simulator = createSimLib("src/main.zig", b, c_sdk_path);
    simulator.setBuildMode(mode);
    simulator.install();

    // //Create empty bin folder needed to run pdc
    // const empty_bin_step = b.step("sim-bin", "Create bin file for simulator");
    // empty_bin_step.makeFn = createEmptyBin;
    // b.getInstallStep().dependOn(empty_bin_step);

    //objcopy elf to bin
    const elf_to_bin_step = b.addSystemCommand(&.{ "objcopy", "-O", "binary", "zig-out/bin/pdex.elf", "zig-out/lib/pdex.bin" });
    b.getInstallStep().dependOn(&elf_to_bin_step.step);

    //Copy assets ready for pdc
    const copy_assets_step = b.step("assets", "Copy the assets into the build folder to be pdc'd");
    copy_assets_step.makeFn = copyAssets;
    b.getInstallStep().dependOn(copy_assets_step);

    //pdc step to create pdx package
    const pdc_step = b.addSystemCommand(&.{ "pdc", "-k", "zig-out/lib", b.fmt("zig-out/{s}.pdx", .{game_name}) });
    pdc_step.step.dependOn(copy_assets_step);
    b.getInstallStep().dependOn(&pdc_step.step);

    //run on simulator
    const sim_path = try std.fs.path.join(allocator, &[_]string{ sdk_path, "bin/PlaydateSimulator.exe" });
    const run_sim_cmd = b.addSystemCommand(&.{ sim_path, "zig-out/" ++ game_name ++ ".pdx" });
    run_sim_cmd.step.dependOn(b.getInstallStep());
    const run_sim_step = b.step("run-sim", "Run the game on simulator");
    run_sim_step.dependOn(&run_sim_cmd.step);

    //Tests
    const maths_test_step = b.addTest("src/maths.zig");
    const graph_coords_test_step = b.addTest("src/graphics_coords.zig");
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&maths_test_step.step);
    test_step.dependOn(&graph_coords_test_step.step);
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

fn createSimLib(root_src: ?string, b: *Builder, playdate_csdk_path: string) *std.build.LibExeObjStep {
    const lib = b.addSharedLibrary("pdex", root_src, .unversioned);
    lib.addIncludePath(playdate_csdk_path);
    lib.defineCMacro("TARGET_SIMULATOR", null);
    lib.defineCMacro("TARGET_EXTENSION", null);
    lib.defineCMacro("_WINDLL", null);
    lib.linkLibC();
    return lib;
}

fn createDeviceLib(name: string, root_src: ?string, b: *Builder, playdate_csdk_path: string, arm_toolchain_path: string, libc_txt_path: string) *std.build.LibExeObjStep {
    const lib = b.addSharedLibrary(name, root_src, .unversioned);
    lib.setOutputDir("zig-out/lib");
    lib.defineCMacro("TARGET_SIMULATOR", null);
    lib.defineCMacro("TARGET_EXTENSION", null);
    setupStep(b, lib, playdate_csdk_path, arm_toolchain_path, libc_txt_path);
    return lib;
}

fn createElf(b: *Builder, lib: *std.build.LibExeObjStep, playdate_csdk_path: string, arm_toolchain_path: string, libc_txt_path: string) *std.build.LibExeObjStep {
    const game_elf = b.addExecutable("pdex.elf", null);
    game_elf.addObjectFile(b.pathJoin(&.{ lib.output_dir.?, b.fmt("lib{s}.so.o", .{lib.name}) }));
    game_elf.step.dependOn(&lib.step);
    const c_args = [_]string{ "-DTARGET_PLAYDATE=1", "-DTARGET_EXTENSION=1" };
    game_elf.want_lto = false; // otherwise release build does not work
    game_elf.addCSourceFile(b.pathJoin(&.{ playdate_csdk_path, "/buildsupport/setup.c" }), &c_args);
    setupStep(b, game_elf, playdate_csdk_path, arm_toolchain_path, libc_txt_path);

    return game_elf;
}

fn setupStep(b: *Builder, step: *std.build.LibExeObjStep, playdate_csdk_path: string, arm_toolchain_path: string, libc_txt_path: string) void {
    step.setLinkerScriptPath(.{ .path = b.pathJoin(&.{ playdate_csdk_path, "/buildsupport/link_map.ld" }) });
    step.addIncludePath(b.pathJoin(&.{ arm_toolchain_path, "/arm-none-eabi/include" }));
    step.addLibraryPath(b.pathJoin(&.{ arm_toolchain_path, "/lib/gcc/arm-none-eabi/", arm_toolchain_version, "/thumb/v7e-m+fp/hard/" }));
    step.addLibraryPath(b.pathJoin(&.{ arm_toolchain_path, "/arm-none-eabi/lib/thumb/v7e-m+fp/hard/" }));

    step.addIncludePath(playdate_csdk_path);
    step.setLibCFile(std.build.FileSource{ .path = libc_txt_path });

    step.setTarget(playdate_target);

    if (b.is_release) {
        step.omit_frame_pointer = true;
    }
    step.strip = true;
    step.link_function_sections = true;
    step.link_z_notext = true; // needed for @cos func
    step.stack_size = 61800;
}
