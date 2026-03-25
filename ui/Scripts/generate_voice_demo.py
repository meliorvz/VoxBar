from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import soundfile as sf
from kokoro_onnx import Kokoro

ROOT = Path(__file__).resolve().parents[1]
ARTICLE_TTS_ROOT = ROOT.parent / "backend"
sys.path.insert(0, str(ARTICLE_TTS_ROOT))
import article_tts

MODEL_PATH = ARTICLE_TTS_ROOT / "models" / "kokoro-v1.0.int8.onnx"
VOICES_PATH = ARTICLE_TTS_ROOT / "models" / "voices-v1.0.bin"
DEFAULT_OUTPUT = ROOT / "Resources" / "VoiceDemo" / "all-voices-pangram.wav"
PHRASE = article_tts.DEFAULT_PREVIEW_TEXT


def prompt_for_voice(voice: str) -> str:
    return article_tts.preview_prompt_for_voice(voice, PHRASE)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Render a single wav file containing all Kokoro voices.")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--pause", type=float, default=0.30)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)

    kokoro = Kokoro(str(MODEL_PATH), str(VOICES_PATH))
    voices = kokoro.get_voices()
    sample_rate = 24000
    silence = np.zeros(int(sample_rate * args.pause), dtype=np.float32)

    rendered: list[np.ndarray] = []
    for voice in voices:
        preview_lang = "cmn" if article_tts.is_mandarin_voice(voice) and article_tts.count_han_characters(PHRASE) > 0 else "en-us"
        samples, current_rate = kokoro.create(prompt_for_voice(voice), voice=voice, speed=1.0, lang=preview_lang)
        if current_rate != sample_rate:
            raise RuntimeError(f"Unexpected sample-rate mismatch: {current_rate}")
        rendered.append(samples)
        rendered.append(silence)

    audio = np.concatenate(rendered)
    sf.write(args.output, audio, sample_rate)
    print(args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
