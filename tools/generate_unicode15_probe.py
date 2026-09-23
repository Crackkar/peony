#!/usr/bin/env python3
"""Generate the compact Unicode property prototype used only by the size probe."""

from __future__ import annotations

import argparse
import struct
import unicodedata
from pathlib import Path


UNICODE_VERSION = "15.0.0"
ALPHA = 1 << 0
DECIMAL = 1 << 1
DIGIT = 1 << 2
NUMERIC = 1 << 3
SPACE = 1 << 4
LOWER = 1 << 5
UPPER = 1 << 6
TITLE = 1 << 7


def property_flags(codepoint: int) -> int:
    char = chr(codepoint)
    flags = 0
    flags |= ALPHA if char.isalpha() else 0
    flags |= DECIMAL if char.isdecimal() else 0
    flags |= DIGIT if char.isdigit() else 0
    flags |= NUMERIC if char.isnumeric() else 0
    flags |= SPACE if char.isspace() else 0
    flags |= LOWER if char.islower() else 0
    flags |= UPPER if char.isupper() else 0
    flags |= TITLE if char.istitle() else 0
    return flags


def build_blob() -> bytes:
    if unicodedata.unidata_version != UNICODE_VERSION:
        raise SystemExit(
            f"expected Unicode {UNICODE_VERSION}; Python provides {unicodedata.unidata_version}"
        )

    ranges: list[tuple[int, int, int]] = []
    start: int | None = None
    previous = -1
    previous_flags = 0
    mappings: list[tuple[int, bytes, bytes]] = []

    for codepoint in range(0x110000):
        if 0xD800 <= codepoint <= 0xDFFF:
            flags = 0
        else:
            char = chr(codepoint)
            flags = property_flags(codepoint)
            lower = char.lower().encode("utf-8")
            upper = char.upper().encode("utf-8")
            if lower != char.encode("utf-8") or upper != char.encode("utf-8"):
                mappings.append((codepoint, lower, upper))

        if flags and start is not None and flags == previous_flags and codepoint == previous + 1:
            previous = codepoint
            continue
        if start is not None:
            ranges.append((start, previous, previous_flags))
        if flags:
            start = previous = codepoint
            previous_flags = flags
        else:
            start = None
            previous = codepoint
            previous_flags = 0

    if start is not None:
        ranges.append((start, previous, previous_flags))

    blob = bytearray(b"PEONY-U15")
    blob.extend(struct.pack("<II", len(ranges), len(mappings)))
    for first, last, flags in ranges:
        blob.extend(struct.pack("<IIB", first, last, flags))
    for codepoint, lower, upper in mappings:
        blob.extend(struct.pack("<IBB", codepoint, len(lower), len(upper)))
        blob.extend(lower)
        blob.extend(upper)
    return bytes(blob)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(build_blob())
    print(f"Unicode {UNICODE_VERSION} prototype: {args.output.stat().st_size} bytes")


if __name__ == "__main__":
    main()
