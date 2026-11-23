#!/usr/bin/env python3
"""Independent oracle for test/fixtures/encrypted_objects/vectors.json.

Computes the key-hierarchy vectors (ENCRYPTED-OBJECTS.md 4.1, 4.2, 4.6, 8)
and the envelope vectors (5.1, 5.3, 5.6) with the Python standard library only — no Dart and no `cryptography`
package — so the Dart implementation is checked against a second one.
XChaCha20-Poly1305 is implemented below from RFC 8439 and
draft-irtf-cfrg-xchacha-03 and self-checked against the draft's test vector.

Usage:
    python3 scripts/gen_encrypted_objects_vectors.py > \
        test/fixtures/encrypted_objects/vectors.json

The sections written here are frozen once merged (section 8): never change
their inputs or outputs, add new sections instead.
"""

import base64
import hashlib
import hmac
import json
import struct
import sys

# ── XChaCha20-Poly1305 (RFC 8439 + draft-irtf-cfrg-xchacha-03) ──────────────


def _rotl(v, c):
    return ((v << c) & 0xFFFFFFFF) | (v >> (32 - c))


def _quarter(s, a, b, c, d):
    s[a] = (s[a] + s[b]) & 0xFFFFFFFF
    s[d] = _rotl(s[d] ^ s[a], 16)
    s[c] = (s[c] + s[d]) & 0xFFFFFFFF
    s[b] = _rotl(s[b] ^ s[c], 12)
    s[a] = (s[a] + s[b]) & 0xFFFFFFFF
    s[d] = _rotl(s[d] ^ s[a], 8)
    s[c] = (s[c] + s[d]) & 0xFFFFFFFF
    s[b] = _rotl(s[b] ^ s[c], 7)


def _rounds(s):
    for _ in range(10):
        _quarter(s, 0, 4, 8, 12)
        _quarter(s, 1, 5, 9, 13)
        _quarter(s, 2, 6, 10, 14)
        _quarter(s, 3, 7, 11, 15)
        _quarter(s, 0, 5, 10, 15)
        _quarter(s, 1, 6, 11, 12)
        _quarter(s, 2, 7, 8, 13)
        _quarter(s, 3, 4, 9, 14)


_SIGMA = list(struct.unpack("<4I", b"expand 32-byte k"))


def _chacha_block(key, counter, nonce12):
    state = _SIGMA + list(struct.unpack("<8I", key)) + [counter] + list(
        struct.unpack("<3I", nonce12)
    )
    working = list(state)
    _rounds(working)
    return struct.pack("<16I", *[(w + s) & 0xFFFFFFFF for w, s in zip(working, state)])


def _hchacha20(key, nonce16):
    state = _SIGMA + list(struct.unpack("<8I", key)) + list(struct.unpack("<4I", nonce16))
    _rounds(state)
    return struct.pack("<8I", *(state[0:4] + state[12:16]))


