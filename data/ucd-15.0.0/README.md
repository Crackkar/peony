# Unicode 15.0.0 source inputs

These files are pinned inputs for [`tools/gen_unicode.mjs`](../../tools/gen_unicode.mjs). Four files come from the [Unicode 15.0.0 UCD directory](https://www.unicode.org/Public/15.0.0/ucd/); `Unihan_NumericValues.txt` is extracted from that release's [Unihan.zip](https://www.unicode.org/Public/15.0.0/ucd/Unihan.zip). The generator checks every SHA-256 before deriving the table. It computes properties and mappings from these source files across all Unicode scalar values; it does not reconstruct its output from the committed binary.

| File | SHA-256 |
|---|---|
| `UnicodeData.txt` | `806e9aed65037197f1ec85e12be6e8cd870fc5608b4de0fffd990f689f376a73` |
| `DerivedCoreProperties.txt` | `d367290bc0867e6b484c68370530bdd1a08b6b32404601b8c7accaf83e05628d` |
| `SpecialCasing.txt` | `78b29c64b5840d25c11a9f31b665ee551b8a499eca6c70d770fcad7dd710f494` |
| `CaseFolding.txt` | `cdd49e55eae3bbf1f0a3f6580c974a0263cb86a6a08daa10fbf705b4808a56f7` |
| `Unihan_NumericValues.txt` | `42289ff99564cf17c3c95938744c2f690452b704a6d076d5372c4571c3cb14f6` |

Run `node tools/gen_unicode.mjs --check` to regenerate in memory and compare with `data/unicode-15.0.bin`. Its expected output SHA-256 is `10a4fd50df393d992424d2102e48e39c58dc6449a7a9cae0dcc5708683848019` (237,028 bytes). `node tools/generate_unicode15_probe.mjs` derives the size probe from that verified table. Both tracked tools are Node programs; no Python generator is required.
