# VoxBar

Turn articles or pasted text into speech on your Mac, then play them from a menu bar app.

VoxBar is a local macOS reading-to-audio tool built around Kokoro voices. Paste a link or text, generate a spoken version, and keep listening from a compact player with history, voice presets, and speed control.

## Why VoxBar

- turn long articles into something you can listen to while walking, commuting, or working
- keep the workflow lightweight with a menu bar app instead of a heavy document app
- keep the speech stack local instead of depending on a hosted TTS service
- clean pasted markdown and article chrome before synthesis so the output sounds more natural
- get optional local-model titles and metadata for cleaner history entries

## What It Feels Like

1. Paste a URL or some text.
2. Pick a voice and speed, or use one of your starred presets.
3. Generate once, then play, pause, skip, rewind, and revisit recent runs from the menu bar.

## What You Get

- local article extraction for normal web articles and blog posts
- local Kokoro TTS with multiple voices
- automatic English vs Mandarin routing
- speed control from `0.50x` to `1.50x`
- voice + speed favorites
- recent generation history with playback and delete
- voice preview playback before committing to a voice
- optional local title metadata via LM Studio

## Install

From a fresh clone, the shortest path is:

```bash
./build.sh
```

That script:

- sets up the Python backend
- installs the required Python packages
- downloads the Kokoro model files
- builds the Swift menu bar app
- opens `VoxBar.app`

If you want to launch it later:

```bash
open ./ui/dist/VoxBar.app
```

## Requirements

Required:

- macOS 14 or newer
- Python 3 with `venv`
- Xcode Command Line Tools or a working Swift toolchain
- internet on first setup to install Python packages and download Kokoro models

Optional:

- LM Studio, if you want better local titles and metadata for generated runs

LM Studio is not required for the core app. Without it, VoxBar still extracts articles and generates speech locally.

## Quick CLI Examples

Generate from a link:

```bash
cd backend
./speak-article "https://example.com/article"
```

Generate from pasted text:

```bash
cd backend
./speak-article --text "This is the text I want spoken."
```

## Repo Layout

- `backend/`: Python extraction + TTS engine
- `ui/`: Swift menu bar app
- `build.sh`: one-command setup and app build
- `backend/README.md`: backend flags, setup, and output details
- `ui/README.md`: app-specific behavior and UI notes

## Notes

- The app resolves the backend relative to the repo by default.
- If you move the backend elsewhere, set `VOXBAR_BACKEND_ROOT` to the directory that contains `speak-article`.
- App support data migrates from the old `ArticleTTSBar` name to `VoxBar` on first launch after the rename.
