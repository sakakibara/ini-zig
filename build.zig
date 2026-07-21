const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root = b.path("src/ini.zig");

    const ini_module = b.addModule("ini", .{
        .root_source_file = root,
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = root,
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit, conformance, and bounded fuzz tests");
    test_step.dependOn(&run_tests.step);

    // Conformance suite over the authored fixture corpus. Fixtures are
    // discovered at test time via std.fs; the corpus root is passed as an
    // absolute path baked at build time so the suite works from any cwd.
    const conformance_options = b.addOptions();
    conformance_options.addOption([]const u8, "corpus_path", b.pathFromRoot("tests/corpus"));

    const conformance_module = b.createModule(.{
        .root_source_file = b.path("src/conformance.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ini.zig", .module = ini_module }},
    });
    conformance_module.addOptions("conformance_options", conformance_options);

    const conformance_tests = b.addTest(.{ .root_module = conformance_module });
    const run_conformance = b.addRunArtifact(conformance_tests);
    test_step.dependOn(&run_conformance.step);

    // Buffered==streaming cross-check harness. Walks the same corpus and an
    // adversarial battery, asserting EventReader/materialize match parser.parse.
    const xcheck_module = b.createModule(.{
        .root_source_file = b.path("src/xcheck.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ini.zig", .module = ini_module }},
    });
    xcheck_module.addOptions("conformance_options", conformance_options);

    const xcheck_tests = b.addTest(.{ .root_module = xcheck_module });
    const run_xcheck = b.addRunArtifact(xcheck_tests);
    test_step.dependOn(&run_xcheck.step);

    // Deterministic property/round-trip battery over the Document editor.
    const document_property_module = b.createModule(.{
        .root_source_file = b.path("src/document_property.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ini.zig", .module = ini_module }},
    });

    const document_property_tests = b.addTest(.{ .root_module = document_property_module });
    const run_document_property = b.addRunArtifact(document_property_tests);
    test_step.dependOn(&run_document_property.step);

    // Bounded fuzz regression test: 1000 iterations with a fixed seed, always
    // included in `zig build test` so the round-trip invariant is never skipped.
    const fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("fuzz/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ini", .module = ini_module }},
        }),
    });
    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
    test_step.dependOn(&run_fuzz_tests.step);

    // Differential harness tool. `zig build differential` compiles it.
    // Run manually: zig-out/bin/differential <dialect> <fixture_file>
    const differential_exe = b.addExecutable(.{
        .name = "differential",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/differential.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ini", .module = ini_module }},
        }),
    });
    b.installArtifact(differential_exe);
    const differential_step = b.step("differential", "Build the differential harness tool");
    differential_step.dependOn(&differential_exe.step);

    if (target.result.os.tag != .freestanding and target.result.os.tag != .other) {
        // Random-input fuzzer. Sidesteps broken `zig test --fuzz` in 0.16.0.
        // `zig build fuzz -- --iters N` runs N iterations.
        const fuzz_exe = b.addExecutable(.{
            .name = "ini-fuzz",
            .root_module = b.createModule(.{
                .root_source_file = b.path("fuzz/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "ini", .module = ini_module }},
            }),
        });
        b.installArtifact(fuzz_exe);
        const run_fuzz = b.addRunArtifact(fuzz_exe);
        if (b.args) |args| run_fuzz.addArgs(args);
        const fuzz_step = b.step("fuzz", "Run the random-input fuzzer (pass -- --iters N etc.)");
        fuzz_step.dependOn(&run_fuzz.step);

        // Microbenchmarks. Always built ReleaseFast for representative timing.
        const bench_exe = b.addExecutable(.{
            .name = "ini-bench",
            .root_module = b.createModule(.{
                .root_source_file = b.path("bench/main.zig"),
                .target = target,
                .optimize = .ReleaseFast,
                .imports = &.{.{ .name = "ini", .module = ini_module }},
            }),
        });
        const run_bench = b.addRunArtifact(bench_exe);
        const bench_step = b.step("bench", "Run microbenchmarks");
        bench_step.dependOn(&run_bench.step);

        // Runnable examples. `zig build examples` builds all; `zig build example-NAME` runs one.
        const examples_step = b.step("examples", "Build all examples");
        inline for (.{ "basic", "typed", "edit", "spans", "stream", "dialects" }) |name| {
            const exe = b.addExecutable(.{
                .name = "example-" ++ name,
                .root_module = b.createModule(.{
                    .root_source_file = b.path("examples/" ++ name ++ ".zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "ini", .module = ini_module }},
                }),
            });
            const install = b.addInstallArtifact(exe, .{});
            examples_step.dependOn(&install.step);

            const run = b.addRunArtifact(exe);
            const run_step = b.step("example-" ++ name, "Run the " ++ name ++ " example");
            run_step.dependOn(&run.step);
        }
    }

    // Generated reference documentation. `zig build docs` emits
    // zig-out/docs/index.html from the library's public API.
    const docs_obj = b.addObject(.{
        .name = "ini-docs",
        .root_module = b.createModule(.{
            .root_source_file = root,
            .target = target,
            .optimize = optimize,
        }),
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate reference documentation into zig-out/docs/");
    docs_step.dependOn(&install_docs.step);
}
