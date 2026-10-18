//! Terminal UI helpers for Pic: colours, boxes and wrapped reply panels.
//!
//! This is plain ANSI + UTF-8 output with no raw-mode tricks, so it behaves the same on
//! Linux, macOS and Windows 10+. Everything draws at a fixed WIDTH columns.
const std = @import("std");
const builtin = @import("builtin");

pub const WIDTH: usize = 72;
pub var color: bool = true; // toggled by /color

pub const Style = enum { plain, accent, user, dim, ok, warn, err };
pub const Kind = enum { ok, warn, err, info };

fn code(s: Style) []const u8 {
    return switch (s) {
        .plain => "\x1b[0m",
        .accent => "\x1b[1;36m",
        .user => "\x1b[1;32m",
        .dim => "\x1b[2m",
        .ok => "\x1b[32m",
        .warn => "\x1b[33m",
        .err => "\x1b[31m",
    };
}

/// Call once at startup. Windows consoles need UTF-8 and ANSI switched on, and
/// launching cmd.exe (with a code-page change) does both for the shared console.
pub fn init(io: std.Io) void {
    if (builtin.os.tag != .windows) return;
    var child = std.process.spawn(io, .{ .argv = &.{ "cmd", "/c", "chcp 65001 >nul" } }) catch return;
    _ = child.wait(io) catch {};
}

pub fn set(w: *std.Io.Writer, s: Style) !void {
    if (color) try w.writeAll(code(s));
}

pub fn put(w: *std.Io.Writer, s: Style, text: []const u8) !void {
    try set(w, s);
    try w.writeAll(text);
    try set(w, .plain);
}

/// Display width: counts UTF-8 code points (skips continuation bytes).
fn cols(s: []const u8) usize {
    var n: usize = 0;
    for (s) |b| {
        if ((b & 0xC0) != 0x80) n += 1;
    }
    return n;
}

fn repeat(w: *std.Io.Writer, s: []const u8, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try w.writeAll(s);
}

/// A horizontal border line, e.g. "╭─ Title ────╮". Pass "" for `right` to leave it open.
fn edge(w: *std.Io.Writer, left: []const u8, title: []const u8, right: []const u8) !void {
    try put(w, .dim, left);
    var used: usize = 2;
    if (title.len > 0) {
        try put(w, .dim, "─ ");
        try put(w, .accent, title);
        try put(w, .dim, " ");
        used += 3 + cols(title);
    }
    try set(w, .dim);
    try repeat(w, "─", WIDTH -| used);
    try w.writeAll(right);
    try set(w, .plain);
    try w.writeAll("\n");
}

/// A boxed row with two columns; the first is padded to `a_pad` columns.
fn row(w: *std.Io.Writer, a: []const u8, a_style: Style, a_pad: usize, b: []const u8, b_style: Style) !void {
    try put(w, .dim, "│ ");
    try put(w, a_style, a);
    try repeat(w, " ", a_pad -| cols(a));
    try put(w, b_style, b);
    try repeat(w, " ", WIDTH -| (4 + @max(a_pad, cols(a)) + cols(b)));
    try put(w, .dim, " │\n");
}

pub fn banner(w: *std.Io.Writer, info: []const u8) !void {
    try w.writeAll("\n");
    try edge(w, "╭", "", "╮");
    try row(w, "◉ Pic", .accent, 10, "your local AI agent", .dim);
    try row(w, info, .dim, 0, "", .plain);
    try row(w, "/help", .accent, 8, "commands   ·   exit to quit", .dim);
    try edge(w, "╰", "", "╯");
    try w.flush();
}

