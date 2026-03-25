from __future__ import annotations

from datetime import datetime
from pathlib import Path

import numpy as np
import soundfile as sf

import article_tts

PROJECT_DIR = Path(__file__).resolve().parent
OUTPUT_DIR = PROJECT_DIR / "output"
PHRASE = article_tts.DEFAULT_PREVIEW_TEXT


def main() -> int:
    kokoro = article_tts.build_kokoro()
    voices = kokoro.get_voices()
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    stem = f"{timestamp}-kokoro-voice-preview"
    wav_path = OUTPUT_DIR / f"{stem}.wav"
    txt_path = OUTPUT_DIR / f"{stem}.txt"
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    combined: list[np.ndarray] = []
    transcript_lines: list[str] = []
    sample_rate: int | None = None

    for index, voice in enumerate(voices, start=1):
        line = f"{index:02d}. {voice}"
        transcript_lines.append(line)
        prompt = article_tts.preview_prompt_for_voice(voice, PHRASE)
        preview_lang = "cmn" if article_tts.is_mandarin_voice(voice) and article_tts.count_han_characters(PHRASE) > 0 else "en-us"
        print(f"[{index}/{len(voices)}] {voice}", flush=True)
        samples, current_rate = kokoro.create(prompt, voice=voice, speed=1.0, lang=preview_lang)
        if sample_rate is None:
            sample_rate = current_rate
        combined.append(samples)
        combined.append(np.zeros(int(current_rate * 0.45), dtype=np.float32))

    if sample_rate is None:
        raise RuntimeError("No voice previews were generated.")

    audio = np.concatenate(combined)
    sf.write(wav_path, audio, sample_rate)
    txt_path.write_text(
        "Kokoro voice preview order\n\n" + "\n".join(transcript_lines) + "\n",
        encoding="utf-8",
    )

    print(f"Preview text: {txt_path}")
    print(f"Preview audio: {wav_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
