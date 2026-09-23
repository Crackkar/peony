#!/usr/bin/env python3
"""Build the checked-in Unicode 15.0.0 runtime tables from Python's pinned UCD."""

from __future__ import annotations

import argparse
import hashlib
import struct
import sys
import unicodedata
from pathlib import Path


VERSION = "15.0.0"
MAGIC = b"PEONYU15"
VERSION_BYTES = VERSION.encode("ascii")
RANGE = struct.Struct("<IIH")
MAPPING_HEAD = struct.Struct("<I")
MAPPING_MAP = struct.Struct("<B3I")
SIMPLE = struct.Struct("<I")
RANGE_FLAGS = {
    "alphabetic": 1 << 0,
    "alnum": 1 << 1,
    "decimal": 1 << 2,
    "digit": 1 << 3,
    "numeric": 1 << 4,
    "whitespace": 1 << 5,
    "lower": 1 << 6,
    "upper": 1 << 7,
    "title": 1 << 8,
    "cased": 1 << 9,
    "case_ignorable": 1 << 10,
    "title_ignorable": 1 << 11,
}
CASE_IGNORABLE_WORD_BREAK = {
    0x0027, 0x00AD, 0x00B7, 0x0387, 0x05F4, 0x2019, 0x2027,
    0xFE13, 0xFE55, 0xFF07, 0xFF1A, 0xFF65,
}
IGNORABLE_CATEGORIES = {"Mn", "Me", "Cf", "Lm", "Sk"}


def codepoints(text: str) -> tuple[int, ...]:
    return tuple(map(ord, text))


def full_mapping(character: str, operation: str) -> tuple[int, ...]:
    mapped = codepoints(getattr(character, operation)())
    return () if mapped == (ord(character),) else mapped


def simple_mapping(cp: int, mapping: tuple[int, ...], operation: str) -> int:
    if len(mapping) == 1:
        return mapping[0]
    # UnicodeData's simple lowercase for dotted capital I is i; the full UCD
    # mapping expands to i + COMBINING DOT ABOVE.
    if cp == 0x0130 and operation == "lower":
        return 0x0069
    return cp


def simple_fold(cp: int, casefold: tuple[int, ...], lower: tuple[int, ...]) -> int:
    if len(casefold) == 1:
        return casefold[0]
    # For capital sharp S the full fold is "ss", while the simple fold is ß.
    if len(lower) == 1:
        return lower[0]
    return cp


def char_flags(cp: int, char: str) -> int:
    category = unicodedata.category(char)
    flags = 0
    flags |= RANGE_FLAGS["alphabetic"] if char.isalpha() else 0
    flags |= RANGE_FLAGS["alnum"] if char.isalnum() else 0
    flags |= RANGE_FLAGS["decimal"] if char.isdecimal() else 0
    flags |= RANGE_FLAGS["digit"] if char.isdigit() else 0
    flags |= RANGE_FLAGS["numeric"] if char.isnumeric() else 0
    flags |= RANGE_FLAGS["whitespace"] if char.isspace() else 0
    flags |= RANGE_FLAGS["lower"] if char.islower() else 0
    flags |= RANGE_FLAGS["upper"] if char.isupper() else 0
    flags |= RANGE_FLAGS["title"] if char.istitle() else 0
    if flags & (RANGE_FLAGS["lower"] | RANGE_FLAGS["upper"] | RANGE_FLAGS["title"]):
        flags |= RANGE_FLAGS["cased"]
    if category in IGNORABLE_CATEGORIES or cp in CASE_IGNORABLE_WORD_BREAK:
        flags |= RANGE_FLAGS["case_ignorable"]
    if category in IGNORABLE_CATEGORIES:
        flags |= RANGE_FLAGS["title_ignorable"]
    return flags


def build_blob() -> tuple[bytes, str]:
    if unicodedata.unidata_version != VERSION:
        raise RuntimeError(
            f"expected Unicode {VERSION}; Python provides {unicodedata.unidata_version}"
        )

    ranges: list[tuple[int, int, int]] = []
    mappings: list[bytes] = []
    input_digest = hashlib.sha256()
    range_start: int | None = None
    previous = -1
    previous_flags = 0

    for cp in range(0x110000):
        char = chr(cp)
        flags = char_flags(cp, char)
        full = (
            full_mapping(char, "lower"),
            full_mapping(char, "upper"),
            full_mapping(char, "title"),
            full_mapping(char, "casefold"),
        )
        simple = (
            simple_mapping(cp, full[0], "lower"),
            simple_mapping(cp, full[1], "upper"),
            simple_mapping(cp, full[2], "title"),
            simple_fold(cp, full[3], full[0]),
        )

        # Fingerprint the complete relevant UCD projection, including unchanged
        # scalars. This is stable across machines that expose the same UCD.
        row = bytearray(6 + 4 * (MAPPING_MAP.size + SIMPLE.size))
        struct.pack_into("<IH", row, 0, cp, flags)
        offset = 6
        for full_map, simple_map in zip(full, simple, strict=True):
            padded = (*full_map[:3], 0, 0, 0)[:3]
            MAPPING_MAP.pack_into(row, offset, len(full_map), *padded)
            offset += MAPPING_MAP.size
            SIMPLE.pack_into(row, offset, simple_map)
            offset += SIMPLE.size
        input_digest.update(row)

        if flags and range_start is not None and flags == previous_flags and cp == previous + 1:
            previous = cp
        else:
            if range_start is not None:
                ranges.append((range_start, previous, previous_flags))
            range_start = cp if flags else None
            previous = cp
            previous_flags = flags

        if any(full_map for full_map in full) or any(simple_map != cp for simple_map in simple):
            record = bytearray(MAPPING_HEAD.size + 4 * (MAPPING_MAP.size + SIMPLE.size))
            MAPPING_HEAD.pack_into(record, 0, cp)
            offset = MAPPING_HEAD.size
            for full_map, simple_map in zip(full, simple, strict=True):
                padded = (*full_map[:3], 0, 0, 0)[:3]
                MAPPING_MAP.pack_into(record, offset, len(full_map), *padded)
                offset += MAPPING_MAP.size
                SIMPLE.pack_into(record, offset, simple_map)
                offset += SIMPLE.size
            mappings.append(bytes(record))

    if range_start is not None:
        ranges.append((range_start, previous, previous_flags))

    input_hash = input_digest.digest()
    header = MAGIC + VERSION_BYTES + struct.pack("<II", len(ranges), len(mappings)) + input_hash
    blob = bytearray(header)
    for first, last, flags in ranges:
        blob.extend(RANGE.pack(first, last, flags))
    for record in mappings:
        blob.extend(record)
    return bytes(blob), input_digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "data" / "unicode-15.0.bin",
    )
    parser.add_argument("--check", action="store_true", help="verify the checked-in blob without writing")
    args = parser.parse_args()

    try:
        blob, input_hash = build_blob()
    except RuntimeError as error:
        print(error, file=sys.stderr)
        return 2

    output_hash = hashlib.sha256(blob).hexdigest()
    details = (
        f"Unicode {VERSION}; projection-sha256={input_hash}; "
        f"blob-sha256={output_hash}; bytes={len(blob)}"
    )
    if args.check:
        try:
            existing = args.output.read_bytes()
        except OSError as error:
            print(f"cannot read {args.output}: {error}", file=sys.stderr)
            return 2
        if existing != blob:
            print(f"Unicode blob does not match generator output: {args.output}", file=sys.stderr)
            print(details, file=sys.stderr)
            return 1
        print(f"match: {args.output} ({details})")
        return 0

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(blob)
    print(f"wrote: {args.output} ({details})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
