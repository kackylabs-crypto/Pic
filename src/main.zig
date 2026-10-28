//! Pic - a lightweight local AI agent in a single Zig file, no dependencies.
//! Works on Windows, macOS and Linux. The only model it talks to is
//! mistralai/ministral-3-3b, served by LM Studio (start its local server first).
//! Written for the Zig 0.16 `std.Io` API (as in Jenson's main.zig): zig build-exe pic.zig -O ReleaseSmall
const std = @import("std");
const builtin = @import("builtin");
const tui = @import("tui.zig");

const LM_BASE = "http://localhost:1234"; // change this if LM Studio uses another port
const CHAT_URL = LM_BASE ++ "/v1/chat/completions";
const MODELS_URL = LM_BASE ++ "/v1/models";
const MODEL = "mistralai/ministral-3-3b"; // the one and only model
const BROWSER_UA = "Mozilla/5.0 (compatible; Pic/1.0)";
const TMP_FILE = ".pic-tmp.txt"; // scratch files, created in the current directory
const SAY_FILE = ".pic-say.txt";
const MIC_FILE = ".pic-voice.wav";
const MAX_HISTORY = 6; // chat turns remembered in memory

const PERSONA =
\\You are Pic, a friendly, quick and lightly witty assistant. You are a real program
\\running on the user's own computer, not a character in a story.
\\
\\Facts about yourself (answer truthfully, never guess):
\\- You are a single dependency-free Zig binary that runs on Windows, macOS and Linux.
\\- Your words come from mistralai/ministral-3-3b, running locally in LM Studio. Only
\\  the web tools you are asked to use go online.
\\- You can open websites and apps, search, play music, check time and stock
\\  prices, summarise web pages and write code files. You cannot do anything beyond that.
\\
\\Style: warm, brief and natural. Plain text, no markdown headings. Match the length of
\\the answer to the question. If you don't know something, say so in one line and offer
\\the closest useful thing. Never invent abilities.
;

const CODE_PROMPT =
\\You are a code generator. Output ONLY the code: no markdown fences, no explanation,
\\no commentary. Start with the first line of code and end with the last. Produce a
\\complete, runnable file with all needed imports and a main entry point where the
\\language has one. Handle obvious errors.
;

const SUMMARY_PROMPT = "Summarise the web page text you are given in 3-6 clear sentences, using only that text. If it looks like an error page or is empty, say so.";

// The router prompt is ROUTER_HEAD + the apps allowed on this OS + ROUTER_TAIL.
const ROUTER_HEAD =
\\You are the router for Pic, a small local assistant. Read the user's message and choose
\\exactly ONE tool. Reply ONLY with one JSON object: {"tool": "...", "target": "..."}
\\
\\Tools:
\\- chat: the user wants an answer, explanation, opinion, advice, writing, maths,
\\  translation or conversation. target = the user's message.
\\- say: greetings, thanks, and questions about Pic itself. target = a short, friendly
\\  reply of one sentence.
\\- open_url: open a website. target = domain or full URL.
\\- open_app: launch a local app. target must be one of:
;

const ROUTER_TAIL =
\\- get_time: the user asks for the current time, date or year. target = "".
\\- search_web / search_youtube / search_wikipedia / search_github / search_amazon /
\\  search_wallpapers: search that site. target = the query only.
\\- play_music: play a song or artist on YouTube Music. target = song or artist.
\\- fetch_url: read and summarise a specific web page. target = full URL.
\\- get_stock_price: live stock price. target = ticker symbol, e.g. NVDA.
\\- do_nothing: only for requests Pic truly cannot do. target = "".
\\
\\Examples:
\\"open youtube" -> {"tool": "open_url", "target": "youtube.com"}
\\"hello" -> {"tool": "say", "target": "Hey! What can I do for you?"}
\\"what time is it" -> {"tool": "get_time", "target": ""}
\\"explain how vaccines work" -> {"tool": "chat", "target": "explain how vaccines work"}
\\"play back in black" -> {"tool": "play_music", "target": "back in black"}
\\"nvidia stock price" -> {"tool": "get_stock_price", "target": "NVDA"}
\\"summarise https://example.com" -> {"tool": "fetch_url", "target": "https://example.com"}
;

