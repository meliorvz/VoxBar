# VoxBar Backend

Local article-to-speech for macOS using:

- `requests` to fetch URLs
- `trafilatura` as the primary article extractor
- `readability-lxml` as a fallback extractor
- `kokoro-onnx` for local text-to-speech
- a local LM Studio-compatible model for short title metadata
- `afplay` with `ffplay` fallback for playback

Everything lives in this folder.

## Current Layout

- `article_tts.py`: main CLI
- `speak-article`: thin wrapper around the project venv
- `setup.sh`: venv setup and Kokoro model download
- `output/jobs/<job-id>/`: per-run assets and `manifest.json`
- `output/previews/`: combined voice preview wavs and indexes
- `output/`: legacy flat outputs from earlier runs

## What It Does

You can:

- extract the readable body from a URL
- synthesize pasted text directly
- read from stdin or a local text file
- generate a short local-model title while Kokoro is rendering
- save cleaned text plus the rendered `.wav`
- play the result locally on your Mac

## Setup

```bash
./setup.sh
```

`setup.sh` creates `.venv`, installs Python dependencies, and downloads:

- `models/kokoro-v1.0.int8.onnx`
- `models/voices-v1.0.bin`

## Basic Usage

Generate and play from a URL:

```bash
./speak-article "https://research.google/blog/turboquant-redefining-ai-efficiency-with-extreme-compression/"
```

Generate from a URL but do not play:

```bash
./speak-article "https://example.com/article" --no-play
```

Generate from raw text:

```bash
./speak-article --text "This is some text I want spoken out loud."
```

Generate from a local file:

```bash
./speak-article --text-file ./notes.txt
```

Generate from stdin:

```bash
pbpaste | ./speak-article
```

or:

```bash
cat article.txt | ./speak-article --stdin
```

Generate with a fixed job id:

```bash
./speak-article --job-id demo-001 --text "Hello world" --no-play
```

## Voices And Speed

List available Kokoro voices:

```bash
./speak-article --list-voices
```

Machine-readable voice list:

```bash
./speak-article --list-voices-json
```

Change the voice:

```bash
./speak-article "https://example.com/article" --voice af_bella
```

Adjust speed:

```bash
./speak-article --text "Hello world" --speed 0.85
```

The default voice is `af_alloy`.

This install also includes Mandarin voices such as:

- `zf_xiaobei`
- `zf_xiaoni`
- `zf_xiaoxiao`
- `zf_xiaoyi`
- `zm_yunjian`
- `zm_yunxi`
- `zm_yunxia`
- `zm_yunyang`

## Language Handling

The default language mode is `auto`.

Current behavior:

- the backend supports the Kokoro voice-language families shipped in this build: `en-us`, `en-gb`, `es`, `fr-fr`, `hi`, `it`, `ja`, `pt-br`, and `cmn`
- the bundled espeak backend advertises many more phonemizer languages, but the Kokoro voice set in this repo only has voices for the families above
- auto mode scores the text with lightweight script, accent, and word hints instead of a binary English-vs-Mandarin rule
- the selected voice acts as a tie-breaker when the input is ambiguous
- when auto mode detects a language family that does not match the selected voice, the bridge falls back to that family’s default voice
- common aliases are normalized, so `en`, `fr`, `pt`, `zh`, and `es-419` map to the appropriate Kokoro language code

You can still force a language explicitly:

```bash
./speak-article --text "Hello world" --lang en-us
./speak-article --text "道德经" --lang cmn --voice zf_xiaobei
./speak-article --text "Bonjour le monde" --lang fr-fr --voice ff_siwis
```

## Title Metadata

By default, the bridge asks a local LM Studio-compatible model for:

- `summary_name`
- `summary`
- `tags`

That metadata call runs in parallel with Kokoro rendering. The bridge will:

- start the LM Studio server if needed
- load the metadata model only for the request
- unload the model after the request completes

The current default metadata model is `qwen3.5-2b`.

Generate metadata only:

```bash
./speak-article --metadata-only --text "A short passage to title"
```

Skip metadata generation:

```bash
./speak-article --no-metadata --text "A short passage to title"
```

Override the metadata model:

```bash
./speak-article --text "Hello world" --metadata-model qwen3.5-4b
```

## Voice Previews

Generate one combined preview wav for every voice:

```bash
./speak-article --preview-all-voices --no-play
```

Use a custom phrase for the preview:

```bash
./speak-article --preview-all-voices --preview-text "The quick brown fox jumps over the lazy dog."
```

Each voice preview prompt is spoken as:

```text
This is {voice name}. {preview text}
```

## Output

Each run creates:

- a cleaned `.txt` file
- a rendered `.wav` file
- a per-run `manifest.json`

Saved artifact names use:

```text
yymmdd-hhmmss-{slug}
```

For example:

```text
260325-152553-short-filename-test-for-timestamp-prefix.wav
```

## Input Cleaning

Before TTS, the bridge strips markdown-style formatting noise that would otherwise get spoken aloud.

It removes or normalizes:

- emphasis markers like `*bold*`, `**bold**`, `_italic_`, `~~strike~~`
- heading markers, blockquotes, bullets, checkboxes, and numbered list prefixes
- markdown links and images while keeping readable labels
- footnote references and definition lines
- inline code markers and fenced code blocks
- markdown table separators

It deliberately keeps normal sentence punctuation, apostrophes, decimals, and hyphenated prose.

## How Article Fetching Works

For URL input the pipeline is:

1. Fetch HTML with `requests` and a browser-like user agent.
2. Try `trafilatura.extract(...)` to get the main article body while dropping navigation and page chrome.
3. If that result is too weak, fall back to `readability-lxml`.
4. Normalize and clean the extracted text.
5. Resolve language and voice.
6. Render audio locally with Kokoro.

## Machine-Readable Events

For app integration, the CLI can emit newline-delimited JSON:

```bash
./speak-article --json-events --job-id example-123 --text "Hello world" --no-play
```

Event types include:

- `stage`
- `progress`
- `result`
- `error`

Example:

```json
{"type":"stage","name":"input","message":"Preparing input","job_id":"example-123"}
{"type":"progress","current":1,"total":4,"characters":812,"stage":"synthesizing"}
{"type":"result","kind":"job","status":"completed","job_id":"example-123","audio_path":"/.../audio.wav"}
```

## Does It Work Generally?

Usually yes, but with limits:

- It works well on normal article pages, blogs, docs pages, and many news sites.
- It works less reliably on pages that require JavaScript to render the article body.
- It can struggle on paywalled pages, login-gated pages, or pages with unusual markup.
- Raw text input is the reliable path because extraction is skipped entirely.

## Timing

The CLI reports timing for:

- input preparation
- TTS rendering
- total runtime

In local testing, the sample Google Research article completed in roughly 4 to 5 minutes total. Extraction was fast; most of the time was spent in Kokoro rendering the full article audio.

Short pasted-text runs are usually just a few seconds.

## Playback

The script tries:

1. `afplay`
2. `ffplay -nodisp -autoexit`

If you already have a generated file and just want to play it:

```bash
afplay ./output/jobs/<job-id>/your-file.wav
```
