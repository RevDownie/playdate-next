const std = @import("std");

const game_name = "until-none";
const arm_toolchain_version = "11.3.1";

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const is_release = optimize != .debug;

    const environ = b.graph.environ_map;
    const sdk_path = environ.get("PLAYDATE_SDK_PATH") orelse @panic("PLAYDATE_SDK_PATH is not set");
    const arm_toolchain_path = environ.get("ARM_TOOLKIT_PATH") orelse @panic("ARM_TOOLKIT_PATH is not set");
    const c_sdk_path = b.pathJoin(&.{ sdk_path, "C_API" });

    const device_target = b.resolveTargetQuery(.{
        .cpu_arch = .thumb,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m7 },
        .cpu_features_add = std.Target.arm.featureSet(&.{ .v7em, .fp_armv8d16sp }),
        .os_tag = .freestanding,
        .abi = .eabihf,
    });
    const sim_target = b.standardTargetOptions(.{});

    //Device: the game compiled to an object that is linked with the SDK's setup.c into an elf
    const device_game = b.addObject(.{
        .name = game_name,
        .root_module = createGameModule(b, device_target, optimize, c_sdk_path, arm_toolchain_path, .device, is_release),
    });
    configureDevice(b, device_game.root_module, c_sdk_path, arm_toolchain_path);

    const game_elf = b.addExecutable(.{
        .name = "pdex.elf",
        .root_module = b.createModule(.{
            .target = device_target,
            .optimize = optimize,
            .strip = true,
            .sanitize_c = .off, // no ubsan runtime for freestanding
            .unwind_tables = .none, // would pull in libgcc unwinding, which drags in newlib malloc and clashes with the SDK
            .omit_frame_pointer = if (is_release) true else null,
        }),
    });
    game_elf.root_module.addObject(device_game);
    game_elf.root_module.addCSourceFile(.{
        .file = .{ .cwd_relative = b.pathJoin(&.{ c_sdk_path, "buildsupport", "setup.c" }) },
        .flags = &.{ "-DTARGET_PLAYDATE=1", "-DTARGET_EXTENSION=1" },
    });
    configureDevice(b, game_elf.root_module, c_sdk_path, arm_toolchain_path);
    // The SDK's linker script does GROUP(libgcc.a libc.a libm.a) but the library paths never reach lld
    // for a freestanding target, so wrap it in a script that adds the search dirs itself
    const link_script = b.addWriteFiles().add("link_map.ld", b.fmt(
        \\SEARCH_DIR("{[gcc_lib]s}")
        \\SEARCH_DIR("{[newlib_lib]s}")
        \\INCLUDE "{[sdk_script]s}"
        \\
    , .{
        .gcc_lib = linkerPath(b, &.{ arm_toolchain_path, "lib", "gcc", "arm-none-eabi", arm_toolchain_version, "thumb", "v7e-m+fp", "hard" }),
        .newlib_lib = linkerPath(b, &.{ arm_toolchain_path, "arm-none-eabi", "lib", "thumb", "v7e-m+fp", "hard" }),
        .sdk_script = linkerPath(b, &.{ c_sdk_path, "buildsupport", "link_map.ld" }),
    }));
    game_elf.setLinkerScript(link_script);
    game_elf.link_function_sections = true;
    game_elf.link_z_notext = true; // needed for @cos func
    game_elf.stack_size = 61800;
    game_elf.entry = .{ .symbol_name = "eventHandlerShim" };
    game_elf.lto = .none; // otherwise release build does not work
    b.installArtifact(game_elf);

    //Everything that pdc packages lives in zig-out/lib
    const pdc_inputs = b.step("pdc-inputs", "Everything pdc needs to build the pdx package");

    const game_bin = game_elf.addObjCopy(.{ .format = .binary });
    pdc_inputs.dependOn(&b.addInstallLibFile(game_bin.getOutput(), "pdex.bin").step);

    //Simulator DLL
    const simulator = b.addLibrary(.{
        .name = "pdex",
        .linkage = .dynamic,
        .root_module = createGameModule(b, sim_target, optimize, c_sdk_path, arm_toolchain_path, .simulator, is_release),
    });
    pdc_inputs.dependOn(&b.addInstallArtifact(simulator, .{ .dest_dir = .{ .override = .lib }, .pdb_dir = .disabled, .implib_dir = .disabled }).step);

    //Assets
    pdc_inputs.dependOn(&b.addInstallLibFile(b.path("pdxinfo"), "pdxinfo").step);
    for ([_][]const u8{ "images", "levels" }) |asset_dir| {
        pdc_inputs.dependOn(&b.addInstallDirectory(.{
            .source_dir = b.path(asset_dir),
            .install_dir = .lib,
            .install_subdir = "",
        }).step);
    }

    //pdc step to create pdx package
    const pdx_path = b.graph.path(.install_prefix, game_name ++ ".pdx");
    const pdc = b.addSystemCommand(&.{"pdc"});
    pdc.addDirectoryArg(b.graph.path(.install_lib, ""));
    pdc.addDirectoryArg(pdx_path);
    pdc.step.dependOn(pdc_inputs);
    b.getInstallStep().dependOn(&pdc.step);

    //Run on simulator
    const run_sim = b.addSystemCommand(&.{b.pathJoin(&.{ sdk_path, "bin", "PlaydateSimulator.exe" })});
    run_sim.addDirectoryArg(pdx_path);
    run_sim.step.dependOn(b.getInstallStep());
    b.step("run-sim", "Run the game on simulator").dependOn(&run_sim.step);

    //Tests
    const test_step = b.step("test", "Run tests");
    for ([_][]const u8{ "src/maths.zig", "src/graphics_coords.zig", "src/sparse_array.zig" }) |test_file| {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_file),
                .target = b.graph.host,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }
}