const TOOLS = [_][]const u8{
    "chat",          "say",             "open_url",          "open_app",
    "get_time",      "search_web",      "search_youtube",    "search_wikipedia",
    "search_github", "search_amazon",   "search_wallpapers", "play_music",
    "fetch_url",     "get_stock_price", "do_nothing",
};

const Site = struct { tool: []const u8, label: []const u8, template: []const u8 };
const SITES = [_]Site{
    .{ .tool = "search_web", .label = "the web", .template = "https://duckduckgo.com/?q={}" },
    .{ .tool = "search_youtube", .label = "YouTube", .template = "https://www.youtube.com/results?search_query={}" },
    .{ .tool = "search_wikipedia", .label = "Wikipedia", .template = "https://en.wikipedia.org/w/index.php?search={}" },
    .{ .tool = "search_github", .label = "GitHub", .template = "https://github.com/search?q={}" },
    .{ .tool = "search_amazon", .label = "Amazon", .template = "https://www.amazon.com/s?k={}" },
    .{ .tool = "search_wallpapers", .label = "Wallhaven", .template = "https://wallhaven.cc/search?q={}" },
    .{ .tool = "play_music", .label = "YouTube Music", .template = "https://music.youtube.com/search?q={}" },
};

// Apps Pic may launch, with the command for each OS. Edit and rebuild to allow more.
const App = struct { name: []const u8, linux: []const u8, mac: []const u8, win: []const u8 };
const APPS = [_]App{
    .{ .name = "browser", .linux = "firefox", .mac = "Safari", .win = "msedge" },
    .{ .name = "terminal", .linux = "x-terminal-emulator", .mac = "Terminal", .win = "cmd" },
    .{ .name = "editor", .linux = "gedit", .mac = "TextEdit", .win = "notepad" },
    .{ .name = "calculator", .linux = "gnome-calculator", .mac = "Calculator", .win = "calc" },
    .{ .name = "vscode", .linux = "code", .mac = "Visual Studio Code", .win = "code" },
    .{ .name = "spotify", .linux = "spotify", .mac = "Spotify", .win = "spotify" },
    .{ .name = "vlc", .linux = "vlc", .mac = "VLC", .win = "vlc" },
};

// Checked in order, so "javascript" is tried before "java".
const Lang = struct { word: []const u8, ext: []const u8 };
const LANGUAGES = [_]Lang{
    .{ .word = "python", .ext = "py" }, .{ .word = "rust", .ext = "rs" }, .{ .word = "javascript", .ext = "js" },
    .{ .word = "typescript", .ext = "ts" }, .{ .word = "html", .ext = "html" }, .{ .word = "bash", .ext = "sh" },
    .{ .word = "c++", .ext = "cpp" }, .{ .word = "java", .ext = "java" }, .{ .word = "golang", .ext = "go" },
    .{ .word = "zig", .ext = "zig" },
};

const Action = struct { tool: []const u8, target: []const u8 = "" };
const Msg = struct { role: []const u8, content: []const u8 };
const Turn = struct { user: []u8, assistant: []u8 };
const State = struct { history: std.ArrayList(Turn) = .empty, speech: bool = true };
const Http = struct { status: u16, body: []const u8 };

