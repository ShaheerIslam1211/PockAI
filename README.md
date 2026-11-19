# PockAI

One Touch Bar app = **Pock** (all widgets, upgraded) + **Purrbar** (synced lyrics & full player) + **PocketAI** (AI Writing Tools), plus subtitles for videos.

## Download & install (users)

| Your system | Download (GitHub → **Releases**) | What you get |
|---|---|---|
| **macOS 12 Monterey or newer**, Touch Bar MacBook Pro (2016–2022) | `PockAI.dmg` | The full app: every widget, lyrics, AI, subtitles, games |
| **Linux**: Fedora, Ubuntu, Linux Mint, Debian, Arch… on a Touch Bar Mac | `.rpm` / `.deb` / `.tar.gz` | Touch Bar layouts (media, clock, battery, F-keys). See [Linux/README.md](Linux/README.md) |
| **Windows 10/11 via Boot Camp** | — | Not possible; Apple's Boot Camp driver handles the Touch Bar. See [Windows/README.md](Windows/README.md) |

**macOS steps**

1. Open `PockAI.dmg` and drag **PockAI** to **Applications**.
2. The first time, right-click PockAI → **Open** → **Open**. It isn't notarised, so macOS asks once.
   On macOS 15 and newer, if there's no Open button, go to System Settings → Privacy & Security → **Open Anyway**.
3. Allow **Accessibility** when asked (System Settings → Privacy & Security → Accessibility → PockAI).
   This is needed for the ✨ AI button and the Dock.
4. Optional: paste a free Gemini API key in PockAI Settings → Writing Tools, and install the browser extension for
   Netflix and YouTube subtitles (menu bar icon → Subtitles → Install Browser Extension…).

All widgets are inside the app. It starts at login and restarts itself if it ever crashes.
To remove it: menu bar icon → Quit, then delete PockAI from Applications.

## Build from source (developers)

