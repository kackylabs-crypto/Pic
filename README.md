# Pic

[![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
![Zig 0.16](https://img.shields.io/badge/zig-0.16.0-orange.svg)

**A tiny, local AI agent for your terminal, written in Zig.**

Pic reads what you type, works out what you mean using a small on-device model, and does
it: open a website or app, search, play music, check a stock price, summarise a web page,
write a code file, or just chat. The brain is
[`mistralai/ministral-3-3b`](https://lmstudio.ai/models/mistralai/ministral-3-3b) running
in [LM Studio](https://lmstudio.ai), so your conversations stay on your machine.

```
╭──────────────────────────────────────────────────────────────────────╮
│ ◉ Pic     your local AI agent                                        │
│ mistralai/ministral-3-3b  ·  linux  ·  speech on                     │
│ /help   commands   ·   exit to quit                                  │
╰──────────────────────────────────────────────────────────────────────╯

 you ❯ open youtube
 ↳ open_url → youtube.com
╭─ Pic ────────────────────────────────────────────────────────────────
│ Opening youtube.com.
╰──────────────────────────────────────────────────────────────────────

 you ❯ explain how vaccines work
╭─ Pic ────────────────────────────────────────────────────────────────
│ Vaccines show your immune system a harmless piece or copy of a germ
│ so it can learn to recognise the real thing. If you're ever exposed,
│ your body already has the antibodies and memory cells to respond
│ quickly, usually before you feel sick.
╰──────────────────────────────────────────────────────────────────────
```

*Illustrative output; real colours appear in your terminal.*

## Features

- **Fully local.** One 3B-parameter model, no API keys, no cloud. Only the web tools you
  ask for touch the network.
- **Lightweight.** Two source files, the Zig standard library only, no dependencies. A
  release build is under 1 MB.
- **Cross-platform by design.** Linux, macOS and Windows code paths for opening links,
  launching apps, reading the clock and speaking replies.
- **Reliable routing on a small model.** Uses LM Studio's structured output, so the model
  can only answer with a valid tool name.
- **Safe by default.** Only `http`/`https` links open, only allow-listed apps launch, and
  nothing the model writes is ever passed to a shell.
- **A proper terminal UI.** Boxed banner, wrapped reply panels, colour, a thinking
  indicator, and a dim trace of which tool Pic chose.

## What Pic can do

| Say something like | Tool | What happens |
|---|---|---|
| `open youtube` | `open_url` | Opens the site in your default browser |
| `launch vscode` | `open_app` | Starts an allow-listed app |
| `search wikipedia for robert hooke` | `search_*` | Opens a search on the web, YouTube, Wikipedia, GitHub, Amazon or Wallhaven |
| `play back in black` | `play_music` | Opens a YouTube Music search |
| `what time is it` | `get_time` | Reads the system clock |
| `nvidia stock price` | `get_stock_price` | Fetches a live quote |
| `summarise https://example.com` | `fetch_url` | Downloads the page and summarises it |
| `explain how vaccines work` | `chat` | Answers with the local model |
| `/code a python script that renames files` | n/a | Writes a code file into the current folder |

## Requirements

- [Zig](https://ziglang.org/download/) **0.16.0**. Pic is written against the new
  `std.Io` APIs, so other versions may need small edits.
- [LM Studio](https://lmstudio.ai) with `mistralai/ministral-3-3b` downloaded.
- A UTF-8 terminal with ANSI colour support (nearly every modern one).

## Quick start

1. **Get the model.** In LM Studio, search for `mistralai/ministral-3-3b`, then download
   and load it.
2. **Start the server.** In LM Studio's *Developer* tab, start the local server. The
   default address is `http://localhost:1234`.
3. **Build and run Pic.**

   ```sh
   git clone <your-repo-url> pic
   cd pic
   zig build -Doptimize=ReleaseSmall
   ./zig-out/bin/pic
   ```

   You can also use `zig build run` for a quick debug build. On NixOS, run
   `nix-shell -p zig` first.

4. Type `/health` to confirm Pic can reach LM Studio and see the model, then `/help` for
   the command list.

Pic saves `/code` output and two small scratch files in the folder you start it from, so
run it from a folder you don't mind them appearing in rather than from the repo itself.

If your LM Studio server is on another port, change `LM_BASE` at the top of `src/main.zig`
and rebuild.

## Commands

| Command | Description |
|---|---|
| `<text>` | Talk to Pic, or tell it what to do |
| `/code <description>` | Generate a code file in the current folder |
| `/apps` | List the apps Pic may launch |
| `/mute`, `/unmute` | Spoken replies off / on |
| `/color` | Turn colours on / off |
| `/clear` | Clear the screen |
| `/forget` | Wipe this session's chat memory |
| `/health` | Check LM Studio and the model |
| `exit`, `quit` | Leave |

## Platform support

| Platform | Status |
|---|---|
| Linux | Developed on NixOS |
| macOS | Code paths written (`open`, `say`); not yet tested |
| Windows 10+ | Code paths written (`rundll32`, PowerShell speech); not yet tested |

Bug reports and fixes for macOS and Windows are especially welcome.

**Spoken replies** use whatever the OS ships: `say` on macOS, the built-in speech engine
on Windows, and `espeak-ng` or `espeak` on Linux (install one to hear Pic). If no engine
is found, Pic stays silent.

## Project layout

```
pic/
├── build.zig
├── LICENSE
├── README.md
├── src/
│   ├── main.zig    # agent: routing, tools, LM Studio client, commands
│   └── tui.zig     # terminal UI: colours, boxes, wrapped reply panels
└── docs/
    └── DOCUMENTATION.md
```

See [`docs/DOCUMENTATION.md`](docs/DOCUMENTATION.md) for how Pic works, configuration,
how to add your own tools and apps, the security model and troubleshooting.

## Limitations

- Replies appear all at once rather than streaming token by token.
- Chat memory lasts only for the session; nothing is saved to disk.
- Settings such as the port and the app list are compile-time constants, so changing them
  means rebuilding.
- Input is line-based, with no arrow-key history yet.

## Contributing

Issues and pull requests are welcome. Please keep Pic small and dependency-free: if a
feature needs a library, it probably belongs in a fork. Unless you say otherwise, any
contribution you submit is licensed under the Apache License 2.0, as described in
section 5 of the license.

## License

Pic is licensed under the [Apache License, Version 2.0](LICENSE). You may use, modify and
distribute it, including commercially, as long as you keep the license and copyright
notices and state significant changes. The license also includes an express patent grant
and comes with no warranty. The full text is in the [`LICENSE`](LICENSE) file.