// LM Studio structured output: forces {"tool": <one of TOOLS>, "target": <string>}.
const RESPONSE_FORMAT =
\\"response_format":{"type":"json_schema","json_schema":{"name":"action","strict":true,"schema":{"type":"object",
\\"properties":{"tool":{"type":"string","enum":["chat","say","open_url","open_app","get_time","search_web","search_youtube","search_wikipedia","search_github","search_amazon","search_wallpapers","play_music","fetch_url","get_stock_price","do_nothing"]},"target":{"type":"string"}},
\\"required":["tool","target"]}}}
;

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn eql(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

fn say(stdout: *std.Io.Writer, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    const text: []const u8 = std.fmt.bufPrint(&buf, fmt, args) catch "(message too long)";
    try tui.reply(stdout, text);
}

fn note(stdout: *std.Io.Writer, kind: tui.Kind, comptime fmt: []const u8, args: anytype) !void {
    var buf: [512]u8 = undefined;
    const text: []const u8 = std.fmt.bufPrint(&buf, fmt, args) catch "(message too long)";
    try tui.status(stdout, kind, text);
}

fn fail(stdout: *std.Io.Writer, err: anyerror) !void {
    if (eql(@errorName(err), "Unreachable")) {
        try note(stdout, .err, "I can't reach LM Studio at {s}. Start its local server and load {s}.", .{ LM_BASE, MODEL });
    } else {
        try note(stdout, .err, "Something went wrong ({s}).", .{@errorName(err)});
    }
}

fn cmdFor(app: App) []const u8 {
    return switch (builtin.os.tag) {
        .windows => app.win,
        .macos => app.mac,
        else => app.linux,
    };
}

fn appNames(a: std.mem.Allocator) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (APPS, 0..) |app, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, app.name);
    }
    return out.items;
}

fn urlEncode(a: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    const hex = "0123456789ABCDEF";
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            try out.append(a, c);
        } else {
            try out.append(a, '%');
            try out.append(a, hex[c >> 4]);
            try out.append(a, hex[c & 0x0F]);
        }
    }
    return out.items;
}

fn fillTemplate(a: std.mem.Allocator, template: []const u8, value: []const u8) ![]u8 {
    const encoded = try urlEncode(a, value);
    const idx = std.mem.indexOf(u8, template, "{}") orelse return try a.dupe(u8, template);
    return try std.fmt.allocPrint(a, "{s}{s}{s}", .{ template[0..idx], encoded, template[idx + 2 ..] });
}

fn normalizeUrl(a: std.mem.Allocator, target: []const u8) ?[]const u8 {
    const t = trim(target);
    var end: usize = 0;
    while (end < t.len and t[end] > ' ') end += 1;
    const first = t[0..end];
    if (first.len == 0) return null;
    for (first) |c| if (std.mem.indexOfScalar(u8, "\"'<>^|`\\\x7f", c) != null) return null;
    const has_scheme = std.mem.startsWith(u8, first, "http://") or std.mem.startsWith(u8, first, "https://");
    if (!has_scheme and std.mem.indexOf(u8, first, "://") != null) return null;
    const url = if (has_scheme) first else (std.fmt.allocPrint(a, "https://{s}", .{first}) catch return null);
    const scheme_end = (std.mem.indexOf(u8, url, "://") orelse return null) + 3;
    const after = url[scheme_end..];
    const host = after[0 .. std.mem.indexOfAny(u8, after, "/?#") orelse after.len];
    if (std.mem.indexOfScalar(u8, host, '.') == null) return null;
    return url;
}

fn http(io: std.Io, a: std.mem.Allocator, method: std.http.Method, url: []const u8, payload: ?[]const u8, ua: []const u8) !Http {
    var client = std.http.Client{ .allocator = a, .io = io };
    defer client.deinit();
    var body = std.Io.Writer.Allocating.init(a);
    defer body.deinit();
    const uri = try std.Uri.parse(url);
    const result = try client.fetch(.{
        .location = .{ .uri = uri },
        .method = method,
        .payload = payload,
        .response_writer = &body.writer,
        .extra_headers = &.{
            .{ .name = "User-Agent", .value = ua },
            .{ .name = "Content-Type", .value = "application/json" },
        },
    });
    return .{ .status = @intFromEnum(result.status), .body = try a.dupe(u8, body.written()) };
}

