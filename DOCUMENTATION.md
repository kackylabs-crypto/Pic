# Pic documentation

This document explains how Pic works, how to configure and extend it, and what to check
when something goes wrong. For a quick overview, see the [README](../README.md).

## Contents

1. [How it works](#how-it-works)
2. [Tools](#tools)
3. [Commands](#commands)
4. [Configuration](#configuration)
5. [Extending Pic](#extending-pic)
6. [Security model](#security-model)
7. [The terminal UI](#the-terminal-ui)
8. [Source tour](#source-tour)
9. [Troubleshooting](#troubleshooting)
10. [Known limitations](#known-limitations)

## How it works

Every line you type goes through two model calls and one tool run:

```
 you type ──► router (model call #1) ──► tool ──► reply panel
                   │                      │
        picks a tool + target      may call the model again
                                   (chat, summarise, /code)
```

1. **Route.** Pic sends your message to the model together with a short system prompt
   listing every tool. The model must answer with a JSON object
   `{"tool": "...", "target": "..."}`. Pic asks LM Studio to enforce this with a JSON
   schema (`response_format`), so a small 3B model cannot invent a tool name. If the
   server rejects the schema (HTTP 400), Pic retries without it. If the reply is still
   not valid, Pic falls back to plain chat with your original message.
2. **Run.** Pic executes the chosen tool. Most tools are local actions (open a URL,
   launch an app). `chat`, `fetch_url` and `/code` make a second model call.
3. **Show.** The result is drawn as a reply panel. For non-chat tools a dim line above it
   shows what the router chose, for example `↳ open_url → youtube.com`.

The router is called at low temperature (0.1) for consistency; chat uses 0.6.

Only one model is ever used: `mistralai/ministral-3-3b`, set by the `MODEL` constant.

### Memory

Pic keeps the last six chat turns in memory and sends them with each `chat` request so
follow-up questions work. The router does not see history. `/forget` wipes it, and it is
never written to disk.

### Memory management

Each turn allocates from a per-turn arena that is freed in one step, so tools never need
individual `free` calls. Only the chat history lives in the long-lived allocator.

## Tools

| Tool | `target` | Behaviour |
|---|---|---|
| `chat` | the user's message | Answers with the local model, with session memory |
| `say` | a one-sentence reply | Greetings, thanks, questions about Pic itself |
| `open_url` | domain or URL | Opens an `http`/`https` link in the default browser |
| `open_app` | an allow-listed app name | Launches the app |
| `get_time` | none | Reads the system clock |
| `search_web` | query | DuckDuckGo |
| `search_youtube` | query | YouTube results |
| `search_wikipedia` | query | Wikipedia search |
| `search_github` | query | GitHub repository search |
| `search_amazon` | query | Amazon product search |
| `search_wallpapers` | query | Wallhaven |
| `play_music` | song or artist | YouTube Music search (it opens the search; press play) |
| `fetch_url` | URL | Downloads the page, strips the HTML, summarises it with the model |
| `get_stock_price` | ticker | Quote from Yahoo Finance's chart endpoint |
| `do_nothing` | none | Used when the request is outside Pic's abilities |

Search-style tools are table-driven (the `SITES` array), so adding a site is one line plus
the two prompt/schema entries described below.

### Default apps

Pic only launches apps from the `APPS` table, using the right command for your OS:

| Name | Linux | macOS | Windows |
|---|---|---|---|
| `browser` | `firefox` | `Safari` | `msedge` |
| `terminal` | `x-terminal-emulator` | `Terminal` | `cmd` |
| `editor` | `gedit` | `TextEdit` | `notepad` |
| `calculator` | `gnome-calculator` | `Calculator` | `calc` |
| `vscode` | `code` | `Visual Studio Code` | `code` |
| `spotify` | `spotify` | `Spotify` | `spotify` |
| `vlc` | `vlc` | `VLC` | `vlc` |

## Commands

| Command | Description |
|---|---|
| `/help` | Show commands and example phrases |
| `/code <description>` | Ask the model to write a complete file and save it |
| `/apps` | List the apps Pic may launch |
| `/mute`, `/unmute` | Turn spoken replies off / on |
| `/color` | Toggle ANSI colours (use this if your terminal shows escape codes) |
| `/clear` | Clear the screen and redraw the banner |
| `/forget` | Clear chat memory |
| `/health` | Check that LM Studio is reachable and the model is loaded |
| `exit`, `quit` | Leave Pic |

### `/code`

`/code a python script that renames files` asks the model for code only (no commentary),
strips any markdown fences, and saves it in the **current directory**. The file name is
built from your request (`a_python_script_that_renames_files.py`). The extension comes
from a language word in your request (python, rust, javascript, typescript, html, bash,
c++, java, golang, zig) and falls back to `.html` or `.py` if the code looks like it, else
`.txt`. Pic never overwrites an existing file: it adds `_2`, `_3`, and so on.

## Configuration

Pic has no config file. Settings are constants near the top of `src/main.zig`; change
them and rebuild.

| Constant | Default | Meaning |
|---|---|---|
| `LM_BASE` | `http://localhost:1234` | Where LM Studio's server listens |
| `MODEL` | `mistralai/ministral-3-3b` | The model id sent to LM Studio |
| `MAX_HISTORY` | `6` | Chat turns kept in memory |
| `BROWSER_UA` | a Mozilla-style string | User-Agent for web requests |
| `APPS` | see above | Launchable apps |
| `SITES` | see above | Search sites |

In `src/tui.zig`, `WIDTH` (default 72) sets the width of every box and panel.

## Extending Pic

### Add an app

Add a row to `APPS` in `src/main.zig` with the name you will say and the command for each
OS. Rebuild. The router prompt picks the new name up automatically.

### Add a search site

1. Add an entry to `SITES` (`.tool`, `.label`, `.template` with `{}` where the
   URL-encoded query goes).
2. Add the tool name to the `TOOLS` array.
3. Add it to the `enum` list inside `RESPONSE_FORMAT`.
4. Mention it in `ROUTER_TAIL` so the model knows it exists.

### Add a new kind of tool

Follow steps 2 to 4 above, then add a branch in `runTool` that returns the reply text.
Keep the `TOOLS` array and the `RESPONSE_FORMAT` enum in sync: if they drift apart, the
model may choose a tool that `route` then rejects and falls back to chat.

Tips for a 3B model: keep tool descriptions to one line, give each a concrete example in
`ROUTER_TAIL`, and prefer a few clear tools over many overlapping ones.

## Security model

Pic lets a language model choose actions, so it is deliberately restrictive.

- **No shell with model text.** Commands are spawned with an argument list, never through
  `sh -c` or `cmd /c` with model-written strings. The two shell uses (reading the clock,
  setting the Windows code page) run fixed, constant commands.
- **URLs are validated.** Only `http` and `https` are accepted. Pic rejects whitespace,
  quotes, `<`, `>`, `^`, `|`, backticks, backslashes and control characters, and requires
  a dotted host. On Windows, links open through `rundll32 url.dll,FileProtocolHandler`
  rather than `cmd /c start`, because `start` would interpret `&` and `|`.
- **Apps are allow-listed.** `open_app` matches the requested name against the compiled-in
  `APPS` table; anything else is refused.
- **Search queries are percent-encoded** before they go into a URL.
- **Fetched pages are treated as text only.** `fetch_url` summarises content but never
  runs tools based on what a page says, so a malicious page cannot trigger actions.
  The summary itself comes from a language model, so treat it as a summary, not a source.
- **Network use.** Pic talks to LM Studio on your machine. It contacts the internet only
  for `fetch_url` and `get_stock_price`, plus whatever your browser opens.

Scratch files `.pic-tmp.txt` and `.pic-say.txt` are written to the current directory (the
clock reading and text for the speech engine). They are listed in `.gitignore`.

## The terminal UI

The interface lives in `src/tui.zig` and is built from ANSI escape codes and UTF-8 box
drawing characters only. There is no raw terminal mode, so it works identically on Linux,
macOS and Windows without platform-specific input code.

- **Banner** with the model, OS and speech state.
- **Reply panels** with a left rule and word wrapping at 68 columns. Lines that already fit
  are left untouched, so indented code is not reflowed.
- **Thinking indicator.** The model call blocks, so Pic shows one static `⠋ thinking…`
  line and erases it when the answer arrives.
- **Tool trace.** A dim `↳ tool → target` line shows what the router decided.
- **Status lines** with `✓`, `!`, `✗` and `•` for confirmations, warnings and errors.
- **Windows.** At startup Pic runs `cmd /c "chcp 65001 >nul"`, which switches the console
  to UTF-8 and turns on ANSI processing. Windows Terminal needs neither, but older
  consoles do.

Not yet supported: reading terminal size (the width is fixed), arrow-key line editing,
and live token streaming. These need raw-mode input or a streaming HTTP client and are
natural next steps.

## Source tour

### `src/main.zig`

| Area | Key items |
|---|---|
| Prompts and tables | `PERSONA`, `ROUTER_HEAD`, `ROUTER_TAIL`, `RESPONSE_FORMAT`, `TOOLS`, `SITES`, `APPS`, `LANGUAGES` |
| HTTP and LM Studio | `http`, `complete` (builds the chat request, retries without schema on HTTP 400) |
| Agent | `route`, `chatReply`, `runTool`, `think`, `handle`, `remember`, `forget` |
| Web tools | `stripHtml`, `summarise`, `stockPrice` |
| OS integration | `spawnOk`, `openUrl`, `launchApp`, `getTime`, `speak` (each switches on `builtin.os.tag`) |
| Code files | `stripFences`, `detectExt`, `saveCode`, `writeCode` |
| Commands and loop | `command`, `health`, `banner`, `main` |

### `src/tui.zig`

`init`, `banner`, `help`, `reply`, `trace`, `status`, `prompt`, `thinking`, `clearLine`,
`clear`, plus the box helpers `boxOpen`, `boxRow`, `boxClose`.

## Troubleshooting

**`error: failed to check cache: '...' file_hash FileNotFound`**
`build.zig` cannot find the source file. It expects `src/main.zig` relative to the
project root. Check your folder layout.

**"I can't reach LM Studio at http://localhost:1234"**
Start the local server in LM Studio's Developer tab and confirm the port. Run `/health`.
If the port differs, change `LM_BASE`.

**`/health` says the model is "NOT found"**
Download `mistralai/ministral-3-3b` in LM Studio and load it. The id must match `MODEL`.

**LM Studio returns HTTP 400 or similar**
Pic prints the server's message to stderr. Common causes are no model loaded or a context
length too small for the prompt; raise it when loading the model.

**Pic picks the wrong tool**
Add a clearer example to `ROUTER_TAIL` for that phrasing. A 3B model leans heavily on
examples.

**Strange `[1;36m` characters, or broken boxes**
Your terminal is not interpreting ANSI or UTF-8. Type `/color` to switch colours off, and
use a terminal set to UTF-8 (Windows Terminal, iTerm2, GNOME Terminal and similar).

**No voice**
Install `espeak-ng` on Linux. macOS (`say`) and Windows (PowerShell speech) ship with an
engine. Use `/unmute` if you muted earlier.

**The browser does not open**
On Linux Pic needs `xdg-open`; install `xdg-utils`. On headless systems there is nothing
to open a link with.

**Stock price or page fetch fails**
These need internet access. Yahoo may rate-limit; try again later.

## Known limitations

- Replies are not streamed; you see the answer when the model finishes.
- No persistence: no saved history and no config file.
- The model is fixed to Ministral 3 3B; changing it means editing `MODEL` and rebuilding.
- A 3B model sometimes misroutes unusual phrasing, and its summaries and code can contain
  mistakes. Review generated code before running it.
- Pic was developed on Linux. The macOS and Windows paths are written but untested.
- Written against Zig 0.16.0. Zig's standard library is still changing, so other versions
  may need small edits.
