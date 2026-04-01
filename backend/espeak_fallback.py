"""
espeak-ng OOV (out-of-vocabulary) word fallback for Kokoro TTS.

When Kokoro encounters a word not in its lexicon, this module provides
phoneme generation via espeak-ng with E2M (espeak-to-misaki/Kokoro) mapping.

Integration note: kokoro-onnx handles G2P internally in its create() method.
Full integration with kokoro-onnx's G2P pipeline will require further
investigation to determine the best hook point.
"""

from __future__ import annotations

import shutil
import subprocess
from typing import Optional

# E2M_MAPPING: maps espeak IPA characters/sequences to Kokoro phoneme format
E2M_MAPPING: dict[str, str] = {
    # Affricates
    "dʒ": "ʤ",
    "tʃ": "ʧ",
    # Diphthongs
    "aɪ": "I",
    "aʊ": "W",
    "eɪ": "A",
    "oʊ": "O",
    "ɔɪ": "Y",
    # Vowel modifications
    "ɜːɹ": "ɜɹ",
    # Flap
    "ɾ": "T",
    # Glottal stop
    "ʔ": "t",
    # US-specific: collapse diphthongs
    "ɪə": "iə",
}

# Characters that should be stripped entirely (length marks, etc)
STRIP_CHARS: set[str] = {"ː"}


def _apply_e2m_mapping(ipa: str) -> str:
    """Apply E2M mapping to convert espeak IPA to Kokoro phonemes."""
    result = ipa

    # Apply multi-character replacements first (longer sequences before shorter)
    multi_char_map = {
        "dʒ": "ʤ",
        "tʃ": "ʧ",
        "aɪ": "I",
        "aʊ": "W",
        "eɪ": "A",
        "oʊ": "O",
        "ɔɪ": "Y",
        "ɜːɹ": "ɜɹ",
        "ɪə": "iə",
    }

    for espeak, kokoro in multi_char_map.items():
        result = result.replace(espeak, kokoro)

    # Remove strip characters (length marks)
    result = "".join(c for c in result if c not in STRIP_CHARS)

    # Single character replacements
    single_char_map = {
        "ɾ": "T",
        "ʔ": "t",
    }

    for espeak, kokoro in single_char_map.items():
        result = result.replace(espeak, kokoro)

    return result


def _check_espeak_installed() -> bool:
    """Check if espeak-ng is installed and available."""
    return shutil.which("espeak-ng") is not None


def espeak_phonemes(word: str) -> str:
    """
    Generate Kokoro-format phonemes for a word using espeak-ng.

    Calls: espeak-ng --ipa -q -v en-us --tie=^ <word>

    Args:
        word: The word to phonemize.

    Returns:
        Kokoro-format phoneme string, or empty string if espeak-ng is unavailable.

    Note:
        The --tie=^ option prevents espeak-ng from concatenating output
        when processing individual words.
    """
    if not _check_espeak_installed():
        return ""

    try:
        result = subprocess.run(
            ["espeak-ng", "--ipa", "-q", "-v", "en-us", "--tie=^", word],
            capture_output=True,
            text=True,
            check=True,
            timeout=5,
        )
        ipa = result.stdout.strip()
        return _apply_e2m_mapping(ipa)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError):
        return ""


def oov_fallback(word: str) -> str:
    """
    Return Kokoro phonemes for an out-of-vocabulary word.

    This is the main entry point for OOV word handling. It attempts to
    generate phonemes using espeak-ng and falls back gracefully if
    espeak-ng is not installed.

    Args:
        word: The unknown word to phonemize.

    Returns:
        Kokoro-format phoneme string, or the original word if generation fails.
        Returns empty string if espeak-ng is not available.
    """
    phonemes = espeak_phonemes(word)
    return phonemes


# Module-level check for espeak-ng availability
ESPEAK_AVAILABLE: bool = _check_espeak_installed()