from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import subprocess
import sys
import time
import traceback
import uuid
import warnings
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import numpy as np
warnings.filterwarnings("ignore", message=r".*doesn't match a supported version.*")
import requests
import soundfile as sf
import trafilatura
from bs4 import BeautifulSoup
from kokoro_onnx import Kokoro, MAX_PHONEME_LENGTH
from readability import Document

PROJECT_DIR = Path(__file__).resolve().parent
MODELS_DIR = PROJECT_DIR / "models"
OUTPUT_DIR = PROJECT_DIR / "output"
JOBS_DIR = OUTPUT_DIR / "jobs"
PREVIEWS_DIR = OUTPUT_DIR / "previews"
MODEL_PATH = MODELS_DIR / "kokoro-v1.0.int8.onnx"
VOICES_PATH = MODELS_DIR / "voices-v1.0.bin"
DEFAULT_VOICE = "af_alloy"
DEFAULT_LANG = "auto"
DEFAULT_PREVIEW_TEXT = "The quick brown fox jumps over the lazy dog."
DEFAULT_METADATA_BASE_URL = os.getenv("ARTICLE_TTS_METADATA_BASE_URL", "http://127.0.0.1:1234")
DEFAULT_METADATA_MODEL = os.getenv(
    "ARTICLE_TTS_METADATA_MODEL",
    "qwen3.5-2b",
)
DEFAULT_METADATA_IDENTIFIER = os.getenv("ARTICLE_TTS_METADATA_IDENTIFIER", "articletts-2b")
DEFAULT_METADATA_CONTEXT = 4096
DEFAULT_METADATA_TTL = 90
DEFAULT_LMS_BIN = os.getenv("ARTICLE_TTS_LMS_BIN", "lms")
DEFAULT_METADATA_TIMEOUT = 30.0
DEFAULT_CHUNK_MAX_CHARS = 420
DEFAULT_CHUNK_MAX_PHONEMES = max(MAX_PHONEME_LENGTH - 30, 1)
DEFAULT_LANGUAGE_CODE = "en-us"
VOICE_PRIOR_WEIGHT = 0.5
METADATA_SYSTEM_PROMPT = """You create short descriptive metadata for articles and pasted text.

Return only JSON matching the provided schema.

Rules:
- Capture the main topic precisely.
- Use 2 to 6 words for summary_name when possible.
- Keep summary under 20 words.
- Prefer specificity over generic labels.
- Do not invent facts not present in the text.
- Keep tags short and topical.
- Do not include quotes, emojis, dates, or trailing punctuation in summary_name.
- Do not end summary_name with dangling words or incomplete phrases.
"""
METADATA_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "summary_name": {"type": "string"},
        "summary": {"type": "string"},
        "tags": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["summary_name", "summary", "tags"],
}


@dataclass(frozen=True)
class LanguageProfile:
    code: str
    default_voice: str
    voice_prefixes: tuple[str, ...]
    aliases: tuple[str, ...] = ()
    word_hints: tuple[str, ...] = ()
    char_hints: tuple[str, ...] = ()
    script_ranges: tuple[tuple[int, int], ...] = ()


TECH_SUBS: dict[str, str] = {
    "JSON": "jay-sahn",
    "YAML": "yam-ul",
    "TOML": "tom-ul",
    "WASM": "waz-um",
    "OAuth": "oh-auth",
    "NGINX": "engine-X",
    "PostgreSQL": "post-gres-Q-L",
    "SQLite": "S-Q-lite",
    "WiFi": "why-fye",
    "iOS": "eye-O-S",
    "macOS": "mac O S",
    "VS Code": "V S Code",
    "CRUD": "C-R-U-D",
}


def apply_tech_subs(text: str) -> str:
    for term, replacement in TECH_SUBS.items():
        text = text.replace(term, replacement)
    return text


def split_compound_tokens(text: str) -> str:
    """Split compound tokens (CamelCase, hyphens, underscores, quotes) before G2P.

    Uses multiple separate re.sub passes instead of one combined alternation
    pattern. This avoids Python's re alternation issue where a greedy
    consuming pattern matches at position 0 and prevents zero-width boundary
    assertions from firing at later positions.
    """
    # 1. Leading quotes
    text = re.sub(r"^[''']+", " ", text)
    # 2. Trailing quotes
    text = re.sub(r"[''']+$", " ", text)
    # 3. Internal apostrophes between word chars -> split
    text = re.sub(r"(?<=[a-zA-Z])['''](?=[a-zA-Z])", " ", text)
    # 4. Consecutive quote/punctuation runs -> single space
    text = re.sub(r"[''']+", " ", text)
    # 5. CamelCase boundaries: lowercase followed by uppercase
    text = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", text)
    # 6. Hyphens and underscores -> space
    text = re.sub(r"[-_]+", " ", text)
    return text


VOCAB_VOWELS = frozenset("aeiou")

CONTEXT_SENSITIVE_RULES: tuple[tuple[str, str, str], ...] = (
    ("a", "eɪ", "ɐ"),
    ("an", "ɐn", "ɐn"),
    ("to", "tʊ", "tə"),
    ("the", "ði", "ðə"),
)


def _get_next_word_first_char(
    token_words: list[tuple[int, str]], current_index: int
) -> str | None:
    """Get the first alphabetic character of the next word, or None if not found."""
    for i in range(current_index + 1, len(token_words)):
        _, word = token_words[i]
        for char in word:
            if char.isalpha():
                return char.lower()
    return None


def apply_context_sensitive_rules(text: str) -> str:
    """Apply context-sensitive pronunciation rules to text.

    Rules depend on the following word's first letter (vowel vs consonant).
    Since Kokoro uses phonemes internally, IPA forms are injected directly.
    Note: Kokoro may not support all IPA characters; integration may need
    adjustment based on how Kokoro's phoneme input is handled.
    """
    word_pattern = re.compile(r"[\w']+")
    tokens_with_spans: list[tuple[str, int, int]] = []
    for match in word_pattern.finditer(text):
        tokens_with_spans.append((match.group(), match.start(), match.end()))

    if not tokens_with_spans:
        return text

    token_words: list[tuple[int, str]] = [
        (start, word.lower()) for word, start, end in tokens_with_spans
    ]

    result_parts: list[str] = []
    last_end = 0

    for word, start, end in tokens_with_spans:
        if start > last_end:
            result_parts.append(text[last_end:start])

        wi = None
        for idx, (tok_start, _) in enumerate(token_words):
            if tok_start == start:
                wi = idx
                break

        if wi is not None:
            lower_word = token_words[wi][1]
            next_char = _get_next_word_first_char(token_words, wi)
            next_starts_vowel = next_char in VOCAB_VOWELS if next_char else False

            replacement = None
            for target, before_vowel, before_cons in CONTEXT_SENSITIVE_RULES:
                if lower_word == target:
                    replacement = before_vowel if next_starts_vowel else before_cons
                    break

            result_parts.append(replacement if replacement is not None else word)
        else:
            result_parts.append(word)

        last_end = end

    if last_end < len(text):
        result_parts.append(text[last_end:])

    return "".join(result_parts)


_voice_subs_cache: tuple[dict[str, str], dict[str, str]] | None = None


def discover_voice_subs() -> Path | None:
    """Walk up from the current working directory to find a .voice-subs file."""
    cwd = Path.cwd()
    # Check cwd itself first, then each parent
    for directory in [cwd] + list(cwd.parents):
        voice_subs_path = directory / ".voice-subs"
        if voice_subs_path.is_file():
            return voice_subs_path
    return None


def parse_voice_subs(path: Path) -> tuple[dict[str, str], dict[str, str]]:
    """Parse a .voice-subs file into text substitutions and phoneme overrides.

    Returns (text_subs, phoneme_subs) where:
    - text_subs: WORD=REPLACEMENT applied before G2P
    - phoneme_subs: WORD=/PHONEMES/ applied directly into phoneme stream (preliminary)
    """
    text_subs: dict[str, str] = {}
    phoneme_subs: dict[str, str] = {}
    if not path.is_file():
        return text_subs, phoneme_subs
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not key or not value:
            continue
        if value.startswith("/") and value.endswith("/"):
            phoneme_subs[key] = value[1:-1]
        else:
            text_subs[key] = value
    return text_subs, phoneme_subs


