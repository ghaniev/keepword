# Keepword

An open-source meeting notes app for macOS 15+ on Apple Silicon: records calls without a bot, transcribes and identifies speakers on-device, writes summaries, and lets you search and chat across meetings.

## Build and run
```bash
./build_app.sh && open Keepword.app
```
The app icon comes from `Resources/assets/meetnote_icn.webp`: `build_app.sh` turns it into `AppIcon.icns` (16–1024 px) on every build.

Extra launch modes:
- `Keepword.app/Contents/MacOS/MeetNotes --selftest` runs the logic and DB self-checks.
- `… --demo` opens a throwaway library with sample meetings.
- `… --demo --snapshot <dir>` renders every screen into PNGs.
- `… --demo --screenshots <dir>` renders the README screenshots (light and dark, 2x, framed). `./screenshots.sh` runs it and writes WebP files to `../docs/screenshots` (needs `brew install webp`).

macOS asks for access on first use: Microphone and System Audio Recording when you record, Calendar and Reminders when you use them. The first transcription downloads the models into `~/Library/Application Support/FluidAudio`: Parakeet TDT v3 (~0.6 GB) and the diarization models (~30 MB).

Settings → Transcription → Engine → On this Mac lists the on-device speech models, each with Download / Delete, progress and cancel: Parakeet TDT v3 (default, ~480 MB, 25 languages incl. Russian), Parakeet Ultra (~650 MB, retrained v3, more accurate), Parakeet Redux (~220 MB, 2-bit v3), Parakeet TDT v2 (~480 MB, English) through FluidAudio, and Whisper Tiny / Base / Small / Medium / Large v3 Turbo / Large v3 (77 MB – 1.5 GB, 99 languages) through [WhisperKit](https://github.com/argmaxinc/WhisperKit) on Core ML. Parakeet models are kept in FluidAudio's folder, Whisper models in `~/Library/Application Support/MeetNotes/Models/Whisper`; a Whisper model is compiled for the Neural Engine and its tokenizer fetched right after download, so later runs work offline. Whisper takes the spoken language from the same setting as the cloud engines and is fed 5-minute parts cut at pauses. Every engine returns timed words, and speakers are found from them by the same on-device diarization (pyannote segmentation, WeSpeaker voices, VBx clustering); the live preview always uses Parakeet (the chosen one, or v3).

The engine can also send recordings to a cloud service instead: OpenAI (`whisper-1`, `gpt-4o-transcribe`), Groq, Deepgram or any OpenAI-compatible `/audio/transcriptions` server (base URL and model are editable, the key is kept in the Keychain). Tracks are cut at pauses into parts under the upload limit (≤ 10 min, AAC ~4 KB/s, well under OpenAI's 25 MB), word times are shifted back to the recording, and silent parts are never sent. Speaker identification and the live preview stay on this Mac; if the cloud fails, the recording is transcribed locally unless that fallback is turned off.

## Project structure
```
Sources/MeetNotes/
  App/            entry point, scenes, AppModel (app state + coordination), RootView, menu bar
  Core/           logic without UI
    Database/     GRDB models, Store (queries + migrations)
    Audio/        Recorder, TrackWriter, Core Audio tap and devices, call detection, playback
    Transcription/ engines (Parakeet and Whisper on this Mac, cloud Whisper/Deepgram), model downloads, live transcription
    Processing/   Pipeline: transcription → speakers → summary → index; search and chat
    AI/           LLM providers (HTTP, CLI, llama.cpp), embeddings, prompts, templates, live queries
    Calendar/     EventKit + iCal feeds, ICS parser
    MCP/          MCP server (for Claude), MCP client with OAuth sign-in, service presets, task mapping
    Capture/      screenshots
    Export/       Markdown / Obsidian
    Utilities/    Keychain, formatting, UserDefaults
  Features/       SwiftUI screens, one folder per feature
    Home, Documents, Chat, Calendar, ActionItems, People, Tags, Search,
    Recording (overlay, prompts, controls), Integrations, Onboarding, Settings, Sidebar
  DesignSystem/   shared components (chips, avatars, tabs, empty states, FlowLayout)
  Dev/            --selftest, test flags (DevCommands), demo library and snapshots
Resources/ru.lproj/  translations
```
Rules:
- `Core` doesn't know about screens.
- Features talk to `Core` through `AppModel` and `Store`.
- Shared UI goes into `DesignSystem`.
- A new screen goes into `Features/<Name>/`.

## AI provider
Settings → AI Provider (or **Set Up AI…** in the File menu). There are four kinds:
- **Local AI, built in (recommended for privacy).** Qwen runs inside Keepword with llama.cpp (b11457, Metal), with no Ollama and no key, and works offline.
  - Pick a model and click "Download and use Local AI". Models are stored in `~/Library/Application Support/MeetNotes/Models/LLM`.
  - The model "Best for your Mac" is chosen by memory: Qwen3.5 4B (2.7 GB) for 8–16 GB, Qwen3.5 9B (5.7 GB) for 24 GB+, Qwen3.6 27B (17.5 GB) for 48 GB+.
  - Thinking mode is switched off for direct answers.
  - The model unloads after 5 idle minutes.
  - A memory guard blocks models that don't fit.
  - The context window limits transcript length (4B: about 40k characters, ≈45 min).
- **Your subscription through a CLI, no API key.**
  - **ChatGPT subscription (Codex CLI):** runs `codex exec`; default model `gpt-5.6-terra`. Sign in once with `codex login`.
  - **Claude subscription (Claude Code CLI):** runs `claude -p` with no tools; default model `sonnet`. Sign in once by running `claude` and typing `/login`.
- **API keys:** OpenAI, Anthropic, Gemini, OpenRouter, DeepSeek.
- **Local:** Ollama or LM Studio. Nothing leaves the Mac.
  ```bash
  OLLAMA_CONTEXT_LENGTH=32768 ollama serve
  ```
  ```bash
  ollama pull qwen3:8b && ollama pull bge-m3
  ```

Semantic search, Similar Documents and chat across meetings use a built-in embedding model: `paraphrase-multilingual-MiniLM-L12-v2`. It runs on-device through Core ML (swift-embeddings), covers 50+ languages (a Russian question finds an English passage) and needs no server or key. It downloads once (~470 MB) into `~/Library/Application Support/MeetNotes/Models`. Transcripts are split into ~30-word chunks and embedded without speaker names. Switching the model or the chunking reindexes everything automatically. Settings → AI Provider → Embeddings can switch to an embedding server (Ollama / OpenAI) or turn embeddings off.

Deep links: `meetnotes://record?title=…`, `stop`, `pause`, `bookmark`, `screenshot`, `open?id=…`, `transcribe?id=…`, `summarize?id=…`, `download-model?id=…`.

Dev checks:
- `MeetNotes --embed-test` runs the model on reference pairs.
- `MeetNotes --search "query" --raw` runs hybrid search on your library and shows raw similarities.
- `-libraryPath <dir>` opens a separate library.
- `-debugMaxInputChars 1500` forces map-reduce on a short meeting.
- `meetnotes://simulate-device-change` simulates a device switch during a recording.
- `--calendar-diag <file>` writes calendar access status and counts (launch with `open -a Keepword.app --args …`).
- `--ics-test <url>` parses an iCal feed and prints a summary.
- `--transcribe-test [file] -transcriptionEngine openai|groq|deepgram|custom` checks the configured transcription engine (URL, key, model) or transcribes a file with it and prints the timed words. With `-transcriptionEngine local -localSpeechModel whisper-small` (any id from `SpeechModels.catalog`) it downloads that model first if needed.
- `--process <id> -libraryPath <dir> -autoSummarize NO -aiCleanup NO [-expectedSpeakers N]` re-runs transcription and diarization of a meeting without the UI and prints who spoke how much. Use it on a copy of the library; audio put in `recordings/<id>/` is enough, the meeting is created if missing.

`Keepword.app/Contents/MacOS/MeetNotes --llm-test` sends one request to the current provider and prints the result.
`--summary-test <meeting id>` prints the summary the current provider would write, without saving it.
Add `-llmBaseURL local:llama -llmModel qwen3.5-4b` to either flag to try the local model without changing Settings.

## Features
| Area | Implementation |
|---|---|
| Layout | Sidebar: Record pill + Import, Home/Chat(Beta)/Calendar/Action Items/People/Tags, FOLDERS tree with counts, Recently Deleted. Card list grouped by day. Document view with `Folder / Title`, meta row, Summary · Transcript · Chat tabs. Centered search bar |
| Recording | Mic (selectable device) + system audio via a Core Audio process tap, no bot. Modes: both / mic / system. Pause, mute, bookmarks (⌘B), level meters, menu bar icon |
| Live transcript | Sliding-window Parakeet per source while recording, shown as chat bubbles |
| Call detection | Core Audio list of processes holding the mic + known meeting apps → floating "Record this meeting?"; "Call ended?" prompt; ignore list |
| Calendar | Week / work-week grid (24 h, opens at working hours) with an all-day row, overlapping meetings side by side, a now-line, a popover per event and a marker on recorded meetings. Events reload when the calendar changes. There are clear states for "no access" (link to Privacy settings) and "no events" (how to add a work calendar). Sources: macOS calendars (EventKit / Internet Accounts) and imported Google calendars |
| Google Calendar | Two ways (Calendar page → "Google Calendar", or Settings → Calendar). (1) Add the Google account in System Settings → Internet Accounts: all calendars with attendees, synced by macOS. (2) Paste Google's "Secret address in iCal format": Keepword downloads and parses it itself every 15 minutes. Parsing handles recurring events (RRULE incl. "2nd Tuesday", COUNT/UNTIL), EXDATE, moved instances, time zones and all-day events. The address is kept in the Keychain |
| Transcription | On-device Parakeet (v3, Ultra, Redux, v2) or Whisper (WhisperKit, tiny … large-v3) with a model manager, or a cloud engine (OpenAI, Groq, Deepgram, OpenAI-compatible) after the call, words → turns, echo dedup (mic vs system), import of audio/video files (drag & drop) |
| Speakers | Offline diarization (pyannote + WeSpeaker + VBx). Voices are matched to known people best-first, at most one speaker per person per meeting, against up to 5 voice samples each (new samples only from confident matches). Words go to the speaker covering most of them; blocks where people talk at the same time are marked. The calendar attendee count caps the number of voices; "Re-identify Speakers…" sets it exactly. Rename once and it sticks; merge people (parent link) |
| AI Cleanup | LLM rewrite in batches of 25 with an editable prompt; original kept, "Restore Original Text" |
| Summary | Attention templates (9 built-in + your own). Priority: document → folder → default. Folder context goes into the prompt. Output: overview, Key Insights with time chips, Action Items (assignee, due date), tags, title |
| Transcript tools | Synced mic+system player with bookmark markers and speed, speaker filter, search, edit, split, assign / rename person, re-transcribe |
| Chat | Global and per-document sessions; citations `[n]` jump to the moment; `@Name`, `@tag`, `@'Title'` mentions; time ranges ("first 10 minutes", "в конце") |
| Search | Hybrid FTS5 bm25 + embeddings, % score, highlighted snippets, "Ask AI" on results |
| Similar Documents | Embedding similarity + shared tags/people boost |
| People, Tags, Action Items | Person card (email, company, position, notes, meetings), tag cloud, all action items grouped by due date, send to Reminders |
| Home | Upcoming meetings with a **Brief** for each one that has history: earlier meetings of the same series, title or attendees, their open action items, and an AI brief on request (what was decided, who owes what, what to raise). **Needs Attention**: recent meetings with unidentified speakers, failed processing or no summary, and action items overdue or due within three days |
| Plain-text action items | "Send the deck tomorrow @Anna" in a document's action items gets a due date and an assignee (matched to the meeting's people). English and Russian: today / tomorrow / the day after, weekdays ("on friday", "до пятницы"), "in 3 days" / "через 3 дня", "next week", "15.11", "Nov 15" / "15 ноября" |
| Menu bar | Start / stop / pause, bookmark, an in-person meeting (microphone only), upcoming meetings, the latest meeting and a new chat |
| Export | Auto-export Markdown with YAML frontmatter to an Obsidian vault, manual export, copy, email |
| Trash | Recently Deleted for 30 days, restore |
| Long meetings | Map-reduce, as in Meetily. Past the model's input limit the transcript is split between utterances into overlapping parts. Each part is condensed into notes that keep `[mm:ss]` times (one retry on failure). Then the notes are summarized; if a level doesn't shrink the text, every part is trimmed evenly. Chat on a long meeting uses retrieval instead of truncation |
| Device changes mid-call | AirPods or another mic or output connected or removed: the mic engine and the system tap rebuild themselves (retrying for ~10 s for Bluetooth) and keep writing to the same files. The switch-over time is filled with silence so both tracks stay aligned; a toast says what happened |
| Crash safety | CAF files stay readable after `kill -9` (tested). A recording interrupted by a crash is marked "recovered" and processed automatically on the next launch. A crash during processing needs a manual retry, so a crashing step can't loop |
| Meeting overlay | Floating panel while recording: timer, pause, mute, bookmark, screenshot, stop; tabs Notes · Transcript (live) · Prep (earlier meetings with the same people + their open action items) |
| Screenshots | Whole screen under the mouse or a dragged area (⌘⇧S / ⌘⇧A or the overlay). Keepword' own windows are left out. Saved as attachments with the recording time and shown inline in the transcript |
| Attachments | Drop or attach files on a document; preview, open, show in Finder. Exported to `Attachments/` next to the Obsidian note |
| Speaker wizard | For every new "Speaker N": three longest excerpts to listen to, then a new name or "same person as …" (merge, so the voice is recognized next time). Optional: hold the summary until new speakers are named |
| Local MCP server | Settings → MCP Server. Streamable HTTP on `127.0.0.1` only, bearer token in Keychain, Origin check. Tools: `search_meetings`, `list_meetings`, `get_transcript`, `get_summary`, `get_action_items`. One-click copy of the Claude Code command and the Claude Desktop config |
| Live queries | A saved prompt over a rolling period (today / 7 / 14 / 30 / 90 days) and scope (all, folder, tag, person), run by hand, daily or weekly. Answers go to their own chat with citations. "Save as Live Query" from chat and from search |

Data lives in `~/Library/Application Support/MeetNotes/` (`meetnotes.sqlite`, `recordings/<id>/`).

## Connecting Claude to your meetings (MCP)
Turn on Settings → MCP Server, then click "Copy command" and run it in a terminal. It looks like this, with your token:
```bash
claude mcp add --transport http meetnotes http://127.0.0.1:8765/mcp --header "Authorization: Bearer <token>"
```
For Claude Desktop, use "Copy configuration" and paste it into `claude_desktop_config.json` (it uses the `mcp-remote` bridge).

## Creating tasks in Jira, Linear, Notion and other services
Settings → Integrations → **Add** has ready-made setups for the official hosted MCP servers:

| Service | Server | Sign-in | Task tool |
|---|---|---|---|
| Jira | `https://mcp.atlassian.com/v2/mcp?tools=all` | Browser, dynamic registration | `createJiraIssue`; site, project and work type are picked from `getAccessibleAtlassianResources`, `listJiraProjects`, `listJiraProjectIssueTypesMetadata` |
| Linear | `https://mcp.linear.app/mcp` | Browser, or an API key as `Authorization: Bearer` | chosen from the server's tools; team, project and assignee from `list_*` |
| Notion | `https://mcp.notion.com/mcp` | Browser | `notion-create-pages`: one page per item under a page you choose |
| Asana | `https://mcp.asana.com/v2/mcp` | Browser with an OAuth app you create (Asana has no dynamic registration); redirect URL `http://localhost:47821/callback` | chosen from the server's tools |
| Miro | `https://mcp.miro.com/` | Browser | chosen from the server's tools |

Sign-in follows the MCP authorization spec: protected-resource and authorization-server discovery, dynamic client registration, PKCE, the `resource` parameter and a loopback redirect. Tokens and client secrets are kept in the Keychain and refreshed before they expire. `--selftest` runs the whole flow against a mock server.

**Other MCP Server…** and **Import JSON…** (Claude Desktop format) add any other server: Keepword runs it itself (stdio) or connects over HTTP with a browser sign-in or with headers. Environment variables and headers are stored in the Keychain.

Where to create tasks:
- **Create Tasks…** next to Action Items: every open item at once.
- An action item's context menu: **Create Task in …**
- **Create Task…** next to Notes: a task from the meeting notes.

The form is built from the tool's schema:
- title, description and due date come from the item, and the description links back to the meeting (`meetnotes://open?id=…`);
- the other fields (project, board, type, owner) can be picked from the server's listing tools and are remembered for next time.

A created task gets a "Task" link on its action item.

Check a stdio server from the command line: `MeetNotes --mcp-test <command> <args…>` lists its tools and tries one call.

## Language
English and Russian. Keepword follows the macOS language by default. To change it, use Settings → General → Language (System / English / Русский) and restart. To try it once without changing anything: `Keepword.app/Contents/MacOS/MeetNotes -AppleLanguages "(ru)"`.

Translations live in `Resources/ru.lproj/`:
- `Localizable.strings`: keys are the English UI strings.
- `Localizable.stringsdict`: Russian plurals (встреча / встречи / встреч).
- `InfoPlist.strings`: permission prompts.

To find new strings, build with `-Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc <dir>`. The compiler writes the keys for every `Text`/`Button`/`String(localized:)`; compare them with `Localizable.strings`.

## Not done yet
- MLX engine (llama.cpp covers local AI).
- Screen video recording during a call.
- iCloud sync with E2E encryption.
- Paid plans and licensing (not needed for personal use).