const GameTarget = enum { device, simulator };

/// The game's root module with the Playdate C API (translated from pd_api.h) available as the "playdate_c" import
fn createGameModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    c_sdk_path: []const u8,
    arm_toolchain_path: []const u8,
    game_target: GameTarget,
    is_release: bool,
) *std.Build.Module {
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/playdate_c.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = game_target == .simulator,
    });
    translate_c.addIncludePath(.{ .cwd_relative = c_sdk_path });
    if (game_target == .device) {
        translate_c.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ arm_toolchain_path, "arm-none-eabi", "include" }) });
    }
    translate_c.defineCMacro("TARGET_EXTENSION", null);
    // The device build has always defined TARGET_SIMULATOR for its game code, so keep doing so
    translate_c.defineCMacro("TARGET_SIMULATOR", null);
    if (game_target == .simulator) translate_c.defineCMacro("_WINDLL", null);

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = game_target == .simulator,
        .strip = if (game_target == .device) true else null,
        .unwind_tables = if (game_target == .device) .none else null,
        .omit_frame_pointer = if (game_target == .device and is_release) true else null,
    });
    module.addImport("playdate_c", translate_c.createModule());
    return module;
}

fn configureDevice(b: *std.Build, module: *std.Build.Module, c_sdk_path: []const u8, arm_toolchain_path: []const u8) void {
    module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ arm_toolchain_path, "arm-none-eabi", "include" }) });
    module.addIncludePath(.{ .cwd_relative = c_sdk_path });
    module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ arm_toolchain_path, "lib", "gcc", "arm-none-eabi", arm_toolchain_version, "thumb", "v7e-m+fp", "hard" }) });
    module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ arm_toolchain_path, "arm-none-eabi", "lib", "thumb", "v7e-m+fp", "hard" }) });
    module.addCMacro("TARGET_EXTENSION", "1");
}

/// Linker scripts want forward slashes, even on Windows
fn linkerPath(b: *std.Build, parts: []const []const u8) []const u8 {
    const joined = b.pathJoin(parts);
    std.mem.replaceScalar(u8, joined, '\\', '/');
    return joined;
}
