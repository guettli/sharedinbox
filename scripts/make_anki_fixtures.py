#!/usr/bin/env python3
"""Builds the Anki import fixtures of #1383 and #1385 in test/fixtures/anki/.

Standard library only (sqlite3, zipfile, json). The collections use the
legacy schema 11 (note types and decks as JSON in `col`), as Anki writes
into `collection.anki2` / `collection.anki21`.

Usage:
    python3 scripts/make_anki_fixtures.py

Writes basic.apkg, basic_v2.apkg, both.apkg, anki21b_only.apkg,
reviews.apkg and test/fixtures/cards.csv. The tests depend on their content: change both
together.
"""

import json
import os
import sqlite3
import tempfile
import zipfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
OUT = os.path.join(ROOT, 'test', 'fixtures', 'anki')

BASIC = 1001
REVERSED = 1002
CLOZE = 1003
DECK = 2001

# A 1x1 PNG.
CAT_PNG = bytes.fromhex(
    '89504e470d0a1a0a0000000d4948445200000001000000010806000000'
    '1f15c4890000000d49444154789c6360000002000001e221bc330000000049454e44ae426082'
)

_BACK = '{{FrontSide}}\n\n<hr id=answer>\n\n'


def _models():
    def fld(name, ord_):
        return {'name': name, 'ord': ord_, 'sticky': False, 'rtl': False,
                'font': 'Arial', 'size': 20}

    def tmpl(name, ord_, qfmt, afmt):
        return {'name': name, 'ord': ord_, 'qfmt': qfmt, 'afmt': afmt,
                'did': None, 'bqfmt': '', 'bafmt': ''}

    return {
        str(BASIC): {
            'id': BASIC, 'name': 'Basic', 'type': 0, 'did': DECK,
            'flds': [fld('Front', 0), fld('Back', 1)],
            'tmpls': [tmpl('Card 1', 0, '{{Front}}', _BACK + '{{Back}}')],
            'css': '.card {}', 'sortf': 0, 'tags': [], 'vers': [],
        },
        str(REVERSED): {
            'id': REVERSED, 'name': 'Basic (and reversed card)', 'type': 0,
            'did': DECK,
            'flds': [fld('Front', 0), fld('Back', 1)],
            'tmpls': [
                tmpl('Card 1', 0, '{{Front}}', _BACK + '{{Back}}'),
                tmpl('Card 2', 1, '{{Back}}', _BACK + '{{Front}}'),
            ],
            'css': '.card {}', 'sortf': 0, 'tags': [], 'vers': [],
        },
        str(CLOZE): {
            'id': CLOZE, 'name': 'Cloze', 'type': 1, 'did': DECK,
            'flds': [fld('Text', 0), fld('Back Extra', 1)],
            'tmpls': [tmpl('Cloze', 0, '{{cloze:Text}}',
                           '{{cloze:Text}}<br>{{Back Extra}}')],
            'css': '.card {}', 'sortf': 0, 'tags': [], 'vers': [],
        },
    }


def _decks():
    return {
        '1': {'id': 1, 'name': 'Default'},
        str(DECK): {'id': DECK, 'name': 'Lang::German'},
    }


# (guid, model, fields, tags)
NOTES = [
    ('basic-1', BASIC, ['Hund', 'dog<br>a pet'], ' animal noun '),
    ('basic-2', BASIC, ['Katze <img src="cat.png">', 'cat &amp; kitten'],
     ' animal '),
    ('basic-3', BASIC, ['<b>Haus</b>', 'house [sound:x.mp3]'], ''),
    ('rev-1', REVERSED, ['gut', 'good'], ' adjective '),
    ('rev-2', REVERSED, ['<i>schnell</i>', '<div>fast</div><div>quick</div>'],
     ' adjective '),
    ('cloze-1', CLOZE, ['{{c1::Berlin}} ist die Hauptstadt', ''], ' geo '),
]