def _get_voice_subs() -> tuple[dict[str, str], dict[str, str]]:
    """Get cached voice subs or discover and cache them."""
    global _voice_subs_cache
    if _voice_subs_cache is None:
        path = discover_voice_subs()
        if path:
            _voice_subs_cache = parse_voice_subs(path)
        else:
            _voice_subs_cache = {}, {}
    return _voice_subs_cache


def apply_voice_subs(text: str) -> str:
    """Apply .voice-subs text substitutions before G2P."""
    text_subs, _ = _get_voice_subs()
    for word, replacement in text_subs.items():
        pattern = re.compile(r"\b" + re.escape(word) + r"\b", re.IGNORECASE)
        text = pattern.sub(replacement, text)
    return text


LANGUAGE_PROFILES: tuple[LanguageProfile, ...] = (
    LanguageProfile(
        code="en-us",
        default_voice="af_alloy",
        voice_prefixes=("af", "am"),
        aliases=("en", "en-us", "en_us", "english"),
        word_hints=(
            "the",
            "and",
            "of",
            "to",
            "in",
            "is",
            "it",
            "that",
            "for",
            "with",
            "as",
            "was",
            "are",
            "this",
            "be",
            "from",
            "or",
            "by",
            "on",
            "an",
            "not",
        ),
    ),
    LanguageProfile(
        code="en-gb",
        default_voice="bf_isabella",
        voice_prefixes=("bf", "bm"),
        aliases=("en-gb", "en_gb", "en-uk", "en_uk", "british"),
        word_hints=(
            "the",
            "and",
            "of",
            "to",
            "in",
            "is",
            "it",
            "that",
            "for",
            "with",
            "as",
            "was",
            "are",
            "this",
            "be",
            "from",
            "or",
            "by",
            "on",
            "an",
            "not",
        ),
    ),
    LanguageProfile(
        code="es",
        default_voice="ef_dora",
        voice_prefixes=("ef", "em"),
        aliases=("es", "es-419", "es_419", "spanish"),
        word_hints=("el", "la", "de", "que", "y", "en", "los", "por", "para", "con", "una", "del", "las", "no"),
        char_hints=("ñ", "¿", "¡", "á", "é", "í", "ó", "ú", "ü"),
    ),
    LanguageProfile(
        code="fr-fr",
        default_voice="ff_siwis",
        voice_prefixes=("ff",),
        aliases=("fr", "fr-fr", "fr_be", "fr-be", "fr_ch", "fr-ch", "french"),
        word_hints=("le", "la", "de", "et", "les", "des", "un", "une", "que", "dans", "pour", "est", "pas"),
        char_hints=("à", "â", "æ", "ç", "é", "è", "ê", "ë", "î", "ï", "ô", "œ", "ù", "û", "ü", "ÿ"),
    ),
    LanguageProfile(
        code="hi",
        default_voice="hf_alpha",
        voice_prefixes=("hf", "hm"),
        aliases=("hi", "hindi"),
        script_ranges=((0x0900, 0x097F),),
    ),
    LanguageProfile(
        code="it",
        default_voice="if_sara",
        voice_prefixes=("if", "im"),
        aliases=("it", "italian"),
        word_hints=("il", "lo", "la", "di", "che", "e", "un", "una", "per", "con", "non", "del", "della"),
        char_hints=("à", "è", "é", "ì", "ò", "ù"),
    ),
    LanguageProfile(
        code="ja",
        default_voice="jf_alpha",
        voice_prefixes=("jf", "jm"),
        aliases=("ja", "japanese"),
        script_ranges=((0x3040, 0x30FF),),
    ),
    LanguageProfile(
        code="pt-br",
        default_voice="pf_dora",
        voice_prefixes=("pf", "pm"),
        aliases=("pt", "pt-br", "pt_br", "portuguese"),
        word_hints=("de", "que", "e", "o", "a", "os", "as", "um", "uma", "para", "com", "não", "por", "da"),
        char_hints=("ã", "õ", "ç", "á", "à", "â", "é", "ê", "í", "ó", "ô", "ú"),
    ),
    LanguageProfile(
        code="cmn",
        default_voice="zf_xiaobei",
        voice_prefixes=("zf", "zm"),
        aliases=("cmn", "cmn-latn-pinyin", "zh", "zh-cn", "zh_cn", "mandarin"),
        script_ranges=((0x3400, 0x4DBF), (0x4E00, 0x9FFF), (0xF900, 0xFAFF)),
    ),
)

LANGUAGE_PROFILE_BY_CODE = {profile.code: profile for profile in LANGUAGE_PROFILES}
LANGUAGE_ALIAS_TO_CODE = {
    alias.casefold().replace("_", "-"): profile.code
    for profile in LANGUAGE_PROFILES
    for alias in profile.aliases
}
VOICE_PREFIX_TO_LANGUAGE_CODE = {
    prefix: profile.code
    for profile in LANGUAGE_PROFILES
    for prefix in profile.voice_prefixes
}
SUPPORTED_LANGUAGE_CODES = tuple(profile.code for profile in LANGUAGE_PROFILES)
SUPPORTED_LANGUAGE_HELP = ", ".join(SUPPORTED_LANGUAGE_CODES)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Fetch an article URL or accept raw text, synthesize speech, and play it."
    )
    parser.add_argument("source", nargs="?", help="Article URL or raw text")
    parser.add_argument("--text", help="Raw text to synthesize directly")
    parser.add_argument("--text-file", type=Path, help="Path to a text file to synthesize")
    parser.add_argument("--stdin", action="store_true", help="Read raw text from stdin")
    parser.add_argument("--title", help="Optional title used for output filenames")
    parser.add_argument("--voice", default=DEFAULT_VOICE, help=f"Kokoro voice name. Default: {DEFAULT_VOICE}")
    parser.add_argument(
        "--lang",
        default=DEFAULT_LANG,
        help=(
            "Kokoro language code. Use 'auto' or one of: "
            f"{SUPPORTED_LANGUAGE_HELP}. Common aliases like en, fr, pt, zh, and es-419 are normalized. "
            f"Default: {DEFAULT_LANG}"
        ),
    )
    parser.add_argument("--speed", type=float, default=1.0, help="Speech speed multiplier")
    parser.add_argument("--metadata-only", action="store_true", help="Generate title metadata JSON and exit")
    parser.add_argument("--no-metadata", action="store_true", help="Skip local title/metadata generation")
    parser.add_argument("--lms-bin", default=DEFAULT_LMS_BIN, help=f"Path to LM Studio CLI. Default: {DEFAULT_LMS_BIN}")
    parser.add_argument(
        "--metadata-base-url",
        default=DEFAULT_METADATA_BASE_URL,
        help=f"Local metadata endpoint base URL. Default: {DEFAULT_METADATA_BASE_URL}",
    )
    parser.add_argument(
        "--metadata-model",
        default=DEFAULT_METADATA_MODEL,
        help=f"Local metadata model name. Default: {DEFAULT_METADATA_MODEL}",
    )
    parser.add_argument(
        "--metadata-identifier",
        default=DEFAULT_METADATA_IDENTIFIER,
        help=f"Loaded-model identifier used for metadata requests. Default: {DEFAULT_METADATA_IDENTIFIER}",
    )
    parser.add_argument(
        "--metadata-context-length",
        type=int,
        default=DEFAULT_METADATA_CONTEXT,
        help=f"Context length used when loading the metadata model. Default: {DEFAULT_METADATA_CONTEXT}",
    )
    parser.add_argument(
        "--metadata-ttl",
        type=int,
        default=DEFAULT_METADATA_TTL,
        help=f"Safety TTL in seconds for metadata model loads. Default: {DEFAULT_METADATA_TTL}",
    )
    parser.add_argument(
        "--metadata-timeout",
        type=float,
        default=DEFAULT_METADATA_TIMEOUT,
        help=f"Metadata request timeout in seconds. Default: {DEFAULT_METADATA_TIMEOUT}",
    )
    parser.add_argument("--list-voices", action="store_true", help="Print available Kokoro voices and exit")
    parser.add_argument("--list-voices-json", action="store_true", help="Print available voices as JSON and exit")
    parser.add_argument("--json-events", action="store_true", help="Emit machine-readable NDJSON events")
    parser.add_argument("--json-progress", action="store_true", help="Deprecated alias for --json-events")
    parser.add_argument("--job-id", help="Stable job id used for output/jobs/<job-id>")
    parser.add_argument(
        "--stream-chunks",
        action="store_true",
        help="Write per-chunk wav files and emit chunk-ready events for progressive playback",
    )
    parser.add_argument(
        "--preview-all-voices",
        action="store_true",
        help="Generate one combined wav preview for every Kokoro voice",
    )
    parser.add_argument(
        "--preview-text",
        default=DEFAULT_PREVIEW_TEXT,
        help=f"Phrase used for --preview-all-voices. Default: {DEFAULT_PREVIEW_TEXT}",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=OUTPUT_DIR,
        help=f"Directory for extracted text and wav output. Default: {OUTPUT_DIR}",
    )
    parser.add_argument("--no-play", action="store_true", help="Generate files but do not play audio")
    return parser.parse_args()