fn complete(io: std.Io, a: std.mem.Allocator, msgs: []const Msg, max_tokens: u32, temperature: f32, schema: bool) ![]const u8 {
    var use_schema = schema;
    while (true) {
        var buf = std.Io.Writer.Allocating.init(a);
        defer buf.deinit();
        const w = &buf.writer;
        try w.print("{{\"model\":\"{s}\",\"temperature\":{d:.2},\"max_tokens\":{d},\"stream\":false,", .{ MODEL, temperature, max_tokens });
        if (use_schema) try w.writeAll(RESPONSE_FORMAT);
        try w.writeAll("\"messages\":");
        try std.json.Stringify.value(msgs, .{}, w);
        try w.writeAll("}");

        const res = http(io, a, .POST, CHAT_URL, buf.written(), BROWSER_UA) catch return error.Unreachable;
        if (res.status == 400 and use_schema) {
            use_schema = false;
            continue;
        }
        if (res.status >= 400) {
            std.debug.print("[LM Studio {d}] {s}\n", .{ res.status, res.body });
            return error.HttpError;
        }
        const Outer = struct { choices: []const struct { message: struct { content: ?[]const u8 = null } } };
        const parsed = try std.json.parseFromSlice(Outer, a, res.body, .{ .ignore_unknown_fields = true });
        if (parsed.value.choices.len == 0) return error.EmptyReply;
        return parsed.value.choices[0].message.content orelse "";
    }
}

fn route(io: std.Io, a: std.mem.Allocator, text: []const u8) !Action {
    const fallback = Action{ .tool = "chat", .target = text };
    const system = try std.fmt.allocPrint(a, "{s} {s}.\n{s}", .{ ROUTER_HEAD, try appNames(a), ROUTER_TAIL });
    const raw = try complete(io, a, &.{
        .{ .role = "system", .content = system },
        .{ .role = "user", .content = text },
    }, 150, 0.1, true);
    const start = std.mem.indexOfScalar(u8, raw, '{') orelse return fallback;
    const end = std.mem.lastIndexOfScalar(u8, raw, '}') orelse return fallback;
    if (start >= end) return fallback;
    const parsed = std.json.parseFromSlice(Action, a, raw[start .. end + 1], .{ .ignore_unknown_fields = true }) catch return fallback;
    for (TOOLS) |tool| {
        if (eql(tool, parsed.value.tool)) return parsed.value;
    }
    return fallback;
}

fn chatReply(io: std.Io, a: std.mem.Allocator, st: *State, text: []const u8) ![]const u8 {
    var msgs = std.ArrayList(Msg).empty;
    try msgs.append(a, .{ .role = "system", .content = PERSONA });
    for (st.history.items) |turn| {
        try msgs.append(a, .{ .role = "user", .content = turn.user });
        try msgs.append(a, .{ .role = "assistant", .content = turn.assistant });
    }
    try msgs.append(a, .{ .role = "user", .content = text });
    return trim(try complete(io, a, msgs.items, 1500, 0.6, false));
}

fn stripHtml(a: std.mem.Allocator, html: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    var last_space = true;
    while (i < html.len and out.items.len < 6000) {
        const c = html[i];
        if (c == '<') {
            const rest = html[i + 1 ..];
            if (std.ascii.startsWithIgnoreCase(rest, "script")) {
                i += 1 + (std.ascii.indexOfIgnoreCase(rest, "</script") orelse break);
            } else if (std.ascii.startsWithIgnoreCase(rest, "style")) {
                i += 1 + (std.ascii.indexOfIgnoreCase(rest, "</style") orelse break);
            }
            i = (std.mem.indexOfScalarPos(u8, html, i, '>') orelse break) + 1;
            if (!last_space) try out.append(a, ' ');
            last_space = true;
        } else if (std.ascii.isWhitespace(c)) {
            if (!last_space) try out.append(a, ' ');
            last_space = true;
            i += 1;
        } else {
            try out.append(a, c);
            last_space = false;
            i += 1;
        }
    }
    return out.items;
}

fn summarise(io: std.Io, a: std.mem.Allocator, target: []const u8) ![]const u8 {
    const url = normalizeUrl(a, target) orelse return "That doesn't look like a valid web address.";
    const res = http(io, a, .GET, url, null, BROWSER_UA) catch return "I couldn't fetch that page.";
    if (res.status >= 400) return "That page returned an error.";
    const text = try stripHtml(a, res.body);
    if (text.len == 0) return "That page had no readable text.";
    return trim(try complete(io, a, &.{
        .{ .role = "system", .content = SUMMARY_PROMPT },
        .{ .role = "user", .content = text },
    }, 400, 0.3, false));
}

