# Anki import fixtures (#1383)

`basic.apkg`, `basic_v2.apkg`, `both.apkg`, `basic_21b.apkg`,
`anki21b_corrupt.apkg`, `reviews.apkg` and `../cards.csv` are built by
`python3 scripts/make_anki_fixtures.py` (standard library only). Run it again
after changing the script; the tests in `test/unit/import/` depend on the
content.

`basic_21b.apkg` is the twin of `basic.apkg` in the format of newer Anki
versions (#1384): a dummy `collection.anki2`, the schema 18
`collection.anki21b`, `meta` = LATEST, and the protobuf `media` map, all
zstd-compressed. Python has no zstd module, so its zstd frames hold raw
(stored) blocks; `anki_apkg_reader_test.dart` re-encodes them with
compressed blocks. `anki21b_corrupt.apkg` holds a truncated zstd frame. None
of the fixtures is an export of a real Anki yet.