def require_models() -> None:
    missing = [path.name for path in (MODEL_PATH, VOICES_PATH) if not path.exists()]
    if missing:
        names = ", ".join(missing)
        raise FileNotFoundError(
            f"Missing Kokoro model files: {names}. Put them in {MODELS_DIR}"
        )


def build_kokoro() -> Kokoro:
    require_models()
    return Kokoro(str(MODEL_PATH), str(VOICES_PATH))


def fetch_html(url: str) -> str:
    response = requests.get(
        url,
        headers={
            "User-Agent": (
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/122.0.0.0 Safari/537.36"
            )
        },
        timeout=30,
    )
    response.raise_for_status()
    return response.text


def strip_markdown_for_tts(text: str) -> str:
    cleaned = text
    cleaned = re.sub(r"\\([\\`*_{}\[\]()#+\-.!|>~])", r"\1", cleaned)
    cleaned = re.sub(r"```[\w-]*\n.*?```", "", cleaned, flags=re.DOTALL)
    cleaned = re.sub(r"!\[([^\]]*)\]\([^)]+\)", r"\1", cleaned)
    cleaned = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", cleaned)
    cleaned = re.sub(r"\[([^\]]+)\]\[[^\]]*\]", r"\1", cleaned)
    cleaned = re.sub(r"(?m)^\s*\[\^?[^\]]+\]:\s*.*$", "", cleaned)
    cleaned = re.sub(r"(?<!\w)\[\^?[A-Za-z0-9_-]+\]", "", cleaned)
    cleaned = re.sub(r"(?<=\w)\[\^?[A-Za-z0-9_-]+\]", "", cleaned)
    cleaned = re.sub(r"<https?://[^>]+>", "", cleaned)
    cleaned = re.sub(r"https?://\S+", "", cleaned)
    cleaned = re.sub(r"(?m)^\s{0,3}#{1,6}\s*", "", cleaned)
    cleaned = re.sub(r"(?m)^\s{0,3}>\s?", "", cleaned)
    cleaned = re.sub(r"(?m)^\s*[-+*]\s+", "", cleaned)
    cleaned = re.sub(r"(?m)^\s*\d+[.)]\s+", "", cleaned)
    cleaned = re.sub(r"(?m)^\s*\[[ xX]\]\s+", "", cleaned)
    cleaned = re.sub(r"(?m)^\s*(?:[-*_]\s*){3,}$", "", cleaned)
    cleaned = re.sub(r"(?m)^\s*\|?(?:\s*:?-+:?\s*\|)+\s*:?-+:?\s*\|?\s*$", "", cleaned)
    cleaned = re.sub(r"(?<!\w)\*\*\*([^*\n]+)\*\*\*(?!\w)", r"\1", cleaned)
    cleaned = re.sub(r"(?<!\w)\*\*([^*\n]+)\*\*(?!\w)", r"\1", cleaned)
    cleaned = re.sub(r"(?<!\w)\*([^*\n]+)\*(?!\w)", r"\1", cleaned)
    cleaned = re.sub(r"(?<!\w)___([^_\n]+)___(?!\w)", r"\1", cleaned)
    cleaned = re.sub(r"(?<!\w)__([^_\n]+)__(?!\w)", r"\1", cleaned)
    cleaned = re.sub(r"(?<!\w)_([^_\n]+)_(?!\w)", r"\1", cleaned)
    cleaned = re.sub(r"~~([^~\n]+)~~", r"\1", cleaned)
    cleaned = re.sub(r"`([^`\n]+)`", r"\1", cleaned)
    normalized_lines: list[str] = []
    for line in cleaned.splitlines():
        if line.count("|") >= 2:
            stripped = line.strip()
            if stripped.startswith("|") or stripped.endswith("|"):
                line = line.replace("|", " ")
        normalized_lines.append(line)
    cleaned = "\n".join(normalized_lines)
    cleaned = re.sub(r"[ \t]{2,}", " ", cleaned)
    return cleaned


def clean_text(text: str) -> str:
    import unicodedata
    text = unicodedata.normalize('NFKC', text)
    text = strip_markdown_for_tts(text)
    text = apply_tech_subs(text)
    text = split_compound_tokens(text)
    text = apply_context_sensitive_rules(text)
    text = apply_voice_subs(text)
    lines: list[str] = []
    for raw_line in text.splitlines():
        line = re.sub(r"\s+", " ", raw_line).strip()
        if not line:
            continue
        if len(line) == 1:
            continue
        lines.append(line)

    text = "\n\n".join(lines)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def derive_title_from_text(text: str) -> str:
    for line in text.splitlines():
        cleaned = re.sub(r"\s+", " ", line).strip(" -#\t")
        if len(cleaned) >= 3:
            return cleaned[:80]
    return "pasted-text"


# Morphological suffix decomposition helpers
VOICED_CONSONANTS = frozenset("bdgjmnnrlw")
VOICELESS_CONSONANTS = frozenset("ptkfsθ")


def ends_with_double_consonant(word: str) -> bool:
    """Check if word ends with a doubled consonant (e.g., 'run', 'sit')."""
    if len(word) < 3:
        return False
    return word[-1] == word[-2] and word[-1] not in "aeiou"


def ends_with_e_drops(word: str) -> bool:
    """Check if word ends with consonant + e that drops before suffix (e.g., 'hope')."""
    if len(word) < 2 or word[-1] != "e":
        return False
    if len(word) == 2:
        return True
    return word[-2] not in "aeiou"


def apply_es_suffix(word: str) -> str:
    """Apply -s/-es suffix, returning root + phonetic suffix."""
    if word.endswith("ies"):
        return word[:-3] + "+ᵻz"
    if word.endswith("es"):
        base = word[:-2]
        if base.endswith(("ss", "xs", "zz", "ch", "sh")):
            return base + "+ᵻz"
        last = base[-1] if base else ""
        if last in VOICELESS_CONSONANTS:
            return base + "+s"
        return base + "+z"
    if word.endswith("s"):
        base = word[:-1]
        if base.endswith(("ss", "xs", "zz", "ch", "sh")):
            return base + "+ᵻz"
        last = base[-1] if base else ""
        if last in VOICELESS_CONSONANTS:
            return base + "+s"
        return base + "+z"
    last = word[-1] if word else ""
    if last in VOICELESS_CONSONANTS:
        return word + "+s"
    return word + "+z"


def apply_ed_suffix(word: str) -> str:
    """Apply -ed suffix, returning root + phonetic suffix."""
    if word.endswith("ed"):
        base = word[:-2]
        if not base:
            return word + "+id"
        if ends_with_e_drops(base + "e"):
            return base + "+d"
        if base[-1] in "dt":
            return base + "+ᵻd"
        if base[-1] in VOICED_CONSONANTS:
            return base + "+d"
        if base[-1] in VOICELESS_CONSONANTS:
            return base + "+t"
        return base + "+d"
    return word + "+ed"


def apply_ing_suffix(word: str) -> str:
    """Apply -ing suffix, returning root + phonetic suffix."""
    if word.endswith("ing"):
        base = word[:-3]
        if not base:
            return word
        if base.endswith("ck"):
            return base[:-1] + "+cking"
        if len(base) >= 2 and base[-1] == base[-2] and base[-1] not in "aeiou":
            base = base[:-1]
        elif len(base) >= 3:
            third_last = base[-3]
            is_vowel = third_last in "aeiou"
            if is_vowel and base[-1] not in "aeiou" and base[-1] not in "wx":
                base = base + base[-1]
        return base + "+ing"
    return word + "+ing"