fn stockPrice(io: std.Io, a: std.mem.Allocator, symbol: []const u8) ![]const u8 {
    var sym = trim(symbol);
    if (sym.len > 0 and sym[0] == '$') sym = sym[1..];
    if (sym.len == 0 or sym.len > 10) return "That doesn't look like a stock ticker.";
    var upper_buf: [10]u8 = undefined;
    const upper = std.ascii.upperString(&upper_buf, sym);
    const url = try std.fmt.allocPrint(a, "https://query1.finance.yahoo.com/v8/finance/chart/{s}", .{try urlEncode(a, upper)});
    const res = http(io, a, .GET, url, null, BROWSER_UA) catch return "I couldn't reach the stock service.";
    const Meta = struct { regularMarketPrice: ?f64 = null, currency: ?[]const u8 = null };
    const Chart = struct { chart: struct { result: ?[]const struct { meta: Meta } = null } };
    const none = try std.fmt.allocPrint(a, "I couldn't get a price for {s}.", .{upper});
    const parsed = std.json.parseFromSlice(Chart, a, res.body, .{ .ignore_unknown_fields = true }) catch return none;
    const results = parsed.value.chart.result orelse return none;
    if (results.len == 0) return none;
    const price = results[0].meta.regularMarketPrice orelse return none;
    return try std.fmt.allocPrint(a, "{s} is trading at {d:.2} {s}.", .{ upper, price, results[0].meta.currency orelse "USD" });
}

fn spawnOk(io: std.Io, argv: []const []const u8) bool {
    if (std.process.spawn(io, .{ .argv = argv })) |_| return true else |_| return false;
}

fn openUrl(io: std.Io, url: []const u8) bool {
    return switch (builtin.os.tag) {
        // rundll32 takes the URL as one argument; cmd's "start" would parse & and | in it.
        .windows => spawnOk(io, &.{ "rundll32", "url.dll,FileProtocolHandler", url }),
        .macos => spawnOk(io, &.{ "open", url }),
        else => spawnOk(io, &.{ "xdg-open", url }),
    };
}

fn launchApp(io: std.Io, cmd: []const u8) bool {
    return switch (builtin.os.tag) {
        .windows => spawnOk(io, &.{ "cmd", "/c", "start", "", cmd }),
        .macos => spawnOk(io, &.{ "open", "-a", cmd }),
        else => spawnOk(io, &.{cmd}),
    };
}

fn getTime(io: std.Io, a: std.mem.Allocator) ![]const u8 {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .windows => &.{ "cmd", "/c", "(date /t & time /t) > " ++ TMP_FILE },
        else => &.{ "sh", "-c", "date +'%H:%M on %A, %B %d, %Y' > " ++ TMP_FILE },
    };
    var child = std.process.spawn(io, .{ .argv = argv }) catch return "I cannot read the clock.";
    _ = child.wait(io) catch return "I cannot read the clock.";
    const file = std.Io.Dir.cwd().openFile(io, TMP_FILE, .{}) catch return "I cannot read the clock.";
    defer file.close(io);
    var buffer: [256]u8 = undefined;
    const n = file.readPositionalAll(io, &buffer, 0) catch return "I cannot read the clock.";
    const clock = try a.dupe(u8, trim(buffer[0..n]));
    std.mem.replaceScalar(u8, clock, '\n', ' ');
    std.mem.replaceScalar(u8, clock, '\r', ' ');
    return try std.fmt.allocPrint(a, "It's {s}.", .{clock});
}

fn speak(io: std.Io, text: []const u8) void {
    const clean = text[0..@min(text.len, 400)];
    if (clean.len == 0) return;
    {
        const file = std.Io.Dir.cwd().createFile(io, SAY_FILE, .{}) catch return;
        defer file.close(io);
        file.writePositionalAll(io, clean, 0) catch return;
    }
    switch (builtin.os.tag) {
        .macos => _ = spawnOk(io, &.{ "say", "-f", SAY_FILE }),
        .windows => _ = spawnOk(io, &.{ "powershell", "-NoProfile", "-Command", "Add-Type -AssemblyName System.Speech; (New-Object System.Speech.Synthesis.SpeechSynthesizer).Speak((Get-Content -Raw -Path '" ++ SAY_FILE ++ "'))" }),
        else => {
            if (!spawnOk(io, &.{ "espeak-ng", "-f", SAY_FILE })) _ = spawnOk(io, &.{ "espeak", "-f", SAY_FILE });
        },
    }
}

