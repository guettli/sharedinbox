#!/usr/bin/env python3
"""Builds the Anki import fixtures of #1383 and #1385 in test/fixtures/anki/.

Standard library only (sqlite3, zipfile, json). The collections use the
legacy schema 11 (note types and decks as JSON in `col`), as Anki writes
into `collection.anki2` / `collection.anki21`, except for the schema 18
`collection.anki21b` of basic_21b.apkg (#1384): note types, fields,
templates and decks in tables, their configs as protobuf, zstd-compressed
like its protobuf `media` map and media files. Python has no zstd module,
so the zstd frames hold raw (stored) blocks.

Usage:
    python3 scripts/make_anki_fixtures.py

Writes basic.apkg, basic_v2.apkg, both.apkg, basic_21b.apkg,
anki21b_corrupt.apkg, reviews.apkg and test/fixtures/cards.csv. The tests
depend on their content: change both together.
"""

import hashlib
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


def _varint(n):
    out = bytearray()
    while True:
        b = n & 0x7f
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def _pb_varint(field, n):
    return _varint(field << 3) + _varint(n)


def _pb_bytes(field, data):
    if isinstance(data, str):
        data = data.encode('utf-8')
    return _varint(field << 3 | 2) + _varint(len(data)) + data


def _zstd(data):
    """A zstd frame of raw blocks: single segment, 4-byte content size."""
    out = bytearray(b'\x28\xb5\x2f\xfd')
    out.append(0xa0)  # Frame_Content_Size_flag 2, Single_Segment_flag.
    out += len(data).to_bytes(4, 'little')
    block = 128 * 1024
    at = 0
    while True:
        chunk = data[at:at + block]
        at += len(chunk)
        last = at >= len(data)
        # Block_Size << 3 | Block_Type 0 (raw) << 1 | Last_Block.
        out += (len(chunk) << 3 | int(last)).to_bytes(3, 'little')
        out += chunk
        if last:
            return bytes(out)


def _unicase(a, b):
    a, b = a.lower(), b.lower()
    return (a > b) - (a < b)


def _schema18(db, models, decks):
    """The note types and decks of schema 18 in their tables."""
    db.executescript('''
        CREATE TABLE notetypes (id integer not null primary key,
          name text not null COLLATE unicase, mtime_secs integer not null,
          usn integer not null, config blob not null);
        CREATE TABLE fields (ntid integer not null, ord integer not null,
          name text not null COLLATE unicase, config blob not null,
          PRIMARY KEY (ntid, ord)) without rowid;
        CREATE TABLE templates (ntid integer not null, ord integer not null,
          name text not null COLLATE unicase, mtime_secs integer not null,
          usn integer not null, config blob not null,
          PRIMARY KEY (ntid, ord)) without rowid;
        CREATE TABLE decks (id integer primary key not null,
          name text not null COLLATE unicase, mtime_secs integer not null,
          usn integer not null, common blob not null, kind blob not null);
        CREATE UNIQUE INDEX idx_notetypes_name ON notetypes (name);
        CREATE UNIQUE INDEX idx_decks_name ON decks (name);
    ''')
    for m in models.values():
        # NotetypeConfig: kind = 1 (omitted when 0, normal), css = 3.
        config = (_pb_varint(1, m['type']) if m['type'] else b'') + \
            _pb_bytes(3, m['css'])
        db.execute('INSERT INTO notetypes VALUES (?, ?, 0, 0, ?)',
                   (m['id'], m['name'], config))
        for f in m['flds']:
            db.execute('INSERT INTO fields VALUES (?, ?, ?, ?)',
                       (m['id'], f['ord'], f['name'], b''))
        for t in m['tmpls']:
            # CardTemplate.Config: q_format = 1, a_format = 2.
            config = _pb_bytes(1, t['qfmt']) + _pb_bytes(2, t['afmt'])
            db.execute('INSERT INTO templates VALUES (?, ?, ?, 0, 0, ?)',
                       (m['id'], t['ord'], t['name'], config))
    for d in decks.values():
        db.execute('INSERT INTO decks VALUES (?, ?, 0, 0, ?, ?)',
                   (d['id'], d['name'].replace('::', '\x1f'), b'', b''))


def _collection(path, notes, decks=None, crt=0, revlog=(), schema=11):
    db = sqlite3.connect(path)
    db.create_collation('unicase', _unicase)
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
    if schema == 18:
        _schema18(db, models, decks or _decks())
        db.execute(
            'INSERT INTO col VALUES (1, ?, 0, 0, 18, 0, 0, 0, ?, ?, ?, ?, ?)',
            (crt, '', '', '', '', ''),
        )
    else:
        db.execute(
            'INSERT INTO col VALUES (1, ?, 0, 0, 11, 0, 0, 0, ?, ?, ?, ?, ?)',
            (crt, '{}', json.dumps(models), json.dumps(decks or _decks()),
             '{}', '{}'),
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


def _collection_bytes(notes, decks=None, crt=0, revlog=(), schema=11):
    with tempfile.TemporaryDirectory() as d:
        return _collection(os.path.join(d, 'c.db'), notes, decks, crt, revlog,
                           schema)


def _apkg(name, entries):
    with zipfile.ZipFile(os.path.join(OUT, name), 'w',
                         zipfile.ZIP_DEFLATED) as z:
        for entry, data in entries:
            info = zipfile.ZipInfo(entry, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, data)


def _media():
    return [('media', json.dumps({'0': 'cat.png'})), ('0', CAT_PNG)]


# PackageMetadata { Version version = 1; } with LATEST = 3.
META_LATEST = _pb_varint(1, 3)


def _media_latest():
    """MediaEntries { repeated MediaEntry entries = 1; } with
    MediaEntry { string name = 1; uint32 size = 2; bytes sha1 = 3; }."""
    entry = _pb_bytes(1, 'cat.png') + _pb_varint(2, len(CAT_PNG)) + \
        _pb_bytes(3, hashlib.sha1(CAT_PNG).digest())
    return [('media', _zstd(_pb_bytes(1, entry))), ('0', _zstd(CAT_PNG))]


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

    # The twin of basic.apkg as newer Anki versions export it: the dummy
    # anki2 next to the zstd-compressed schema 18 anki21b.
    _apkg('basic_21b.apkg', [
        ('collection.anki2', dummy),
        ('collection.anki21b', _zstd(_collection_bytes(NOTES, schema=18))),
        ('meta', META_LATEST),
    ] + _media_latest())

    # A zstd frame header without blocks.
    _apkg('anki21b_corrupt.apkg', [
        ('collection.anki2', dummy),
        ('collection.anki21b', b'\x28\xb5\x2f\xfd\xa0\x10\x00\x00\x00'),
        ('meta', META_LATEST),
        ('media', _zstd(b'')),
    ])

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