def morphological_decompose(word: str) -> str:
    """Decompose a word into root + phonetic suffix for TTS fallback."""
    if not word or len(word) < 3:
        return word
    lower = word.lower()
    if lower.endswith("ing"):
        return apply_ing_suffix(word)
    if lower.endswith("ed"):
        return apply_ed_suffix(word)
    if lower.endswith("s") or lower.endswith("es"):
        return apply_es_suffix(word)
    return word


def decompose_for_tts(text: str) -> str:
    """Apply morphological decomposition to words in text for TTS OOV fallback."""
    words = re.findall(r"[\w']+", text)
    if not words:
        return text
    decomposed = text
    for word in words:
        if len(word) >= 3 and word == word.lower():
            decomp = morphological_decompose(word)
            if decomp != word:
                decomposed = decomposed.replace(word, decomp, 1)
    return decomposed


def preview_prompt_for_voice(voice: str, phrase: str) -> str:
    spoken_name = voice.replace("_", " ")
    normalized_phrase = phrase.strip()
    if normalized_phrase and normalized_phrase[-1] not in ".!?":
        normalized_phrase += "."
    return f"This is {spoken_name}. {normalized_phrase}"


def clamp_speed(speed: float) -> float:
    return max(0.5, min(1.5, speed))


def sanitize_summary_name(text: str) -> str:
    cleaned = text.strip().strip("\"'`")
    cleaned = re.sub(r"[\r\n]+", " ", cleaned)
    cleaned = re.sub(r"[^A-Za-z0-9 _-]+", "", cleaned)
    cleaned = re.sub(r"\s{2,}", " ", cleaned)
    cleaned = cleaned.strip(" .-_")
    words = cleaned.split()
    if not words:
        return ""
    cleaned_words = words[:6]
    trailing_noise = {
        "a", "an", "and", "as", "at", "by", "due", "for", "from", "in", "into",
        "of", "on", "or", "the", "to", "with",
    }
    while cleaned_words and cleaned_words[-1].lower() in trailing_noise:
        cleaned_words.pop()
    return " ".join(cleaned_words)


def sanitize_metadata_summary(text: str) -> str:
    cleaned = re.sub(r"\s+", " ", text).strip().strip("\"'`")
    return cleaned[:180]


def sanitize_tags(raw_tags: object) -> list[str]:
    if not isinstance(raw_tags, list):
        return []
    cleaned: list[str] = []
    for item in raw_tags:
        value = re.sub(r"[^A-Za-z0-9 +_-]+", "", str(item)).strip(" -_")
        if not value:
            continue
        lowered = value.lower()
        if lowered not in {tag.lower() for tag in cleaned}:
            cleaned.append(value[:24])
    return cleaned[:4]


def build_metadata_user_prompt(text: str, source_kind: str, title_hint: str | None) -> str:
    title_value = title_hint or "none"
    excerpt = text[:6000].strip()
    return f"""Create a concise title and metadata for this spoken-content job.

Context:
- source_kind: {source_kind}
- language: en
- title_hint: {title_value}

Source text:
{excerpt}
"""


def extract_text_message(body: dict[str, object]) -> str:
    message = body["choices"][0]["message"]
    content = (message.get("content") or "").strip()
    if not content:
        content = (message.get("reasoning_content") or "").strip()
    if not content:
        raise RuntimeError("Metadata model returned neither content nor reasoning_content.")
    return content


def extract_json_message(body: dict[str, object]) -> dict[str, object]:
    content = extract_text_message(body).strip()
    content = re.sub(r"^```(?:json)?\s*", "", content, flags=re.IGNORECASE)
    content = re.sub(r"\s*```$", "", content)
    try:
        return json.loads(content)
    except json.JSONDecodeError:
        start = content.find("{")
        end = content.rfind("}")
        if start != -1 and end != -1 and end > start:
            return json.loads(content[start : end + 1])
        raise RuntimeError("Metadata model returned invalid JSON.")


def generate_title_metadata(
    text: str,
    *,
    source_kind: str,
    title_hint: str | None,
    base_url: str,
    model: str,
    identifier: str,
    context_length: int,
    ttl_seconds: int,
    lms_bin: str,
    timeout_seconds: float,
) -> dict[str, object]:
    loaded_by_us = ensure_metadata_model_loaded(
        model=model,
        identifier=identifier,
        context_length=context_length,
        ttl_seconds=ttl_seconds,
        lms_bin=lms_bin,
    )
    payload = {
        "model": identifier,
        "temperature": 0.1,
        "max_tokens": 120,
        "response_format": {
            "type": "json_schema",
            "json_schema": {
                "name": "article_tts_metadata",
                "schema": METADATA_SCHEMA,
                "strict": True,
            },
        },
        "messages": [
            {"role": "system", "content": METADATA_SYSTEM_PROMPT},
            {
                "role": "user",
                "content": build_metadata_user_prompt(
                    text,
                    source_kind=source_kind,
                    title_hint=title_hint,
                ),
            },
        ],
    }
    response = requests.post(
        f"{base_url.rstrip('/')}/v1/chat/completions",
        json=payload,
        timeout=timeout_seconds,
    )
    try:
        response.raise_for_status()
        data = extract_json_message(response.json())
        summary_name = sanitize_summary_name(str(data.get("summary_name", "")))
        if not summary_name:
            raise RuntimeError("Metadata summary_name was empty after sanitization.")
        return {
            "summary_name": summary_name,
            "summary": sanitize_metadata_summary(str(data.get("summary", ""))),
            "tags": sanitize_tags(data.get("tags", [])),
            "model": model,
            "identifier": identifier,
        }
    finally:
        if loaded_by_us:
            try:
                unload_metadata_model(identifier=identifier, lms_bin=lms_bin)
            except Exception:
                pass


def build_named_artifact_paths(job_dir: Path, title: str) -> dict[str, Path]:
    timestamp = datetime.now().strftime("%y%m%d-%H%M%S")
    stem = f"{timestamp}-{slugify(title[:80])}"
    return {
        "text_path": job_dir / f"{stem}.txt",
        "audio_path": job_dir / f"{stem}.wav",
    }


