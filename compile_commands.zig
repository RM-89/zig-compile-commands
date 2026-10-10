const std = @import("std");
const get_flags = @import("get_flags.zig");
const gen_helper_source = @embedFile("gen_compile_commands.zig");

const LazyPath = std.Build.LazyPath;
const TargetsSlice = []*std.Build.Step.Compile;

/// Prefix/suffix used to mark paths that must be resolved by the make phase in
/// the JSON template. Must stay in sync with `gen_compile_commands.zig`.
pub const path_token_prefix = "@@ZCC_PATH_";
pub const path_token_suffix = "@@";

pub const CompileCommandOptions = struct {
    name: []const u8,
    targets: TargetsSlice,
    // Alternative command driver path (eg: /usr/local/bin/clang++)
    // It will use `clang` if not specified this.
    driver: ?[]const u8 = null,
    // Include many flags specifying all the features of the specific
    // target cpu. makes compile_commands.json a much much larger file, but may
    // fix some incorrect LSP stuff indicating, for example, whether simd
    // extensions are available
    include_cpu_features: bool = false,
    // output the compile_commands.json to a file other than
    // $PWD/compile_commands.json. Mainly used by tests. Will cause an error
    // the file path does not exist.
    // NOTE: if you choose this then be aware that this step will depend on the
    // generation of this path.
    custom_output_directory: ?std.Build.LazyPath = null,
    // Output a file that is called something other than "compile_commands.json"
    custom_output_filename: ?[]const u8 = null,
};

pub const CompileCommandEntry = struct {
    arguments: []const []const u8,
    directory: []const u8,
    file: []const u8,
    output: []const u8,
};

/// Collects all `LazyPath`s that appear in compile_commands.json while the
/// compile_commands entries are being computed at configure time. Each path is
/// assigned a token of the form `@@ZCC_PATH_<n>@@`; the token is what ends up
/// inside the JSON template. During the make phase the resolved paths are passed
/// as command line arguments to `gen_compile_commands`, in order, and the tokens
/// are replaced.
pub const PathRegistry = struct {
    paths: std.ArrayList(LazyPath) = .empty,
    is_dirs: std.ArrayList(bool) = .empty,

    pub fn add(self: *PathRegistry, b: *std.Build, path: LazyPath, is_dir: bool) []const u8 {
        const index = self.paths.items.len;
        self.paths.append(b.allocator, path.dupe(b.graph)) catch @panic("OOM");
        self.is_dirs.append(b.allocator, is_dir) catch @panic("OOM");
        return b.fmt("{s}{d}{s}", .{ path_token_prefix, index, path_token_suffix });
    }
};

pub fn createStep(b: *std.Build, options: CompileCommandOptions) *std.Build.Step {
    // Compute all of the compile_commands.json entries at configure time. Any
    // path which cannot be fully resolved until the make phase (config headers,
    // emitted include trees, generated source files, ...) is replaced by a
    // token, and the corresponding `LazyPath` is recorded in `registry`.
    var registry = PathRegistry{};
    var compile_commands: std.ArrayList(CompileCommandEntry) = .empty;
    var idx: usize = 0;
    var csteps: std.ArrayList(*std.Build.Step.Compile) = .empty;
    csteps.appendSlice(b.allocator, options.targets) catch @panic("OOM");
    while (idx < csteps.items.len) : (idx += 1) {
        const compile_step = csteps.items[idx];
        get_flags.compileStepToCompileCommandEntries(compile_step, options, &registry, &compile_commands, &csteps) catch |err| {
            std.log.err("Error getting compile commands of compile step {s}: {}", .{ compile_step.name, err });
            continue;
        };
    }

    // Serialize the entries (with path tokens) to a JSON template.
    const template = std.json.Stringify.valueAlloc(b.allocator, compile_commands.items, .{
        .whitespace = .indent_tab,
        .emit_null_optional_fields = false,
    }) catch @panic("OOM");

    const write_files = b.addWriteFiles();
    const template_lp = write_files.add("compile_commands_template.json", template);
    const helper_src_lp = write_files.add("gen_compile_commands.zig", gen_helper_source);

    // Compile the helper program for the host; it substitutes the resolved
    // paths into the JSON template and writes the final
    // "compile_commands.json".
    const helper_exe = b.addExecutable(.{
        .name = "zcc-gen-compile-commands",
        .root_module = b.createModule(.{
            .root_source_file = helper_src_lp,
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });

    const run = b.addRunArtifact(helper_exe);
    run.addFileArg2(template_lp, .{ .make_absolute = true });
    const output_directory: LazyPath = options.custom_output_directory orelse
        .{ .relative = .{ .base = .build_root } };
    run.addDirectoryArg2(output_directory, .{ .make_absolute = true });
    run.addArg(options.custom_output_filename orelse "compile_commands.json");
    for (registry.paths.items, registry.is_dirs.items) |path, is_dir| {
        const arg_options = std.Build.Step.Run.PathArgOptions{ .make_absolute = true };
        if (is_dir) {
            run.addDirectoryArg2(path, arg_options);
        } else {
            run.addFileArg2(path, arg_options);
        }
    }
    // The helper writes directly to the requested output directory, which is a
    // side effect that the build system does not know about.
    run.has_side_effects = true;

    const cdb_step = b.step(options.name, "Create compile_commands.json");
    cdb_step.dependOn(&run.step);

    return &run.step;
}
