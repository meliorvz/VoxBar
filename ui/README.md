# VoxBar

Menu bar app for local article and text-to-speech on macOS.

## What It Does

- accepts a URL or pasted text
- runs the existing Python bridge in `../backend`
- shows condensed progress while the job runs
- auto-plays the completed generation
- keeps a recent list with play and delete
- plays audio with `AVAudioPlayer`
- lets you choose voice and speed defaults
- supports up to 5 starred `voice + speed` presets
- supports per-voice preview playback
- uses local-model metadata titles from the backend when available

## Current UI Flow

The menu is player-first:

- a compact `Now Playing` area stays at the top
- `Source` is collapsible and expands while generating
- `Voice & Speed` is collapsible and shows the current selection when closed
- `Recent` is collapsible and stays out of the way until needed

When a generation finishes successfully:

- the new result is inserted at the top of history
- it becomes the selected item
- playback starts automatically
- the source and settings sections collapse again

## Build

```bash
./Scripts/build-app.sh
```

The bundle is written to:

```bash
./dist/VoxBar.app
```

Open it with:

```bash
open ./dist/VoxBar.app
```

## Backend Dependency

The app depends on the Python bridge in `../backend`.

The bridge currently provides:

- article extraction
- Kokoro synthesis
- automatic English vs Mandarin routing
- local LM Studio-compatible title metadata
- JSON progress events

If the bridge path changes, update `AppPaths.bridgeScript`.

## Input Rules

- if the input starts with `http://` or `https://`, it is treated as a URL
- otherwise it is treated as raw text

The backend also cleans pasted markdown-ish formatting before TTS so the app is less likely to read `*bold*` or link syntax out loud.

## Voice, Speed, And Presets

The app loads available voices from the bridge's `--list-voices-json` output.

Current behavior:

- default voice is `af_alloy`
- speed persists in `UserDefaults`
- speed range is `0.50x` to `1.50x`
- speed step is `0.05x`
- voice previews use the currently selected speed
- you can star up to 5 combined `voice + speed` presets
- starred presets appear at the top of the custom voice list

## Language Handling

Language resolution happens in the backend, not the Swift UI.

Current behavior:

- mostly English text uses `en-us`
- mostly Chinese text uses `cmn`
- short pure-Chinese inputs like `道德经` route to Mandarin correctly
- if Chinese text is detected while an English voice is selected, the backend falls back to a Mandarin voice

## History

Each history item stores:

- title
- metadata summary when available
- input kind
- voice
- source preview
- run folder
- generated text path
- generated audio path

Deleting a history item removes its run folder from disk.

## Playback

Playback controls operate on the currently selected item:

- play / pause
- rewind 15 seconds
- skip forward 30 seconds
- seek via slider

Tapping a recent row switches the active item and plays it.

## Voice Demo

The bundled all-voices pangram demo is here:

```bash
./Resources/VoiceDemo/all-voices-pangram.wav
```

Regenerate it with:

```bash
./Scripts/generate-voice-demo.sh
```

## Login Item

You can add `VoxBar.app` to macOS login items if you want it to launch at sign-in.

## Notes

- the app is light while idle
- Kokoro only works when generating audio
- the metadata model is loaded on demand by the backend and then unloaded again
- existing app support data migrates from `ArticleTTSBar` to `VoxBar` on first launch after the rename
- app logs are written under `~/Library/Application Support/VoxBar/Logs/voxbar.log`
- failed backend jobs write a detailed `error.txt` inside their job folder