pub fn help(w: *std.Io.Writer) !void {
    const commands = [_][2][]const u8{
        .{ "<text>", "just talk, or tell me what to do" },
        .{ "/code <desc>", "write a code file in this folder" },
        .{ "/apps", "list the apps I may launch" },
        .{ "/mute  /unmute", "spoken replies off / on" },
        .{ "/color", "turn colours on / off" },
        .{ "/clear", "clear the screen" },
        .{ "/forget", "wipe this session's memory" },
        .{ "/health", "check LM Studio and the model" },
        .{ "exit", "quit" },
    };
    const examples = [_][]const u8{
        "open youtube",
        "play back in black",
        "nvidia stock price",
        "summarise https://example.com",
        "/code a python script that renames files",
    };
    try w.writeAll("\n");
    try edge(w, "╭", "Commands", "╮");
    for (commands) |c| try row(w, c[0], .accent, 16, c[1], .plain);
    try edge(w, "├", "Try saying", "┤");
    for (examples) |e| try row(w, e, .plain, 0, "", .plain);
    try edge(w, "╰", "", "╯");
    try w.flush();
}

pub fn boxOpen(w: *std.Io.Writer, title: []const u8) !void {
    try w.writeAll("\n");
    try edge(w, "╭", title, "╮");
}

pub fn boxRow(w: *std.Io.Writer, label: []const u8, value: []const u8, style: Style) !void {
    try row(w, label, .plain, 12, value, style);
}

pub fn boxClose(w: *std.Io.Writer) !void {
    try edge(w, "╰", "", "╯");
    try w.flush();
}

fn gutter(w: *std.Io.Writer) !void {
    try put(w, .dim, "│ ");
}

/// Pic's answer: a left-barred panel with word wrapping. Short lines (including
/// indented code) are printed untouched; only over-long lines are re-wrapped.
pub fn reply(w: *std.Io.Writer, text: []const u8) !void {
    const inner = WIDTH - 4;
    try w.writeAll("\n");
    try edge(w, "╭", "Pic", "");
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, text, " \t\r\n"), '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\r");
        try gutter(w);
        if (cols(line) <= inner) {
            try w.writeAll(line);
            try w.writeAll("\n");
            continue;
        }
        var used: usize = 0;
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        while (words.next()) |word| {
            const n = cols(word);
            if (used > 0 and used + 1 + n > inner) {
                try w.writeAll("\n");
                try gutter(w);
                used = 0;
            }
            if (used > 0) {
                try w.writeAll(" ");
                used += 1;
            }
            try w.writeAll(word);
            used += n;
        }
        try w.writeAll("\n");
    }
    try edge(w, "╰", "", "");
    try w.flush();
}

/// Dim "which tool did the router pick" line shown above a reply.
pub fn trace(w: *std.Io.Writer, tool: []const u8, target: []const u8) !void {
    try set(w, .dim);
    try w.writeAll(" ↳ ");
    try w.writeAll(tool);
    if (target.len > 0) {
        try w.writeAll(" → ");
        try w.writeAll(target[0..@min(target.len, 48)]);
    }
    try set(w, .plain);
    try w.writeAll("\n");
}

pub fn status(w: *std.Io.Writer, kind: Kind, text: []const u8) !void {
    const icon: []const u8 = switch (kind) {
        .ok => "✓",
        .warn => "!",
        .err => "✗",
        .info => "•",
    };
    const style: Style = switch (kind) {
        .ok => .ok,
        .warn => .warn,
        .err => .err,
        .info => .dim,
    };
    try w.writeAll(" ");
    try put(w, style, icon);
    try w.writeAll(" ");
    try w.writeAll(text);
    try w.writeAll("\n");
    try w.flush();
}

pub fn prompt(w: *std.Io.Writer) !void {
    try w.writeAll("\n");
    try put(w, .user, " you ❯ ");
    try w.flush();
}

/// Shown while the model works; the call blocks, so this is a single static frame.
pub fn thinking(w: *std.Io.Writer) !void {
    try put(w, .dim, " ⠋ thinking…");
    try w.flush();
}

pub fn clearLine(w: *std.Io.Writer) !void {
    try w.writeAll(if (color) "\r\x1b[2K" else "\n");
    try w.flush();
}

pub fn clear(w: *std.Io.Writer) !void {
    try w.writeAll(if (color) "\x1b[2J\x1b[H" else "\n\n\n");
}
