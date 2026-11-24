# Anki import fixtures (#1383)

`basic.apkg`, `basic_v2.apkg`, `both.apkg`, `anki21b_only.apkg` and
`../cards.csv` are built by `python3 scripts/make_anki_fixtures.py`
(standard library only). Run it again after changing the script; the tests in
`test/unit/import/` depend on the content.