def _chacha20_xor(key, counter, nonce12, data):
    out = bytearray()
    for i in range(0, len(data), 64):
        block = _chacha_block(key, counter + i // 64, nonce12)
        out += bytes(a ^ b for a, b in zip(data[i : i + 64], block))
    return bytes(out)


def _poly1305(key, msg):
    r = int.from_bytes(key[:16], "little") & 0x0FFFFFFC0FFFFFFC0FFFFFFC0FFFFFFF
    s = int.from_bytes(key[16:], "little")
    p = (1 << 130) - 5
    acc = 0
    for i in range(0, len(msg), 16):
        n = int.from_bytes(msg[i : i + 16] + b"\x01", "little")
        acc = ((acc + n) * r) % p
    return ((acc + s) & ((1 << 128) - 1)).to_bytes(16, "little")


def _pad16(b):
    return b"\x00" * (-len(b) % 16)


def xchacha20poly1305_encrypt(key, nonce24, plaintext, aad):
    """Returns ciphertext ‖ tag(16)."""
    subkey = _hchacha20(key, nonce24[:16])
    nonce12 = b"\x00" * 4 + nonce24[16:]
    otk = _chacha_block(subkey, 0, nonce12)[:32]
    ct = _chacha20_xor(subkey, 1, nonce12, plaintext)
    mac_data = (
        aad + _pad16(aad) + ct + _pad16(ct) + struct.pack("<QQ", len(aad), len(ct))
    )
    return ct + _poly1305(otk, mac_data)


def _self_check():
    # draft-irtf-cfrg-xchacha-03, A.3.1.
    pt = (
        b"Ladies and Gentlemen of the class of '99: If I could offer you only "
        b"one tip for the future, sunscreen would be it."
    )
    aad = bytes.fromhex("50515253c0c1c2c3c4c5c6c7")
    key = bytes(range(0x80, 0xA0))
    nonce = bytes(range(0x40, 0x58))
    out = xchacha20poly1305_encrypt(key, nonce, pt, aad)
    assert out[:16].hex() == "bd6d179d3e83d43b9576579493c0e939", out[:16].hex()
    assert out[-16:].hex() == "c0875924c1c7987947deafd8780acf49", out[-16:].hex()


# ── Format helpers (ENCRYPTED-OBJECTS.md 4.6) ───────────────────────────────


def hkdf(root, info):
    prk = hmac.new(b"\x00" * 32, root, hashlib.sha256).digest()  # empty salt
    return hmac.new(prk, info.encode() + b"\x01", hashlib.sha256).digest()


def enc(s):
    b = s.encode()
    return struct.pack(">H", len(b)) + b


def b64url(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"


def crockford(b):
    n = int.from_bytes(b, "big")
    chars = len(b) * 8 // 5
    return "".join(CROCKFORD[(n >> (5 * (chars - 1 - i))) & 31] for i in range(chars))


INFOS = {
    "obj": "sharedinbox-obj-v1",
    "itemIdHmac": "sharedinbox-itemid-hmac-v1",
    "slotsMac": "sharedinbox-slots-mac-v1",
    "collectionWrap": "sharedinbox-collection-wrap-v1",
    "kekRecovery": "sharedinbox-kek-recovery-v1",
    "kekPassphrase": "sharedinbox-kek-passphrase-v1",
    "kekPasskey": "sharedinbox-kek-passkey-v1",
    "pairing": "sharedinbox-pairing-v1",
}


def padded_length(p):
    if p > 65536:
        return -(-p // 65536) * 65536
    bucket = 1024
    while bucket < p:
        bucket *= 2
    return bucket


def hlc(wall_ms, counter, device_id):
    return "%013d-%04x-%s" % (wall_ms, counter, device_id)


def message_id(raw):
    return "<%s@sharedinbox.invalid>" % base64.b32encode(raw).decode().lower().rstrip("=")


def envelope_sections(collection_key, key_id):
    """The envelope slice (#1369): itemHmac, padding, envelope, hlc, messageId."""
    item_id = b64url(bytes(range(0x00, 0x10)))
    k_item = hkdf(collection_key, INFOS["itemIdHmac"])
    item_hmac = hmac.new(k_item, item_id.encode(), hashlib.sha256).digest()

    inner_mime = (
        b"Content-Type: multipart/related; boundary=\"si-test\"\r\n\r\n"
        b"--si-test\r\nContent-Type: application/json; charset=utf-8\r\n\r\n"
        b"{}\r\n--si-test--\r\n"
    )
    nonce = bytes(range(0x90, 0xA8))
    k_obj = hkdf(collection_key, INFOS["obj"])
    aad = b"SIE1" + key_id + item_hmac
    p = 4 + len(inner_mime)
    plaintext = struct.pack(">I", len(inner_mime)) + inner_mime
    plaintext += b"\x00" * (padded_length(p) - p)
    blob = b"SIE1" + key_id + nonce + xchacha20poly1305_encrypt(k_obj, nonce, plaintext, aad)

    device_id = b64url(bytes(range(0xF0, 0x100)))
    message_raw = bytes(range(0xE0, 0xF0))
    return {
        "itemHmac": {
            "collectionKey": collection_key.hex(),
            "kItem": k_item.hex(),
            "itemId": item_id,
            "itemHmac": item_hmac.hex(),
        },
        "padding": [
            {"p": n, "padded": padded_length(n)}
            for n in [0, 1, 1024, 1025, 2048, 2049, 65536, 65537, 131072, 131073]
        ],
        "envelope": {
            "collectionKey": collection_key.hex(),
            "keyId": key_id.hex(),
            "itemId": item_id,
            "itemHmac": item_hmac.hex(),
            "nonce": nonce.hex(),
            "innerMime": inner_mime.hex(),
            "kObj": k_obj.hex(),
            "aad": aad.hex(),
            "blob": blob.hex(),
        },
        "hlc": [
            {"wallMs": w, "counter": c, "deviceId": device_id, "encoded": hlc(w, c, device_id)}
            for w, c in [(0, 0), (1700000000000, 1), (1700000000000, 0xFFFF)]
        ],
        "messageId": {"random": message_raw.hex(), "messageId": message_id(message_raw)},
    }


def main():
    _self_check()

    account_key = bytes(range(0x00, 0x20))
    account_key_id = bytes(range(0xA0, 0xB0))
    collection_key = bytes(range(0x20, 0x40))
    key_id = bytes(range(0xB0, 0xC0))
    collection_id = "deck-1"
    recovery_raw = bytes(range(0x40, 0x50))
    slot_id = bytes(range(0xC0, 0xD0))
    slot_nonce = bytes(range(0x50, 0x68))
    wrap_nonce = bytes(range(0x70, 0x88))

    checksum = hashlib.sha256(recovery_raw).digest()[:4]
    chars = crockford(recovery_raw + checksum)
    formatted = "-".join(chars[i : i + 4] for i in range(0, 32, 4))
    kek = hkdf(recovery_raw, INFOS["kekRecovery"])

    slot_aad = account_key_id + slot_id + enc("recovery")
    slot_wrapped = xchacha20poly1305_encrypt(kek, slot_nonce, account_key, slot_aad)

    k_wrap = hkdf(account_key, INFOS["collectionWrap"])
    wrap_aad = b"SICK1" + account_key_id + enc(collection_id) + key_id + enc("account")
    wrap_wrapped = xchacha20poly1305_encrypt(k_wrap, wrap_nonce, collection_key, wrap_aad)

    payload = {
        "v": 1,
        "kind": "account-key",
        "accountKeyId": b64url(account_key_id),
        "slotListVersion": 1,
        "slots": [
            {
                "slotId": b64url(slot_id),
                "type": "recovery",
                "nonce": b64url(slot_nonce),
                "wrapped": b64url(slot_wrapped),
            }
        ],
    }
    payload_bytes = json.dumps(payload, separators=(",", ":")).encode()
    k_slots = hkdf(account_key, INFOS["slotsMac"])
    mac = hmac.new(k_slots, payload_bytes, hashlib.sha256).digest()

    vectors = {
        "_comment": (
            "ENCRYPTED-OBJECTS.md section 8. Generated by "
            "scripts/gen_encrypted_objects_vectors.py. Binary values are hex. "
            "Each top-level section is frozen once merged."
        ),
        "hkdf": {
            "root": account_key.hex(),
            "subKeys": {
                name: {"info": info, "key": hkdf(account_key, info).hex()}
                for name, info in INFOS.items()
            },
        },
        "recoveryKey": {
            "raw": recovery_raw.hex(),
            "checksum": checksum.hex(),
            "formatted": formatted,
            "kek": kek.hex(),
        },
        "slotWrap": {
            "accountKey": account_key.hex(),
            "accountKeyId": account_key_id.hex(),
            "slotId": slot_id.hex(),
            "type": "recovery",
            "nonce": slot_nonce.hex(),
            "kek": kek.hex(),
            "aad": slot_aad.hex(),
            "wrapped": slot_wrapped.hex(),
        },
        "collectionWrap": {
            "accountKey": account_key.hex(),
            "accountKeyId": account_key_id.hex(),
            "collectionId": collection_id,
            "collectionKey": collection_key.hex(),
            "keyId": key_id.hex(),
            "wrapType": "account",
            "nonce": wrap_nonce.hex(),
            "kWrap": k_wrap.hex(),
            "aad": wrap_aad.hex(),
            "wrapped": wrap_wrapped.hex(),
        },
        "keyMailMac": {
            "accountKey": account_key.hex(),
            "kSlots": k_slots.hex(),
            "payload": payload_bytes.decode(),
            "mac": mac.hex(),
        },
    }
    vectors.update(envelope_sections(collection_key, key_id))
    json.dump(vectors, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
