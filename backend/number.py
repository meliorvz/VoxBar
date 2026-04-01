from __future__ import annotations

import re
from typing import Literal

ONES: tuple[str, ...] = (
    "zero", "one", "two", "three", "four",
    "five", "six", "seven", "eight", "nine",
    "ten", "eleven", "twelve", "thirteen", "fourteen",
    "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
)

TENS: tuple[str, ...] = (
    "", "", "twenty", "thirty", "forty",
    "fifty", "sixty", "seventy", "eighty", "ninety",
)

THOUSANDS: tuple[str, ...] = (
    "", "thousand", "million", "billion", "trillion",
    "quadrillion", "quintillion",
)

CURRENCY_SYMBOLS: dict[str, str] = {
    "$": "dollars",
    "£": "pounds",
    "€": "euros",
}


def _cardinal_0_to_999(n: int) -> str:
    if n < 20:
        return ONES[n]
    if n < 100:
        tens_digit = n // 10
        ones_digit = n % 10
        tens_word = TENS[tens_digit]
        if ones_digit == 0:
            return tens_word
        return f"{tens_word} {ONES[ones_digit]}"
    hundreds_digit = n // 100
    remainder = n % 100
    hundreds_word = f"{ONES[hundreds_digit]} hundred"
    if remainder == 0:
        return hundreds_word
    return f"{hundreds_word} {_cardinal_0_to_999(remainder)}"


def cardinal(n: int) -> str:
    if n < 0:
        return f"minus {cardinal(-n)}"
    if n == 0:
        return "zero"
    parts: list[str] = []
    chunk_index = 0
    while n > 0:
        chunk = n % 1000
        if chunk != 0:
            chunk_word = _cardinal_0_to_999(chunk)
            if THOUSANDS[chunk_index]:
                chunk_word = f"{chunk_word} {THOUSANDS[chunk_index]}"
            parts.append(chunk_word)
        n //= 1000
        chunk_index += 1
    return " ".join(reversed(parts))


def _parse_currency(text: str) -> tuple[Literal["$", "£", "€"] | None, str]:
    if not text:
        return None, text
    if text[0] in CURRENCY_SYMBOLS:
        return text[0], text[1:]
    return None, text


def currency_to_words(text: str) -> str:
    symbol, remaining = _parse_currency(text)
    if symbol is None:
        return text

    if "." in remaining:
        dollar_part, cent_part = remaining.split(".", 1)
    else:
        dollar_part = remaining
        cent_part = ""

    dollar_amount = 0
    if dollar_part:
        try:
            dollar_amount = int(dollar_part)
        except ValueError:
            return text

    cents_word = ""
    if cent_part:
        try:
            cent_amount = int(cent_part.ljust(2, "0")[:2])
            cents_word = cardinal(cent_amount)
        except ValueError:
            return text

    parts: list[str] = []

    if dollar_amount == 0 and cent_part:
        parts.append(f"{cents_word} cents")
    elif dollar_amount > 0:
        dollars_word = cardinal(dollar_amount)
        parts.append(f"{dollars_word} {CURRENCY_SYMBOLS[symbol]}")
        if cent_part:
            parts.append(f"{cents_word} cents")
    else:
        return text

    return " ".join(parts)


def number_to_words(text: str) -> str:
    """Convert a number string to words. Handles integers, decimals, commas."""
    original = text
    text = text.strip()

    # Handle trailing period (sentence-ending punctuation, not decimal)
    trailing_period = False
    if text.endswith("."):
        trailing_period = True
        text = text[:-1]

    # Handle negative
    negative = False
    if text.startswith("-"):
        negative = True
        text = text[1:]

    # Handle decimal
    if "." in text and text.replace(".", "", 1).replace(",", "").isdigit():
        parts = text.split(".", 1)
        integer_part = parts[0].replace(",", "")
        fractional_part = parts[1] if len(parts) > 1 else ""

        result_parts = []
        if integer_part and integer_part != "-":
            try:
                result_parts.append(cardinal(int(integer_part)))
            except ValueError:
                result_parts.append(integer_part)

        if fractional_part:
            digit_words = [ONES[int(d)] for d in fractional_part if d.isdigit()]
            if digit_words:
                result_parts.append("point")
                result_parts.extend(digit_words)

        result = " ".join(result_parts)
        if negative:
            result = f"minus {result}"
        if trailing_period:
            result += "."
        return result

    # Handle comma-separated (e.g., 1,000)
    text = text.replace(",", "")

    if not text or text == "-":
        return original

    try:
        result = cardinal(int(text))
    except ValueError:
        return original

    if negative:
        result = f"minus {result}"
    if trailing_period:
        result += "."
    return result


def ordinal(n: int) -> str:
    """Convert an integer to ordinal words (1 -> first, 2 -> second, etc.)."""
    if n < 0:
        return f"minus {ordinal(-n)}"

    # Irregular ordinals
    IRREGULAR_ORDINALS: dict[int, str] = {
        1: "first",
        2: "second",
        3: "third",
        4: "fourth",
        5: "fifth",
        6: "sixth",
        7: "seventh",
        8: "eighth",
        9: "ninth",
        10: "tenth",
        11: "eleventh",
        12: "twelfth",
        13: "thirteenth",
        14: "fourteenth",
        15: "fifteenth",
        16: "sixteenth",
        17: "seventeenth",
        18: "eighteenth",
        19: "nineteenth",
        20: "twentieth",
        30: "thirtieth",
        40: "fortieth",
        50: "fiftieth",
        60: "sixtieth",
        70: "seventieth",
        80: "eightieth",
        90: "ninetieth",
    }

    if n in IRREGULAR_ORDINALS:
        return IRREGULAR_ORDINALS[n]

    tens_digit = (n // 10) * 10
    ones_digit = n % 10
    if tens_digit == 0:
        tens_word = ONES[ones_digit]
    else:
        tens_word = f"{TENS[tens_digit // 10]}-"
    return f"{tens_word}{IRREGULAR_ORDINALS[ones_digit]}"


def ordinal_to_words(text: str) -> str:
    """Convert ordinal number string (e.g., '1st', '3rd', '22nd') to words."""
    text = text.strip()
    m = re.match(r"^(\-?\d+)(st|nd|rd|th)$", text, re.IGNORECASE)
    if not m:
        return text
    num = int(m.group(1))
    return ordinal(num)


def year_to_words(n: int) -> str:
    """Convert a year to spoken words."""
    if n < 0:
        return f"minus {year_to_words(-n)}"
    if n == 0:
        return "zero"

    if n < 1000:
        return cardinal(n)

    # Special cases for years
    if n == 2000:
        return "two thousand"
    if n == 2001:
        return "twenty oh one"
    if n == 2008:
        return "twenty oh eight"

    # Four-digit years: split into two parts
    first_part = n // 100
    second_part = n % 100

    first_word = cardinal(first_part)

    if second_part == 0:
        return first_word
    if second_part < 10:
        # 1905 -> nineteen oh five
        return f"{first_word} oh {ONES[second_part]}"
    if second_part < 20:
        # 1919 -> nineteen nineteen
        return f"{first_word} {ordinal(second_part)}"

    tens_word = TENS[second_part // 10]
    ones_word = ONES[second_part % 10]
    return f"{first_word} {tens_word} {ones_word}"