# The review history fixture (#1385): `col.crt` and the revlog.
REVIEWS_CRT = 1700000000
REVIEW_NOTES = [
    ('rv-1', BASIC, ['eins', 'one'], ''),
    ('rv-2', BASIC, ['zwei', 'two'], ''),
    ('rv-3', BASIC, ['drei', 'three'], ''),
    ('rv-cloze', CLOZE, ['{{c1::vier}} ist vier', ''], ''),
]
_T0 = 1735689600000  # 2025-01-01T00:00:00Z
_MIN = 60 * 1000
_HOUR = 60 * _MIN
_DAY = 24 * _HOUR
# (id, cid, ease, ivl, time, type); cards 1-3 are rv-1..rv-3, 4 the cloze.
REVLOG = [
    # rv-1: learn, review, lapse, relearn, filtered, rescheduled.
    (_T0, 1, 3, -600, 5000, 0),
    (_T0 + 10 * _MIN, 1, 3, 1, 4000, 0),
    (_T0 + _DAY, 1, 3, 3, 3000, 1),
    (_T0 + 4 * _DAY, 1, 1, -600, 8000, 1),
    (_T0 + 4 * _DAY + 10 * _MIN, 1, 3, 1, 6000, 2),
    (_T0 + 5 * _DAY, 1, 4, 5, 2000, 3),
    (_T0 + 6 * _DAY, 1, 0, 10, 0, 5),
    # rv-2: two reviews, a reset, a review, a manual "set due", a review.
    (_T0 + _HOUR, 2, 2, -600, 7000, 0),
    (_T0 + 2 * _DAY, 2, 3, 2, 3000, 1),
    (_T0 + 3 * _DAY, 2, 0, 0, 0, 4),
    (_T0 + 3 * _DAY + _HOUR, 2, 3, -600, 4000, 0),
    (_T0 + 4 * _DAY + 1000, 2, 0, 5, 0, 4),
    (_T0 + 5 * _DAY + _HOUR, 2, 3, 1, 3000, 0),
    # rv-3: two reviews.
    (_T0 + 2 * _HOUR, 3, 3, -600, 2500, 0),
    (_T0 + 3 * _DAY + 2 * _HOUR, 3, 4, 4, 1500, 1),
    # The cloze card and a cid without a card.
    (_T0 + _DAY + _HOUR, 4, 3, -600, 3000, 0),
    (_T0 + _DAY + 2 * _HOUR, 99, 3, 1, 3000, 1),
]


def _collection(path, notes, decks=None, crt=0, revlog=()):
    db = sqlite3.connect(path)
    db.executescript('''
        CREATE TABLE col (id integer primary key, crt integer not null,
          mod integer not null, scm integer not null, ver integer not null,
          dty integer not null, usn integer not null, ls integer not null,
          conf text not null, models text not null, decks text not null,
          dconf text not null, tags text not null);
        CREATE TABLE notes (id integer primary key, guid text not null,
          mid integer not null, mod integer not null, usn integer not null,
          tags text not null, flds text not null, sfld integer not null,
          csum integer not null, flags integer not null, data text not null);
        CREATE TABLE cards (id integer primary key, nid integer not null,
          did integer not null, ord integer not null, mod integer not null,
          usn integer not null, type integer not null, queue integer not null,
          due integer not null, ivl integer not null, factor integer not null,
          reps integer not null, lapses integer not null, left integer not null,
          odue integer not null, odid integer not null, flags integer not null,
          data text not null);
        CREATE TABLE revlog (id integer primary key, cid integer not null,
          usn integer not null, ease integer not null, ivl integer not null,
          lastIvl integer not null, factor integer not null,
          time integer not null, type integer not null);
        CREATE TABLE graves (usn integer not null, oid integer not null,
          type integer not null);
    ''')
    models = _models()
    db.execute(
        'INSERT INTO col VALUES (1, ?, 0, 0, 11, 0, 0, 0, ?, ?, ?, ?, ?)',
        (crt, '{}', json.dumps(models), json.dumps(decks or _decks()), '{}',
         '{}'),
    )
    did = DECK if decks is None else int(next(iter(decks)))
    card_id = 1
    for i, (guid, mid, fields, tags) in enumerate(notes, start=1):
        db.execute(
            'INSERT INTO notes VALUES (?, ?, ?, 0, 0, ?, ?, ?, 0, 0, ?)',
            (i, guid, mid, tags, '\x1f'.join(fields), fields[0], ''),
        )
        for ord_ in range(len(models[str(mid)]['tmpls'])):
            db.execute(
                'INSERT INTO cards VALUES '
                '(?, ?, ?, ?, 0, 0, 0, 0, ?, 0, 0, 0, 0, 0, 0, 0, 0, ?)',
                (card_id, i, did, ord_, card_id, ''),
            )
            card_id += 1
    for id_, cid, ease, ivl, time, type_ in revlog:
        db.execute(
            'INSERT INTO revlog VALUES (?, ?, 0, ?, ?, 0, 2500, ?, ?)',
            (id_, cid, ease, ivl, time, type_),
        )
    db.commit()
    db.close()
    with open(path, 'rb') as f:
        return f.read()