fn recordMic(io: std.Io, stdout: *std.Io.Writer, seconds: u32) !void {
    var dur_buf: [16]u8 = undefined;
    const duration = std.fmt.bufPrint(&dur_buf, "{d}", .{seconds}) catch "5";
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .linux => &.{ "ffmpeg", "-y", "-f", "alsa", "-i", "default", "-t", duration, "-ac", "1", "-ar", "16000", MIC_FILE },
        .macos => &.{ "ffmpeg", "-y", "-f", "avfoundation", "-i", ":0", "-t", duration, "-ac", "1", "-ar", "16000", MIC_FILE },
        .windows => &.{ "ffmpeg", "-y", "-f", "dshow", "-i", "audio=Microphone", "-t", duration, "-ac", "1", "-ar", "16000", MIC_FILE },
        else => return error.NotSupported,
    };
    try note(stdout, .info, "Listening for {d} seconds from the microphone...", .{seconds});
    var child = std.process.spawn(io, .{ .argv = argv }) catch |err| {
        try note(stdout, .err, "I couldn't access the microphone. Install FFmpeg and allow mic access.", .{});
        return err;
    };
    _ = child.wait(io) catch |err| {
        try note(stdout, .err, "The mic recording stopped before it finished.", .{});
        return err;
    };
    try note(stdout, .ok, "Saved a voice clip to ./{s}.", .{MIC_FILE});
}

fn stripFences(raw: []const u8) []const u8 {
    var s = trim(raw);
    if (std.mem.startsWith(u8, s, "```")) s = if (std.mem.indexOfScalar(u8, s, '\n')) |nl| s[nl + 1 ..] else "";
    if (std.mem.endsWith(u8, s, "```")) s = s[0 .. s.len - 3];
    return trim(s);
}

fn detectExt(request: []const u8, code: []const u8) []const u8 {
    var req_buf: [256]u8 = undefined;
    const n = @min(request.len, req_buf.len);
    const req = std.ascii.lowerString(req_buf[0..n], request[0..n]);
    for (LANGUAGES) |lang| {
        if (std.mem.indexOf(u8, req, lang.word) != null) return lang.ext;
    }
    if (std.mem.indexOf(u8, code, "<html") != null) return "html";
    if (std.mem.indexOf(u8, code, "def ") != null) return "py";
    return "txt";
}

fn saveCode(io: std.Io, a: std.mem.Allocator, code: []const u8, request: []const u8) ![]const u8 {
    const dir = std.Io.Dir.cwd();
    var slug_buf: [64]u8 = undefined;
    var len: usize = 0;
    for (request) |c| {
        if (len >= 40) break;
        if (std.ascii.isAlphanumeric(c)) {
            slug_buf[len] = std.ascii.toLower(c);
            len += 1;
        } else if (len > 0 and slug_buf[len - 1] != '_') {
            slug_buf[len] = '_';
            len += 1;
        }
    }
    while (len > 0 and slug_buf[len - 1] == '_') len -= 1;
    const slug: []const u8 = if (len == 0) "output" else slug_buf[0..len];
    const ext = detectExt(request, code);

    var counter: u32 = 1;
    var filename = try std.fmt.allocPrint(a, "{s}.{s}", .{ slug, ext });
    while (dir.statFile(io, filename, .{})) |_| {
        counter += 1;
        filename = try std.fmt.allocPrint(a, "{s}_{d}.{s}", .{ slug, counter, ext });
    } else |_| {}

    const file = try dir.createFile(io, filename, .{});
    defer file.close(io);
    try file.writePositionalAll(io, code, 0);
    try file.writePositionalAll(io, "\n", code.len);
    return filename;
}