def run_lms(args: list[str], *, lms_bin: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run([lms_bin, *args], check=True, capture_output=True, text=True)


def ensure_metadata_server_running(*, lms_bin: str) -> None:
    status = run_lms(["server", "status"], lms_bin=lms_bin)
    if "not running" in (status.stdout + status.stderr).lower():
        run_lms(["server", "start"], lms_bin=lms_bin)


def loaded_model_identifiers(*, lms_bin: str) -> set[str]:
    result = run_lms(["ps", "--json"], lms_bin=lms_bin)
    try:
        payload = json.loads(result.stdout or "[]")
    except json.JSONDecodeError:
        return set()
    if not isinstance(payload, list):
        return set()
    identifiers: set[str] = set()
    for item in payload:
        if not isinstance(item, dict):
            continue
        for key in ("identifier", "id"):
            value = item.get(key)
            if value:
                identifiers.add(str(value))
    return identifiers


def ensure_metadata_model_loaded(
    *,
    model: str,
    identifier: str,
    context_length: int,
    ttl_seconds: int,
    lms_bin: str,
) -> bool:
    ensure_metadata_server_running(lms_bin=lms_bin)
    if identifier in loaded_model_identifiers(lms_bin=lms_bin):
        return False
    run_lms(
        [
            "load",
            model,
            "--identifier",
            identifier,
            "--ttl",
            str(ttl_seconds),
            "-c",
            str(context_length),
            "--parallel",
            "1",
            "-y",
        ],
        lms_bin=lms_bin,
    )
    return True


def unload_metadata_model(*, identifier: str, lms_bin: str) -> None:
    run_lms(["unload", identifier], lms_bin=lms_bin)


def fallback_extract(html: str) -> tuple[str | None, str]:
    document = Document(html)
    title = document.short_title() or None
    summary_html = document.summary()
    soup = BeautifulSoup(summary_html, "html.parser")

    for tag in soup(["script", "style", "noscript", "svg"]):
        tag.decompose()

    text = soup.get_text("\n", strip=True)
    return title, clean_text(text)


def extract_article(url: str, html: str) -> tuple[str, str]:
    metadata = trafilatura.extract_metadata(html)
    title = metadata.title if metadata and metadata.title else None

    extracted = trafilatura.extract(
        html,
        url=url,
        include_comments=False,
        include_tables=True,
        include_formatting=False,
        favor_precision=True,
        deduplicate=True,
        output_format="txt",
        with_metadata=False,
    )

    text = clean_text(extracted or "")
    if len(text) >= 400:
        return title or "article", text

    fallback_title, fallback_text = fallback_extract(html)
    title = title or fallback_title or "article"
    if fallback_text:
        return title, fallback_text

    if text:
        return title or "article", text

    raise RuntimeError("Could not extract meaningful article text from the page.")


def slugify(value: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return slug or "article"


def count_characters_in_ranges(text: str, ranges: tuple[tuple[int, int], ...]) -> int:
    total = 0
    for char in text:
        codepoint = ord(char)
        if any(start <= codepoint <= end for start, end in ranges):
            total += 1
    return total


def normalize_language_code(value: str) -> str:
    normalized = value.strip().casefold().replace("_", "-")
    return LANGUAGE_ALIAS_TO_CODE.get(normalized, normalized)


def profile_for_language(code: str) -> LanguageProfile | None:
    return LANGUAGE_PROFILE_BY_CODE.get(normalize_language_code(code))


def profile_for_voice(voice: str) -> LanguageProfile | None:
    prefix = voice.split("_", 1)[0]
    code = VOICE_PREFIX_TO_LANGUAGE_CODE.get(prefix)
    if code is None:
        return None
    return LANGUAGE_PROFILE_BY_CODE.get(code)


def language_code_for_voice(voice: str) -> str | None:
    profile = profile_for_voice(voice)
    return profile.code if profile else None


def default_voice_for_language(code: str) -> str | None:
    profile = profile_for_language(code)
    return profile.default_voice if profile else None


def is_mandarin_voice(voice: str) -> bool:
    return language_code_for_voice(voice) == "cmn"


def preview_language_for_voice(voice: str, text: str) -> str:
    detection = detect_language(text, preferred_voice=voice)
    return str(detection["lang"])


def count_word_hints(tokens: list[str], hints: tuple[str, ...]) -> int:
    hint_set = set(hints)
    return sum(1 for token in tokens if token in hint_set)


def score_language_profile(text: str, tokens: list[str], profile: LanguageProfile) -> tuple[float, dict[str, int]]:
    evidence: dict[str, int] = {}
    score = 0.0

    if profile.script_ranges:
        script_count = count_characters_in_ranges(text, profile.script_ranges)
        if script_count:
            evidence["script_chars"] = script_count
            score += script_count * 4.0

    if profile.char_hints:
        hint_count = sum(text.count(char) for char in profile.char_hints)
        if hint_count:
            evidence["char_hints"] = hint_count
            score += hint_count * 3.0

    if profile.word_hints:
        word_hits = count_word_hints(tokens, profile.word_hints)
        if word_hits:
            evidence["word_hints"] = word_hits
            score += word_hits * 1.5

    return score, evidence


def detect_language(text: str, preferred_voice: str | None = None) -> dict[str, object]:
    normalized = re.sub(r"\s+", " ", text).strip()
    tokens = re.findall(r"[\w']+", normalized.casefold())
    scores: dict[str, float] = {}
    evidence: dict[str, dict[str, int]] = {}

    for profile in LANGUAGE_PROFILES:
        score, profile_evidence = score_language_profile(normalized, tokens, profile)
        scores[profile.code] = score
        if profile_evidence:
            evidence[profile.code] = profile_evidence

    preferred_profile = profile_for_voice(preferred_voice) if preferred_voice else None
    if preferred_profile is not None:
        scores[preferred_profile.code] = scores.get(preferred_profile.code, 0.0) + VOICE_PRIOR_WEIGHT
        evidence.setdefault(preferred_profile.code, {})["voice_prior"] = int(VOICE_PRIOR_WEIGHT * 10)

    ranked = sorted(scores.items(), key=lambda item: (item[1], item[0] == DEFAULT_LANGUAGE_CODE, item[0]), reverse=True)
    resolved_lang = ranked[0][0] if ranked else DEFAULT_LANGUAGE_CODE
    best_score = ranked[0][1] if ranked else 0.0
    runner_up_score = ranked[1][1] if len(ranked) > 1 else 0.0

    if best_score <= 0:
        fallback = preferred_profile.code if preferred_profile else DEFAULT_LANGUAGE_CODE
        return {
            "lang": fallback,
            "reason": "No strong language cues detected; using the selected voice or English default.",
            "scores": scores,
            "evidence": evidence,
            "preferred_voice_lang": preferred_profile.code if preferred_profile else None,
        }

    if best_score - runner_up_score < 1.0 and preferred_profile is not None:
        resolved_lang = preferred_profile.code
        reason = "Language cues were weak; using the selected voice language."
    else:
        reason = f"Detected {resolved_lang} from text cues."

    return {
        "lang": resolved_lang,
        "reason": reason,
        "scores": scores,
        "evidence": evidence,
        "preferred_voice_lang": preferred_profile.code if preferred_profile else None,
    }


def resolve_language_and_voice(
    text: str,
    requested_lang: str,
    requested_voice: str,
) -> tuple[str, str, dict[str, object]]:
    normalized_requested_lang = normalize_language_code(requested_lang)
    requested_voice_profile = profile_for_voice(requested_voice)

    if normalized_requested_lang != "auto":
        resolved_lang = normalized_requested_lang
        detection: dict[str, object] = {
            "mode": "manual",
            "reason": f"Language forced via --lang {resolved_lang}.",
            "requested_lang": requested_lang,
            "normalized_requested_lang": resolved_lang,
            "requested_voice": requested_voice,
            "preferred_voice_lang": requested_voice_profile.code if requested_voice_profile else None,
        }
        resolved_voice = requested_voice
        target_voice = default_voice_for_language(resolved_lang)
        if target_voice is not None:
            target_profile = profile_for_language(resolved_lang)
            if requested_voice_profile is None or requested_voice_profile.code != target_profile.code:
                resolved_voice = target_voice
                detection["voice_fallback"] = {
                    "from": requested_voice,
                    "to": resolved_voice,
                    "reason": "Selected voice does not match the forced language.",
                }
        return resolved_lang, resolved_voice, detection

    detection = detect_language(text, preferred_voice=requested_voice)
    resolved_lang = str(detection["lang"])
    resolved_voice = requested_voice
    target_voice = default_voice_for_language(resolved_lang)

    if target_voice is not None:
        target_profile = profile_for_language(resolved_lang)
        if requested_voice_profile is None or requested_voice_profile.code != target_profile.code:
            resolved_voice = target_voice
            detection["voice_fallback"] = {
                "from": requested_voice,
                "to": resolved_voice,
                "reason": "Detected language does not match the selected voice.",
            }

    detection["mode"] = "auto"
    detection["requested_lang"] = requested_lang
    detection["requested_voice"] = requested_voice
    return resolved_lang, resolved_voice, detection


def split_text_on_delimiters(text: str, delimiters: str) -> list[str]:
    units: list[str] = []
    current: list[str] = []

    for character in text:
        current.append(character)
        if character in delimiters:
            unit = "".join(current).strip()
            if unit:
                units.append(unit)
            current = []

    if current:
        unit = "".join(current).strip()
        if unit:
            units.append(unit)

    return units


def split_text_on_words(text: str) -> list[str]:
    return re.findall(r"\S+", text)


def phoneme_length(
    text: str,
    *,
    tokenizer: object,
    lang: str,
    cache: dict[str, int],
) -> int:
    cached = cache.get(text)
    if cached is not None:
        return cached

    length = len(tokenizer.phonemize(text, lang))
    cache[text] = length
    return length


def chunk_fits(
    text: str,
    *,
    max_chars: int,
    max_phonemes: int,
    tokenizer: object | None,
    lang: str,
    cache: dict[str, int],
) -> bool:
    if not text or len(text) > max_chars:
        return False
    if tokenizer is None:
        return True
    return phoneme_length(text, tokenizer=tokenizer, lang=lang, cache=cache) <= max_phonemes


def split_oversized_fragment(
    text: str,
    *,
    max_chars: int,
    max_phonemes: int,
    tokenizer: object | None,
    lang: str,
    cache: dict[str, int],
) -> list[str]:
    remaining = text.strip()
    fragments: list[str] = []

    while remaining:
        upper_bound = min(len(remaining), max_chars)
        lower_bound = 1
        best_index = 0

        while lower_bound <= upper_bound:
            midpoint = (lower_bound + upper_bound) // 2
            candidate = remaining[:midpoint].strip()
            if candidate and chunk_fits(
                candidate,
                max_chars=max_chars,
                max_phonemes=max_phonemes,
                tokenizer=tokenizer,
                lang=lang,
                cache=cache,
            ):
                best_index = midpoint
                lower_bound = midpoint + 1
            else:
                upper_bound = midpoint - 1

        if best_index <= 0:
            best_index = 1

        min_break_index = max(int(best_index * 0.55), 1)
        split_index = best_index
        window = remaining[:best_index]
        preferred_breaks = " \t\n-/,;:，、；："
        for break_char in preferred_breaks:
            break_at = window.rfind(break_char)
            if break_at >= min_break_index:
                split_index = break_at + 1
                break

        chunk = remaining[:split_index].strip()
        if not chunk:
            chunk = remaining[:best_index].strip()
            split_index = max(best_index, 1)

        fragments.append(chunk)
        remaining = remaining[split_index:].strip()

    return fragments


def assemble_chunks_from_units(
    units: list[str],
    *,
    max_chars: int,
    max_phonemes: int,
    tokenizer: object | None,
    lang: str,
    cache: dict[str, int],
) -> list[str]:
    chunks: list[str] = []
    current = ""

    for unit in units:
        piece = re.sub(r"\s+", " ", unit).strip()
        if not piece:
            continue

        if not chunk_fits(
            piece,
            max_chars=max_chars,
            max_phonemes=max_phonemes,
            tokenizer=tokenizer,
            lang=lang,
            cache=cache,
        ):
            if current:
                chunks.append(current)
                current = ""
            chunks.extend(
                split_into_chunks(
                    piece,
                    max_chars=max_chars,
                    max_phonemes=max_phonemes,
                    tokenizer=tokenizer,
                    lang=lang,
                    cache=cache,
                )
            )
            continue

        candidate = piece if not current else f"{current} {piece}"
        if chunk_fits(
            candidate,
            max_chars=max_chars,
            max_phonemes=max_phonemes,
            tokenizer=tokenizer,
            lang=lang,
            cache=cache,
        ):
            current = candidate
            continue

        if current:
            chunks.append(current)
        current = piece

    if current:
        chunks.append(current)

    return chunks


def split_into_chunks(
    text: str,
    max_chars: int = DEFAULT_CHUNK_MAX_CHARS,
    max_phonemes: int = DEFAULT_CHUNK_MAX_PHONEMES,
    *,
    tokenizer: object | None = None,
    lang: str = "en-us",
    cache: dict[str, int] | None = None,
) -> list[str]:
    normalized = re.sub(r"\n{3,}", "\n\n", text).strip()
    if not normalized:
        return []

    chunk_cache = cache if cache is not None else {}
    collapsed = re.sub(r"\s+", " ", normalized).strip()
    if chunk_fits(
        collapsed,
        max_chars=max_chars,
        max_phonemes=max_phonemes,
        tokenizer=tokenizer,
        lang=lang,
        cache=chunk_cache,
    ):
        return [collapsed]

    paragraphs = [part.strip() for part in normalized.split("\n\n") if part.strip()]
    chunks: list[str] = []

    for paragraph in paragraphs:
        paragraph_text = re.sub(r"\s+", " ", paragraph).strip()
        if not paragraph_text:
            continue

        if chunk_fits(
            paragraph_text,
            max_chars=max_chars,
            max_phonemes=max_phonemes,
            tokenizer=tokenizer,
            lang=lang,
            cache=chunk_cache,
        ):
            chunks.append(paragraph_text)
            continue

        sentence_units = split_text_on_delimiters(paragraph_text, ".!?。！？")
        if len(sentence_units) > 1:
            chunks.extend(
                assemble_chunks_from_units(
                    sentence_units,
                    max_chars=max_chars,
                    max_phonemes=max_phonemes,
                    tokenizer=tokenizer,
                    lang=lang,
                    cache=chunk_cache,
                )
            )
            continue

        clause_units = split_text_on_delimiters(paragraph_text, ",;:，、；：")
        if len(clause_units) > 1:
            chunks.extend(
                assemble_chunks_from_units(
                    clause_units,
                    max_chars=max_chars,
                    max_phonemes=max_phonemes,
                    tokenizer=tokenizer,
                    lang=lang,
                    cache=chunk_cache,
                )
            )
            continue

        word_units = split_text_on_words(paragraph_text)
        if len(word_units) > 1:
            chunks.extend(
                assemble_chunks_from_units(
                    word_units,
                    max_chars=max_chars,
                    max_phonemes=max_phonemes,
                    tokenizer=tokenizer,
                    lang=lang,
                    cache=chunk_cache,
                )
            )
            continue

        chunks.extend(
            split_oversized_fragment(
                paragraph_text,
                max_chars=max_chars,
                max_phonemes=max_phonemes,
                tokenizer=tokenizer,
                lang=lang,
                cache=chunk_cache,
            )
        )

    return chunks


class ProgressReporter:
    def __init__(self, json_mode: bool) -> None:
        self.json_mode = json_mode

    def emit(self, event_type: str, **payload: object) -> None:
        if self.json_mode:
            print(json.dumps({"type": event_type, **payload}, ensure_ascii=True), flush=True)
        elif event_type == "stage":
            print(str(payload.get("message", "")), flush=True)
        elif event_type in {"chunk", "progress"}:
            print(
                f"Chunk {payload.get('current', '?')}/{payload.get('total', '?')}",
                flush=True,
            )


def synthesize(
    text: str,
    voice: str,
    lang: str,
    speed: float,
    chunk_output_dir: Path | None = None,
    reporter: ProgressReporter | None = None,
) -> tuple[np.ndarray, int]:
    kokoro = build_kokoro()
    chunks = split_into_chunks(text, tokenizer=kokoro.tokenizer, lang=lang)
    if not chunks:
        raise RuntimeError("No text remained after chunking.")

    rendered: list[np.ndarray] = []
    sample_rate: int | None = None
    buffered_seconds = 0.0

    if chunk_output_dir is not None:
        chunk_output_dir.mkdir(parents=True, exist_ok=True)

    total = len(chunks)
    if reporter:
        reporter.emit("stage", name="synthesizing", message=f"Rendering {total} audio chunks", total=total)
    else:
        print(f"Rendering {total} audio chunks...", flush=True)
    for index, chunk in enumerate(chunks, start=1):
        if reporter:
            reporter.emit("progress", current=index, total=total, characters=len(chunk), stage="synthesizing")
        else:
            print(f"Chunk {index}/{total}", flush=True)
        try:
            samples, current_rate = kokoro.create(chunk, voice=voice, speed=speed, lang=lang)
        except Exception:
            decomposed_chunk = decompose_for_tts(chunk)
            samples, current_rate = kokoro.create(decomposed_chunk, voice=voice, speed=speed, lang=lang)
        if sample_rate is None:
            sample_rate = current_rate
        elif current_rate != sample_rate:
            raise RuntimeError(
                f"Unexpected sample-rate change: {sample_rate} vs {current_rate}"
            )
        if index < total:
            silence = np.zeros(int(current_rate * 0.18), dtype=np.float32)
            chunk_audio = np.concatenate((samples, silence))
        else:
            chunk_audio = samples
        rendered.append(chunk_audio)
        buffered_seconds += len(chunk_audio) / current_rate

        if chunk_output_dir is not None:
            chunk_path = chunk_output_dir / f"{index:04d}.wav"
            sf.write(chunk_path, chunk_audio, current_rate)
            if reporter:
                reporter.emit(
                    "chunk_ready",
                    current=index,
                    total=total,
                    chunk_path=str(chunk_path),
                    chunk_seconds=round(len(chunk_audio) / current_rate, 3),
                    buffered_seconds=round(buffered_seconds, 3),
                    sample_rate=current_rate,
                )

    if sample_rate is None:
        raise RuntimeError("Kokoro did not return audio.")

    audio = np.concatenate(rendered)
    return audio, sample_rate


def play_audio(path: Path) -> None:
    commands = [
        ["afplay", str(path)],
        ["ffplay", "-nodisp", "-autoexit", "-loglevel", "error", str(path)],
    ]
    errors: list[str] = []

    for command in commands:
        try:
            subprocess.run(command, check=True)
            return
        except FileNotFoundError:
            errors.append(f"{command[0]} not found")
        except subprocess.CalledProcessError as exc:
            errors.append(f"{command[0]} exited with {exc.returncode}")

    raise RuntimeError("Playback failed: " + "; ".join(errors))


def output_paths(output_dir: Path, title: str) -> tuple[Path, Path]:
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    stem = f"{timestamp}-{slugify(title)}"
    return output_dir / f"{stem}.txt", output_dir / f"{stem}.wav"


def ensure_job_paths(output_dir: Path, job_id: str) -> dict[str, Path]:
    job_dir = output_dir / "jobs" / job_id
    job_dir.mkdir(parents=True, exist_ok=True)
    return {
        "job_dir": job_dir,
        "chunks_dir": job_dir / "chunks",
        "manifest_path": job_dir / "manifest.json",
        "input_path": job_dir / "input.txt",
        "text_path": job_dir / "cleaned.txt",
        "audio_path": job_dir / "audio.wav",
        "error_path": job_dir / "error.txt",
    }


def write_manifest(path: Path, payload: dict[str, object]) -> None:
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")


def write_error_details(path: Path, exc: Exception, *, job_id: str, title: str, source_kind: str) -> None:
    timestamp = datetime.now().isoformat()
    payload = (
        f"timestamp: {timestamp}\n"
        f"job_id: {job_id}\n"
        f"title: {title}\n"
        f"source_kind: {source_kind}\n"
        f"error_type: {type(exc).__name__}\n"
        f"error: {exc}\n\n"
        "traceback:\n"
        f"{traceback.format_exc()}"
    )
    path.write_text(payload, encoding="utf-8")


def looks_like_url(value: str) -> bool:
    return value.startswith("http://") or value.startswith("https://")


def resolve_input(
    args: argparse.Namespace,
    reporter: ProgressReporter | None = None,
) -> tuple[str, str, str, str]:
    if args.text:
        text = clean_text(args.text)
        return args.title or derive_title_from_text(text), text, "text", args.text

    if args.text_file:
        raw = args.text_file.read_text(encoding="utf-8")
        text = clean_text(raw)
        return args.title or derive_title_from_text(text), text, "text-file", str(args.text_file)

    if args.stdin or (not sys.stdin.isatty() and not args.source):
        raw = sys.stdin.read()
        text = clean_text(raw)
        if not text:
            raise RuntimeError("No text was provided on stdin.")
        return args.title or derive_title_from_text(text), text, "stdin", raw

    if not args.source:
        raise RuntimeError("Provide a URL, --text, --text-file, or pipe text on stdin.")

    if looks_like_url(args.source):
        if reporter:
            reporter.emit("stage", name="fetching_url", message="Fetching article URL")
        html = fetch_html(args.source)
        if reporter:
            reporter.emit("stage", name="extracting_article", message="Extracting article text")
        title, article_text = extract_article(args.source, html)
        return args.title or title, article_text, "url", args.source

    text = clean_text(args.source)
    return args.title or derive_title_from_text(text), text, "text", args.source


def list_voices() -> int:
    kokoro = build_kokoro()
    for voice in kokoro.get_voices():
        print(voice)
    return 0


def list_voices_json() -> int:
    kokoro = build_kokoro()
    print(json.dumps({"voices": kokoro.get_voices()}, ensure_ascii=True))
    return 0


def format_duration(seconds: float) -> str:
    if seconds < 60:
        return f"{seconds:.1f}s"
    minutes = int(seconds // 60)
    remaining = seconds - (minutes * 60)
    return f"{minutes}m {remaining:.1f}s"


def make_voice_preview(args: argparse.Namespace, reporter: ProgressReporter) -> int:
    kokoro = build_kokoro()
    voices = kokoro.get_voices()
    preview_dir = args.output_dir / "previews"
    preview_dir.mkdir(parents=True, exist_ok=True)

    stem = f"all-voices-{slugify(args.preview_text[:80])}"
    wav_path = preview_dir / f"{stem}.wav"
    manifest_path = preview_dir / f"{stem}.json"
    index_path = preview_dir / f"{stem}.txt"

    reporter.emit(
        "stage",
        name="preview_all_voices",
        message=f"Rendering preview for {len(voices)} voices",
        total=len(voices),
    )

    audio_parts: list[np.ndarray] = []
    sample_rate: int | None = None
    offsets: list[dict[str, object]] = []
    cursor_seconds = 0.0

    for index, voice in enumerate(voices, start=1):
        reporter.emit("progress", current=index, total=len(voices), voice=voice, stage="preview_all_voices")
        prompt = preview_prompt_for_voice(voice, args.preview_text)
        preview_lang = preview_language_for_voice(voice, prompt)
        samples, current_rate = kokoro.create(prompt, voice=voice, speed=args.speed, lang=preview_lang)
        if sample_rate is None:
            sample_rate = current_rate
        elif sample_rate != current_rate:
            raise RuntimeError(f"Unexpected sample-rate change: {sample_rate} vs {current_rate}")

        silence = np.zeros(int(current_rate * 0.45), dtype=np.float32)
        duration_seconds = len(samples) / current_rate
        offsets.append(
            {
                "voice": voice,
                "start_seconds": round(cursor_seconds, 3),
                "duration_seconds": round(duration_seconds, 3),
            }
        )
        audio_parts.append(samples)
        audio_parts.append(silence)
        cursor_seconds += duration_seconds + (len(silence) / current_rate)

    if sample_rate is None:
        raise RuntimeError("No preview audio was generated.")

    sf.write(wav_path, np.concatenate(audio_parts), sample_rate)
    write_manifest(
        manifest_path,
        {
            "kind": "voice-preview",
            "preview_text": args.preview_text,
            "prompt_template": "This is {voice}. {preview_text}",
            "voice_count": len(voices),
            "audio_path": str(wav_path),
            "index": offsets,
        },
    )
    index_path.write_text(
        "\n".join(
            f"{item['voice']}\t{item['start_seconds']}s\t{item['duration_seconds']}s"
            for item in offsets
        ) + "\n",
        encoding="utf-8",
    )

    reporter.emit(
        "result",
        kind="voice-preview",
        audio_path=str(wav_path),
        manifest_path=str(manifest_path),
        index_path=str(index_path),
    )
    if not args.json_events and not args.json_progress:
        print(f"Preview audio: {wav_path}")
        print(f"Preview index: {index_path}")
    return 0


def main() -> int:
    args = parse_args()
    args.speed = clamp_speed(args.speed)
    json_mode = args.json_events or args.json_progress
    reporter = ProgressReporter(json_mode)

    if args.list_voices:
        return list_voices()

    if args.list_voices_json:
        return list_voices_json()

    if args.preview_all_voices:
        require_models()
        args.output_dir.mkdir(parents=True, exist_ok=True)
        return make_voice_preview(args, reporter)

    require_models()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    total_start = time.perf_counter()
    input_elapsed = 0.0
    synth_elapsed = 0.0
    title = args.title or "untitled"
    metadata_summary = ""
    metadata_tags: list[str] = []
    metadata_model_used = ""
    resolved_lang = args.lang
    resolved_voice = args.voice
    language_detection: dict[str, object] = {"mode": "manual", "reason": "Language routing not evaluated yet."}
    source_kind = ""
    source_value = ""
    job_id = args.job_id or f"{datetime.now().strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:8]}"
    job_paths = ensure_job_paths(args.output_dir, job_id)
    manifest_path = job_paths["manifest_path"]

    try:
        input_start = time.perf_counter()
        reporter.emit("stage", name="input", message="Preparing input", job_id=job_id)
        title, article_text, source_kind, source_value = resolve_input(args, reporter=reporter)
        input_elapsed = time.perf_counter() - input_start
        resolved_lang, resolved_voice, language_detection = resolve_language_and_voice(
            article_text,
            args.lang,
            args.voice,
        )
        reporter.emit(
            "stage",
            name="language_routing",
            message=f"Resolved language {resolved_lang} with voice {resolved_voice}",
            job_id=job_id,
            requested_lang=args.lang,
            requested_voice=args.voice,
            resolved_lang=resolved_lang,
            resolved_voice=resolved_voice,
            language_detection=language_detection,
        )

        if args.metadata_only:
            metadata = generate_title_metadata(
                article_text,
                source_kind=source_kind,
                title_hint=title,
                base_url=args.metadata_base_url,
                model=args.metadata_model,
                identifier=args.metadata_identifier,
                context_length=args.metadata_context_length,
                ttl_seconds=args.metadata_ttl,
                lms_bin=args.lms_bin,
                timeout_seconds=args.metadata_timeout,
            )
            if json_mode:
                reporter.emit(
                    "result",
                    kind="metadata",
                    title=str(metadata["summary_name"]),
                    metadata_summary=str(metadata["summary"]),
                    metadata_tags=sanitize_tags(metadata["tags"]),
                    metadata_model=str(metadata["model"]),
                )
            else:
                print(json.dumps(metadata, ensure_ascii=True, indent=2))
            return 0

        reporter.emit("stage", name="writing_text", message="Writing extracted text", job_id=job_id)
        job_paths["input_path"].write_text(source_value, encoding="utf-8")
        job_paths["text_path"].write_text(article_text, encoding="utf-8")

        metadata_future: concurrent.futures.Future[dict[str, object]] | None = None
        if not args.no_metadata:
            reporter.emit("stage", name="metadata", message="Generating local title metadata", job_id=job_id)
            metadata_executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)
            metadata_future = metadata_executor.submit(
                generate_title_metadata,
                article_text,
                source_kind=source_kind,
                title_hint=title,
                base_url=args.metadata_base_url,
                model=args.metadata_model,
                identifier=args.metadata_identifier,
                context_length=args.metadata_context_length,
                ttl_seconds=args.metadata_ttl,
                lms_bin=args.lms_bin,
                timeout_seconds=args.metadata_timeout,
            )
        else:
            metadata_executor = None

        synth_start = time.perf_counter()
        audio, sample_rate = synthesize(
            article_text,
            resolved_voice,
            resolved_lang,
            args.speed,
            chunk_output_dir=job_paths["chunks_dir"] if args.stream_chunks else None,
            reporter=reporter,
        )
        synth_elapsed = time.perf_counter() - synth_start

        final_title = title
        try:
            if metadata_future is not None:
                metadata = metadata_future.result(timeout=max(args.metadata_timeout, 1.0))
                final_title = str(metadata.get("summary_name", final_title)) or final_title
                metadata_summary = str(metadata.get("summary", "")).strip()
                metadata_tags = sanitize_tags(metadata.get("tags", []))
                metadata_model_used = str(metadata.get("model", "")).strip()
                reporter.emit("stage", name="metadata_ready", message=f"Metadata title: {final_title}", job_id=job_id)
        except Exception as exc:
            reporter.emit("stage", name="metadata_fallback", message=f"Metadata fallback: {exc}", job_id=job_id)
        finally:
            if metadata_executor is not None:
                metadata_executor.shutdown(wait=False)

        artifact_paths = build_named_artifact_paths(job_paths["job_dir"], final_title)
        reporter.emit("stage", name="writing_audio", message="Writing audio file", job_id=job_id)
        artifact_paths["text_path"].write_text(article_text, encoding="utf-8")
        sf.write(artifact_paths["audio_path"], audio, sample_rate)
        total_elapsed = time.perf_counter() - total_start

        manifest = {
            "kind": "job",
            "job_id": job_id,
            "status": "completed",
            "title": final_title,
            "source_kind": source_kind,
            "source_value": source_value,
            "voice": resolved_voice,
            "requested_voice": args.voice,
            "lang": resolved_lang,
            "requested_lang": args.lang,
            "speed": args.speed,
            "language_detection": language_detection,
            "metadata_summary": metadata_summary,
            "metadata_tags": metadata_tags,
            "metadata_model": metadata_model_used,
            "job_dir": str(job_paths["job_dir"]),
            "chunks_dir": str(job_paths["chunks_dir"]) if args.stream_chunks else "",
            "input_path": str(job_paths["input_path"]),
            "text_path": str(artifact_paths["text_path"]),
            "audio_path": str(artifact_paths["audio_path"]),
            "created_at": datetime.now().isoformat(),
            "timings": {
                "input_seconds": round(input_elapsed, 3),
                "render_seconds": round(synth_elapsed, 3),
                "total_seconds": round(total_elapsed, 3),
            },
        }
        write_manifest(manifest_path, manifest)

        if json_mode:
            reporter.emit(
                "result",
                kind="job",
                status="completed",
                job_id=job_id,
                title=final_title,
                job_dir=str(job_paths["job_dir"]),
                manifest_path=str(manifest_path),
                chunks_dir=str(job_paths["chunks_dir"]) if args.stream_chunks else None,
                text_path=str(artifact_paths["text_path"]),
                audio_path=str(artifact_paths["audio_path"]),
                voice=resolved_voice,
                requested_voice=args.voice,
                lang=resolved_lang,
                requested_lang=args.lang,
                language_detection=language_detection,
                metadata_summary=metadata_summary,
                metadata_tags=metadata_tags,
                metadata_model=metadata_model_used,
                input_prep_seconds=round(input_elapsed, 3),
                tts_render_seconds=round(synth_elapsed, 3),
                total_seconds=round(total_elapsed, 3),
            )
        else:
            print(f"Title: {final_title}")
            print(f"Text: {artifact_paths['text_path']}")
            print(f"Audio: {artifact_paths['audio_path']}")
            print(f"Job dir: {job_paths['job_dir']}")
            print(f"Input prep: {format_duration(input_elapsed)}")
            print(f"TTS render: {format_duration(synth_elapsed)}")
            print(f"Total: {format_duration(total_elapsed)}")

        if not args.no_play:
            reporter.emit("stage", name="playback", message="Playing audio", job_id=job_id)
            play_audio(artifact_paths["audio_path"])

        return 0
    except Exception as exc:
        total_elapsed = time.perf_counter() - total_start
        write_error_details(
            job_paths["error_path"],
            exc,
            job_id=job_id,
            title=title,
            source_kind=source_kind,
        )
        write_manifest(
            manifest_path,
            {
                "kind": "job",
                "job_id": job_id,
                "status": "failed",
                "title": title,
                "source_kind": source_kind,
                "source_value": source_value,
                "voice": resolved_voice,
                "requested_voice": args.voice,
                "lang": resolved_lang,
                "requested_lang": args.lang,
                "speed": args.speed,
                "language_detection": language_detection,
                "metadata_summary": metadata_summary,
                "metadata_tags": metadata_tags,
                "metadata_model": metadata_model_used,
                "job_dir": str(job_paths["job_dir"]),
                "chunks_dir": str(job_paths["chunks_dir"]) if args.stream_chunks else "",
                "input_path": str(job_paths["input_path"]),
                "text_path": str(job_paths["text_path"]),
                "audio_path": str(job_paths["audio_path"]),
                "error_path": str(job_paths["error_path"]),
                "error": str(exc),
                "created_at": datetime.now().isoformat(),
                "timings": {
                    "input_seconds": round(input_elapsed, 3),
                    "render_seconds": round(synth_elapsed, 3),
                    "total_seconds": round(total_elapsed, 3),
                },
            },
        )
        reporter.emit(
            "error",
            job_id=job_id,
            manifest_path=str(manifest_path),
            chunks_dir=str(job_paths["chunks_dir"]) if args.stream_chunks else None,
            error_path=str(job_paths["error_path"]),
            message=str(exc),
        )
        raise


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        if "--json-progress" in sys.argv or "--json-events" in sys.argv:
            print(json.dumps({"type": "error", "message": str(exc)}, ensure_ascii=True), flush=True)
        else:
            print(f"Error: {exc}", file=sys.stderr)
        raise SystemExit(1)
    except KeyboardInterrupt:
        print("Interrupted.", file=sys.stderr)
        raise SystemExit(130)