def _collection_bytes(notes, decks=None, crt=0, revlog=()):
    with tempfile.TemporaryDirectory() as d:
        return _collection(os.path.join(d, 'c.db'), notes, decks, crt, revlog)


def _apkg(name, entries):
    with zipfile.ZipFile(os.path.join(OUT, name), 'w',
                         zipfile.ZIP_DEFLATED) as z:
        for entry, data in entries:
            info = zipfile.ZipInfo(entry, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, data)


def _media():
    return [('media', json.dumps({'0': 'cat.png'})), ('0', CAT_PNG)]


def main():
    os.makedirs(OUT, exist_ok=True)
    basic = _collection_bytes(NOTES)
    _apkg('basic.apkg', [('collection.anki2', basic)] + _media())

    v2 = list(NOTES)
    v2[0] = ('basic-1', BASIC, ['Hund', 'dog<br>a loyal pet'], ' animal noun ')
    v2.append(('rev-3', REVERSED, ['Baum', 'tree'], ' noun '))
    _apkg('basic_v2.apkg',
          [('collection.anki2', _collection_bytes(v2))] + _media())

    dummy = _collection_bytes(
        [('dummy-1', BASIC,
          ['Please update to the latest Anki version, then import the '
           '.colpkg/.apkg file again.', ''], '')],
        decks={'1': {'id': 1, 'name': 'Default'}},
    )
    _apkg('both.apkg', [('collection.anki2', dummy),
                        ('collection.anki21', basic)] + _media())

    # The zstd-compressed schema 18 collection of newer exports; its content
    # does not matter, only that it is the only collection.
    _apkg('anki21b_only.apkg', [('collection.anki21b', b'\x28\xb5\x2f\xfd'),
                                ('meta', b'\x08\x03')])

    _apkg('reviews.apkg', [
        ('collection.anki2',
         _collection_bytes(REVIEW_NOTES, crt=REVIEWS_CRT, revlog=REVLOG)),
        ('media', '{}'),
    ])

    csv = (
        '\ufeffFront,Back,Tags,Deck\r\n'
        'Hallo,hello,greeting,German\r\n'
        '"Apfel, rot","apple, red",fruit food,German\r\n'
        '"Zitat","He said ""hi""",,\r\n'
        '"zwei\nZeilen","two\r\nlines",multi line,German\r\n'
        'Über,über / about,umlaut,Deutsch::Präpositionen\r\n'
        '日本,Japan \U0001f5fe,cjk emoji,Asia\r\n'
        ',no front,,German\r\n'
        '\r\n'
        'Tschüss,bye,greeting,German\n'
    )
    with open(os.path.join(ROOT, 'test', 'fixtures', 'cards.csv'), 'w',
              encoding='utf-8', newline='') as f:
        f.write(csv)


if __name__ == '__main__':
    main()