fn writeCode(io: std.Io, a: std.mem.Allocator, stdout: *std.Io.Writer, request: []const u8) !void {
    if (request.len == 0) return say(stdout, "What would you like me to write? Try: /code a python script that renames files", .{});
    try tui.thinking(stdout);
    const raw = complete(io, a, &.{
        .{ .role = "system", .content = CODE_PROMPT },
        .{ .role = "user", .content = request },
    }, 3000, 0.3, false) catch |err| {
        try tui.clearLine(stdout);
        return fail(stdout, err);
    };
    try tui.clearLine(stdout);
    const code = stripFences(raw);
    const path = saveCode(io, a, code, request) catch |err| return fail(stdout, err);
    try note(stdout, .ok, "Saved {d} lines to ./{s}", .{ std.mem.count(u8, code, "\n") + 1, path });
}

fn runTool(io: std.Io, a: std.mem.Allocator, st: *State, action: Action, original: []const u8) ![]const u8 {
    const tool = action.tool;
    const target = trim(action.target);

    if (eql(tool, "chat")) return chatReply(io, a, st, original);
    if (eql(tool, "say")) return if (target.len == 0) "At your service." else target[0..@min(target.len, 300)];
    if (eql(tool, "get_time")) return getTime(io, a);
    if (eql(tool, "do_nothing")) return "Sorry, I can't do that one yet.";
    if (eql(tool, "fetch_url")) return summarise(io, a, target);
    if (eql(tool, "get_stock_price")) return stockPrice(io, a, target);

    if (eql(tool, "open_url")) {
        const url = normalizeUrl(a, target) orelse return "That doesn't look like a safe website.";
        if (!openUrl(io, url)) return "I couldn't open a browser on this system.";
        return try std.fmt.allocPrint(a, "Opening {s}.", .{target});
    }

    if (eql(tool, "open_app")) {
        var lower_buf: [64]u8 = undefined;
        if (target.len > lower_buf.len) return "That name is too long.";
        const lower = std.ascii.lowerString(&lower_buf, target);
        for (APPS) |app| {
            if (!eql(app.name, lower)) continue;
            if (!launchApp(io, cmdFor(app))) return try std.fmt.allocPrint(a, "I couldn't launch {s}; is it installed?", .{app.name});
            return try std.fmt.allocPrint(a, "Launching {s}.", .{app.name});
        }
        return try std.fmt.allocPrint(a, "I'm not allowed to launch {s}. Allowed: {s}.", .{ target, try appNames(a) });
    }

    for (SITES) |site| {
        if (!eql(tool, site.tool)) continue;
        if (target.len == 0) return "What should I search for?";
        const url = try fillTemplate(a, site.template, target);
        if (!openUrl(io, url)) return "I couldn't open a browser on this system.";
        return try std.fmt.allocPrint(a, "Searching {s} for {s}.", .{ site.label, target });
    }
    return try std.fmt.allocPrint(a, "I don't know how to do {s}.", .{tool});
}

fn remember(gpa: std.mem.Allocator, st: *State, user: []const u8, reply: []const u8) !void {
    if (st.history.items.len >= MAX_HISTORY) {
        const old = st.history.orderedRemove(0);
        gpa.free(old.user);
        gpa.free(old.assistant);
    }
    try st.history.append(gpa, .{
        .user = try gpa.dupe(u8, user),
        .assistant = try gpa.dupe(u8, reply[0..@min(reply.len, 600)]),
    });
}

fn forget(gpa: std.mem.Allocator, st: *State) void {
    for (st.history.items) |turn| {
        gpa.free(turn.user);
        gpa.free(turn.assistant);
    }
    st.history.clearRetainingCapacity();
}

const Outcome = struct { action: Action, reply: []const u8 };

fn think(io: std.Io, a: std.mem.Allocator, st: *State, text: []const u8) !Outcome {
    const action = try route(io, a, text);
    return .{ .action = action, .reply = try runTool(io, a, st, action, text) };
}

fn handle(io: std.Io, gpa: std.mem.Allocator, a: std.mem.Allocator, stdout: *std.Io.Writer, st: *State, text: []const u8) !void {
    try tui.thinking(stdout);
    const out = think(io, a, st, text) catch |err| {
        try tui.clearLine(stdout);
        return fail(stdout, err);
    };
    try tui.clearLine(stdout);
    if (!eql(out.action.tool, "chat")) try tui.trace(stdout, out.action.tool, out.action.target);
    try tui.reply(stdout, out.reply);
    if (st.speech) speak(io, out.reply);
    try remember(gpa, st, text, out.reply);
}