Needs a Mac with Xcode 15+ and [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
git clone <this repo> && cd PockAI
./build.sh            # debug build → ~/Applications/PockAI.app → launch
./build.sh release    # optimised build (use this day to day)
./build.sh --no-open  # build + install only
./build.sh dist       # build/PockAI.dmg, the installer you upload to Releases
Linux/build-packages.sh   # build/linux/*.deb, *.rpm, *.tar.gz (needs Docker)
```

`project.yml` is the source of truth; `PockAI.xcodeproj` is generated from it.
`build.sh` signs with **your** Apple Development certificate if you have one (it detects your team, so
Accessibility permission survives rebuilds), otherwise ad-hoc.

**What goes on GitHub:** the source only. `build/` (about 1 GB of Xcode intermediates) and installers (`*.dmg`,
`*.deb`, `*.rpm`) are in `.gitignore`. You don't need to delete them, git just skips them.
Upload the installers to a **GitHub Release** instead:

```bash
gh release create v1.0.0 build/PockAI.dmg build/linux/* --title "PockAI 1.0.0" --notes "See README"
```

**Runs on macOS 12 Monterey and newer.**
Features that need a newer macOS switch themselves off on older versions:
- lyric translation: macOS 15+
- reading subtitles from the screen: macOS 14+
- live equaliser: macOS 14.2+ (older Macs get the animated one)

## What's on the Touch Bar

| Widget | What it does | Gestures |
|---|---|---|
| ✨ **AI Writing Tools** | Appears when you select text in any app. Tap → Proofread, Rewrite, Friendly, Professional, Concise, Expand, Summary, Key Points, List, Table, To English, Reply, Emojify + your templates, all on the Touch Bar → **Replace / Copy / Retry / Open panel**, Undo after replacing. | Tap: options · Long-press: full panel · ⌃⌥W anywhere |
| ♪ **Lyrics** | Purrbar's synced lyrics with word-by-word highlight, album art, next line. Hides for videos (no artist). | Tap: full Purr player · Long-press: lyrics on/off · Swipe: next/previous |
| CC **Subtitles** | Captions from Netflix, YouTube, Prime Video, Disney+, Max, Hulu, Apple TV+, any HTML5 video (browser extension); `.srt/.vtt` next to local movies (IINA, VLC, QuickTime…); optional on-screen reading for Safari/any app. If the bar is full, captions show full-width automatically. | Tap: full-width · Long-press: hide (small CC button stays) |
| **System Monitor** | CPU, RAM, network. | Tap: switch view · Long-press: Activity Monitor |
| 📋 **Clipboard History** | Last 15 copied texts (memory only, password-manager copies skipped). | Tap: list → tap one to paste · Long-press: clear |
| ⏱ **Timer** | Pomodoro / focus timer with chime. | Tap: start/pause · Swipe: ±5 min · Long-press: reset |
| ⚡ **Quick Actions** | Screenshot, Lock, Display sleep, Dark mode, Focus. | Tap |
| 📅 **Next Event** | Next calendar event today with countdown (turns red 10 min before). | Tap: Calendar |
| 🎮 **Games** | Dino Run, Whack-a-Mole, Perfect Stop, Memory — full-bar, best scores saved. | Tap: pick a game · ✕: back |
| Esc, Dock, Status, Control Center, Now Playing, Weather | The classic Pock widgets, fixed for macOS 15 (Now Playing works again on 15.4+). | as in Pock |

Customise the layout: menu bar icon → Customize → Pock (drag widgets in/out).
While you customise, widgets show as small icons on the Touch Bar, so you can add as many as you like.
Nothing gets pushed out, and the bar scrolls afterwards.
Every widget has a settings page in **menu bar icon → Manage widgets** (with Reset to defaults).
When widgets don't fit, the bar becomes one **scrollable strip** (swipe left/right) instead of macOS hiding widgets.

## Every app keeps its own Touch Bar

Safari, Chrome, Music, Photos, Final Cut, Photoshop, Word, Excel, Keynote, Xcode and other apps have their own Touch Bar controls:

- The **first button on PockAI's bar is the app you're in**. Tap it to show that app's own controls.
- To bring PockAI back, tap the **PockAI icon in the Control Strip** (next to brightness).
  Double-tap Control (⌃⌃) or the menu bar icon → "PockAI ↔ App's own Touch Bar" does the same.
  Tap again to get the app's controls back.
- **Switching apps switches the bar.** PockAI remembers your choice for each app.
  For example: Chrome shows Chrome's buttons, Finder shows PockAI, Music shows Music's controls.
- Apps known for good Touch Bar controls start with their own controls.
  Edit the list, or turn this off, in **PockAI Settings → Touch Bar → Apps' own Touch Bar**.
- PockAI never steps aside while one of its full-bar screens (AI, player, games) is open.

## Stability

- A launchd watchdog (`~/Library/LaunchAgents/com.pockai.app.agent.plist`) starts PockAI at login and relaunches it within seconds if it ever crashes. Quit from the menu is respected. Toggle with Pock Preferences → Launch at login.
- Crash fixes over the original Pock widgets: Dock (stale-index crashes, duplicate repositories/observers, uninitialised Accessibility pointer, Trash duplication), Status (IOKit/CoreWLAN), Control Center (index/unowned/timer), Dock folders (`fatalError`), Preferences (invalid stored values), login items (deprecated API), and repeated bar re-creation leaking widgets.
- Weather uses Open-Meteo (Pock's weather server is gone).
- Crash reports: `~/Library/Logs/DiagnosticReports/PockAI-*.ips`.

## Touch Bar size (13" / 15" / 16")

Full-bar screens (AI options, Purr player, full-width subtitles) size themselves from the Mac model:
13"/15" = 1085 pt, 16" = 1004 pt (no Esc on the bar). Inline widgets measure the free space on the live bar and fit into it.
Override in **PockAI Settings → Touch Bar**.

## Setup (one time)

1. **Accessibility**: System Settings → Privacy & Security → Accessibility → turn on **PockAI** (needed for ✨ to see and replace selected text).
2. **Gemini key**: picked up automatically from the PocketAI app; otherwise PockAI Settings → Writing Tools.
3. **Browser subtitles**: PockAI menu → Subtitles → Install Browser Extension… (Chrome/Edge/Brave/Arc: `chrome://extensions` → Developer mode → Load unpacked).
4. Optional: Screen Recording (subtitles from screen, Dock window previews).

## Under the hood

- `App/` – Pock core (no CocoaPods, no AppCenter analytics, no update checks to pock.app). Built-in widgets load from `Contents/PlugIns`; third-party `.pock` widgets still load from `~/Library/Application Support/PockAI/Widgets`.
- `PockKit/` – widget SDK (vendored, crash-hardened; old API kept so existing widgets load).
- `PockAIKit/` – shared services: one now-playing helper (`/usr/bin/perl` + `libnowplaying.dylib`, as in Purrbar — required on macOS 15.4+), lyrics store with cache, Purr player, Gemini client, selection monitor, subtitle server (`127.0.0.1:38917`, local only), settings.
- `Widgets/` – each widget is its own `.pock` bundle.
- `BrowserExtension/` – Chromium MV3 extension (captions → `127.0.0.1` only).
- `Linux/` – tiny-dfr layouts, `pockai-touchbar` command, installer and `.deb`/`.rpm` packaging.
- `Windows/` – why there's no Windows build and what Boot Camp gives you.

Memory: ~15–25 MB with all widgets (the Dock widget used ~110 MB before icons were rendered at Touch Bar size).
Timers and the now-playing helper only run while something needs them.

## Test hooks

```sh
osascript -l JavaScript -e "ObjC.import('Foundation'); \$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('local.pockai.player.open', \$(), \$(), true)"
```

Names: `local.pockai.games.open` (object = `0`–`3` or empty), `local.pockai.player.open`, `local.pockai.ai.open` (object = text), `local.pockai.ai.run` (object = mode, e.g. `fix`), `local.pockai.settings`, and Purrbar's `local.pockai.purr.*`.
Captions: `curl -X POST http://127.0.0.1:38917/subtitle -d '{"text":"Hello","site":"Test"}'`.
`screencapture -b tb.png` captures the Touch Bar. Crash log: `~/Library/Logs/PockAI/last-crash.log`.

Credits: Pock & PockKit © Pierluigi Galdi (MIT), TinyConstraints © Robert-Hein Hooijmans (MIT).
