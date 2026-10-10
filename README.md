# zig compile_commands.json

A simple zig module to generate compile_commands.json from a slice of build
targets. Useful if you are using zig as a build system for C/C++.

Supports zig v0.17.0. Older versions are available in the commit history, but
not maintained.

## Example Usage

To get the package in your project, `cd` into its root directory and run:

```bash
zig fetch --save-exact=compile_commands "https://github.com/RM-89/zig-compile-commands/archive/e1bcfe4300849a187387ef721d7fbc3cfc2ab849.tar.gz"
```

This will add an entry to your `build.zig.zon` dependencies list. You can change the commit hash in the URL for other versions.

Use it in your `build.zig` like this:

```zig
pub fn build(b: *std.Build) !void {
    // import the dependency's build.zig
    const zcc = b.lazyImport(@This(), "compile_commands").?;

    // make a list of targets that have include files and c source files
    var targets: std.ArrayList(*std.Build.Step.Compile) = .empty;

    // create your executable
    const exe = b.addExecutable(.{
        .name = "my-project",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // keep track of it, so later we can pass it to compile_commands
    try targets.append(b.allocator, exe);
    // maybe some other targets, too?
    const exe_2 = b.addExecutable(...);
    b.installArtifact(exe_2);
    try targets.append(b.allocator, exe_2);

    // If you have a lib which is a standalone output of the build, like exe and
    // exe_2 are, append it to the list of targets. But if exe or exe_2 links
    // lib, then it will be visited by the compile_commands.json generator
    // automatically
    const lib = b.addLibrary(...);
    try targets.append(b.allocator, lib);

    // Always call createStep last, because it will analyze the build graph at
    // the moment it is called. The "cdb" string is the name the step will be
    // registered under.
    //
    // This function returns the step. One thing you might use this for is to
    // make it a dependency of the main install step of the std.Build, so that
    // `zig build` also generates the compile_commands.json.
    _ = zcc.createStep(b, .{
        .name = "cdb",
        .targets = targets.items,
    });
}
```

And you're all done. Just run `zig build cdb` to generate the `compile_commands.json`
file according to your current build graph.

## Go-to-definition goes to header and not to source file, and/or source files are excluded by clangd

Clangd will filter out source files in a compilation commands database if those
source files are not contained by the directory the database is in. One
consequence of this is that `compile_commands.json` must be present in the
folder that `zig-pkg/` is in (which it probably is, so you are probably fine)
in order for dependencies fetched by zig to get indexed by clangd. Out of tree
source dependencies that you try to include will not be indexed. This includes
zig fetched dependencies in versions of zig before 0.16.0, when dependencies
were fetched into the global cache dir.

## Building `compile_commands.json` fails or panics

The Zig build system creates folders at build time, to place generated files in
(config headers, emitted include trees, ...). The exact locations of those files
can only be known during the make phase of a Zig 0.17 build, not while your
`build.zig` is running. For this reason, when zig-compile-commands scans your
build graph it records every `LazyPath` it encounters and substitutes the
resolved paths (which it gets from the make phase) into the generated file at
the end. Through those `LazyPath`s, the step that generates
`compile_commands.json` automatically depends on the steps that generate the
files, so no extra work is normally required.

One caveat: steps added to the build graph after `createStep` is called are not
scanned, so their generated files will be missing from the database. Make sure
nothing is added to the build graph after `createStep` is called. If you want to
be certain that everything needed for the `compile_commands.json` is built
before the file is generated, you can depend on the targets' compile steps:

```zig
    const compile_commands_step = zcc.createStep(b, .{
        .name = "cdb",
        .targets = targets.items,
    });
    // Build everything in the project before generating the compile_commands
    for (targets.items) |target| compile_commands_step.dependOn(&target.step);
```