fn banner(stdout: *std.Io.Writer, st: *State) !void {
    var buf: [160]u8 = undefined;
    const info: []const u8 = std.fmt.bufPrint(&buf, "{s}  ·  {s}  ·  speech {s}", .{ MODEL, @tagName(builtin.os.tag), if (st.speech) "on" else "off" }) catch MODEL;
    try tui.banner(stdout, info);
}

fn health(io: std.Io, a: std.mem.Allocator, stdout: *std.Io.Writer, st: *State) !void {
    try tui.boxOpen(stdout, "Health");
    try tui.boxRow(stdout, "System", @tagName(builtin.os.tag), .plain);
    try tui.boxRow(stdout, "Speech", if (st.speech) "on" else "muted", .plain);
    if (http(io, a, .GET, MODELS_URL, null, BROWSER_UA)) |res| {
        const loaded = res.status < 400 and std.mem.indexOf(u8, res.body, MODEL) != null;
        try tui.boxRow(stdout, "LM Studio", "reachable at " ++ LM_BASE, .ok);
        try tui.boxRow(stdout, "Model", if (loaded) MODEL ++ " loaded" else MODEL ++ " NOT found, load it in LM Studio", if (loaded) .ok else .err);
    } else |_| {
        try tui.boxRow(stdout, "LM Studio", "NOT reachable at " ++ LM_BASE, .err);
    }
    try tui.boxClose(stdout);
}

fn command(io: std.Io, gpa: std.mem.Allocator, a: std.mem.Allocator, stdout: *std.Io.Writer, st: *State, text: []const u8) !void {
    const sp = std.mem.indexOfScalar(u8, text, ' ') orelse text.len;
    const word = text[0..sp];
    const rest = trim(text[sp..]);
    if (eql(word, "/help")) {
        try tui.help(stdout);
    } else if (eql(word, "/code")) {
        try writeCode(io, a, stdout, rest);
    } else if (eql(word, "/apps")) {
        try note(stdout, .info, "I can launch: {s}", .{try appNames(a)});
    } else if (eql(word, "/mute") or eql(word, "/unmute")) {
        st.speech = eql(word, "/unmute");
        try note(stdout, .info, "Spoken replies {s}.", .{if (st.speech) "on" else "off"});
    } else if (eql(word, "/voice") or eql(word, "/mic")) {
        const secs: u32 = if (rest.len == 0) 5 else std.fmt.parseInt(u32, rest, 10) catch 5;
        try recordMic(io, stdout, secs);
    } else if (eql(word, "/color")) {
        tui.color = !tui.color;
        try note(stdout, .info, "Colours {s}.", .{if (tui.color) "on" else "off"});
    } else if (eql(word, "/clear")) {
        try tui.clear(stdout);
        try banner(stdout, st);
    } else if (eql(word, "/forget")) {
        forget(gpa, st);
        try note(stdout, .info, "Memory cleared.", .{});
    } else if (eql(word, "/health")) {
        try health(io, a, stdout, st);
    } else {
        try note(stdout, .warn, "I don't know {s}. Type /help for the list.", .{word});
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var state = State{};
    defer {
        forget(gpa, &state);
        state.history.deinit(gpa);
    }

    tui.init(io);
    try banner(stdout, &state);

    while (true) {
        try tui.prompt(stdout);

        // Fresh reader each turn (Jenson's trick): it drops the '\n' left by takeDelimiterExclusive.
        var stdin_buffer: [32768]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
        const stdin = &stdin_reader.interface;
        const line = stdin.takeDelimiterExclusive('\n') catch break;
        const text = trim(line);
        if (text.len == 0) continue;
        if (eql(text, "exit") or eql(text, "quit")) break;

        // Everything a turn allocates lives in this arena and is freed in one go.
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        if (text[0] == '/') {
            try command(io, gpa, a, stdout, &state, text);
        } else {
            try handle(io, gpa, a, stdout, &state, text);
        }
    }
    try tui.status(stdout, .info, "Goodbye.");
}
