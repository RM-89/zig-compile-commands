//! Helper executable invoked by `zig-compile-commands` at make time.
//!
//! The build script cannot resolve the final location of generated files
//! (config headers, emitted include trees, ...) while it is running; those
//! paths only exist once the make phase runs. To work around that, the build
//! script emits a JSON template in which every path that needs resolving is
//! represented by a placeholder of the form `@@ZCC_PATH_<n>@@`, and then runs
//! this program with the resolved paths as arguments. The placeholder `<n>` is
//! replaced by the JSON-escaped `argv[4 + n]`.
//!
//! Usage:
//!   gen_compile_commands <template-file> <output-dir> <output-filename> <path0> <path1> ...
const std = @import("std");
const Io = std.Io;

const token_prefix = "@@ZCC_PATH_";
const token_suffix = "@@";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4) return error.MissingArguments;

    const template_path = args[1];
    const out_dir = args[2];
    const out_filename = args[3];
    const paths = args[4..];

    var template_file = if (Io.Dir.path.isAbsolute(template_path))
        try Io.Dir.openFileAbsolute(io, template_path, .{})
    else
        try Io.Dir.cwd().openFile(io, template_path, .{});
    defer template_file.close(io);
    var template_reader = template_file.reader(io, &.{});
    const template = try template_reader.interface.allocRemaining(arena, .unlimited);

    var out: std.ArrayList(u8) = .empty;

    var i: usize = 0;
    while (i < template.len) {
        if (std.mem.startsWith(u8, template[i..], token_prefix)) {
            const rest = template[i + token_prefix.len ..];
            const end = std.mem.indexOf(u8, rest, token_suffix) orelse
                return error.InvalidTemplate;
            const index = try std.fmt.parseInt(usize, rest[0..end], 10);
            if (index >= paths.len) return error.InvalidTemplate;
            try jsonEscape(&out, arena, paths[index]);
            i += token_prefix.len + end + token_suffix.len;
        } else {
            try out.append(arena, template[i]);
            i += 1;
        }
    }

    const out_path = try Io.Dir.path.join(arena, &.{ out_dir, out_filename });
    var out_file = if (Io.Dir.path.isAbsolute(out_path))
        try Io.Dir.createFileAbsolute(io, out_path, .{})
    else
        try Io.Dir.cwd().createFile(io, out_path, .{});
    defer out_file.close(io);
    try out_file.writeStreamingAll(io, out.items);
}

fn jsonEscape(out: *std.ArrayList(u8), arena: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(arena, "\\\""),
        '\\' => try out.appendSlice(arena, "\\\\"),
        0...0x1f => {
            const hex = "0123456789abcdef";
            try out.appendSlice(arena, &.{
                '\\', 'u', '0', '0', hex[c >> 4], hex[c & 0xf],
            });
        },
        else => try out.append(arena, c),
    };
}
