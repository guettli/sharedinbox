package main

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// newRecipientKey generates a maintainer key pair the way the report service
// does: a random 16-byte key ID plus an X25519 key pair.
func newRecipientKey(t *testing.T) (keyID, priv, pub []byte) {
	t.Helper()
	keyID = make([]byte, reportKeyIDLen)
	if _, err := rand.Read(keyID); err != nil {
		t.Fatalf("rand keyID: %v", err)
	}
	k, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey: %v", err)
	}
	return keyID, k.Bytes(), k.PublicKey().Bytes()
}

// encryptReportForTest mirrors the app's on-device ECIES encryption
// (share_encryption_service.dart) so the test can round-trip decryptReport.
func encryptReportForTest(t *testing.T, recipientKeyID, recipientPub, plaintext []byte) []byte {
	t.Helper()
	curve := ecdh.X25519()
	eph, err := curve.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("eph GenerateKey: %v", err)
	}
	recip, err := curve.NewPublicKey(recipientPub)
	if err != nil {
		t.Fatalf("NewPublicKey: %v", err)
	}
	shared, err := eph.ECDH(recip)
	if err != nil {
		t.Fatalf("ECDH: %v", err)
	}
	aesKey, err := hkdf.Key(sha256.New, shared, recipientKeyID, reportEncryptionInfo, 32)
	if err != nil {
		t.Fatalf("hkdf: %v", err)
	}
	block, err := aes.NewCipher(aesKey)
	if err != nil {
		t.Fatalf("NewCipher: %v", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		t.Fatalf("NewGCM: %v", err)
	}
	nonce := make([]byte, reportNonceLen)
	if _, err := rand.Read(nonce); err != nil {
		t.Fatalf("rand nonce: %v", err)
	}
	ciphertext := gcm.Seal(nil, nonce, plaintext, nil)
	return bytes.Join([][]byte{recipientKeyID, eph.PublicKey().Bytes(), nonce, ciphertext}, nil)
}

func TestDecryptReportRoundTrip(t *testing.T) {
	keyID, priv, pub := newRecipientKey(t)
	want := []byte("From: a@b.c\r\nSubject: bug\r\n\r\nsomething broke\r\n")

	wire := encryptReportForTest(t, keyID, pub, want)

	got, err := decryptReport(priv, keyID, wire)
	if err != nil {
		t.Fatalf("decryptReport: %v", err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("round trip mismatch:\n got %q\nwant %q", got, want)
	}
}

func TestDecryptReportNilKeyIDSkipsCheck(t *testing.T) {
	keyID, priv, pub := newRecipientKey(t)
	want := []byte("hello")
	wire := encryptReportForTest(t, keyID, pub, want)

	got, err := decryptReport(priv, nil, wire)
	if err != nil {
		t.Fatalf("decryptReport with nil keyID: %v", err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestDecryptReportKeyIDMismatch(t *testing.T) {
	keyID, priv, pub := newRecipientKey(t)
	wire := encryptReportForTest(t, keyID, pub, []byte("x"))

	wrongID := make([]byte, reportKeyIDLen) // all zero, different from keyID
	if _, err := decryptReport(priv, wrongID, wire); err == nil {
		t.Fatal("expected key ID mismatch error, got nil")
	}
}

func TestDecryptReportTampered(t *testing.T) {
	keyID, priv, pub := newRecipientKey(t)
	wire := encryptReportForTest(t, keyID, pub, []byte("secret body"))
	wire[len(wire)-1] ^= 0xff // flip a MAC byte

	if _, err := decryptReport(priv, keyID, wire); err == nil {
		t.Fatal("expected AES-GCM authentication failure, got nil")
	}
}

func TestDecryptReportTooShort(t *testing.T) {
	_, priv, _ := newRecipientKey(t)
	if _, err := decryptReport(priv, nil, []byte("too short")); err == nil {
		t.Fatal("expected too-short error, got nil")
	}
}

// TestDecryptReportBadPrivateKeyLen asserts the private-key length guard fires
// before any wire parsing (the 100-byte wire is a valid length, so only the
// short key can be at fault).
func TestDecryptReportBadPrivateKeyLen(t *testing.T) {
	if _, err := decryptReport([]byte("short"), nil, make([]byte, 100)); err == nil {
		t.Fatal("expected private-key length error, got nil")
	}
}

// TestDecryptReportWrongPrivateKey: a correctly-sized but unrelated private key
// must fail at GCM authentication, not silently return garbage.
func TestDecryptReportWrongPrivateKey(t *testing.T) {
	keyID, _, pub := newRecipientKey(t)
	wire := encryptReportForTest(t, keyID, pub, []byte("body"))

	other, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey: %v", err)
	}
	if _, err := decryptReport(other.Bytes(), keyID, wire); err == nil {
		t.Fatal("expected GCM authentication failure with the wrong key, got nil")
	}
}

// TestRunDecryptEndToEnd exercises the subcommand entry point: env-provided
// keypair, a mail.enc file argument, and plaintext written to stdout.
func TestRunDecryptEndToEnd(t *testing.T) {
	keyID, priv, pub := newRecipientKey(t)
	want := []byte("From: x@y.z\r\n\r\nvia runDecrypt")
	wire := encryptReportForTest(t, keyID, pub, want)

	fullPub := append(append([]byte{}, keyID...), pub...)
	t.Setenv("REPORT_PRIVATE_KEY", base64.StdEncoding.EncodeToString(priv))
	t.Setenv("REPORT_PUBLIC_KEY", base64.StdEncoding.EncodeToString(fullPub))

	path := filepath.Join(t.TempDir(), "mail.enc")
	if err := os.WriteFile(path, wire, 0o600); err != nil {
		t.Fatalf("write mail.enc: %v", err)
	}

	// Capture stdout while runDecrypt writes the plaintext.
	old := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	os.Stdout = w
	runErr := runDecrypt([]string{path})
	_ = w.Close()
	os.Stdout = old
	if runErr != nil {
		t.Fatalf("runDecrypt: %v", runErr)
	}
	got, err := io.ReadAll(r)
	if err != nil {
		t.Fatalf("read stdout: %v", err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("runDecrypt output mismatch:\n got %q\nwant %q", got, want)
	}
}

// TestRunDecryptMissingEnv: without the key env vars the subcommand errors
// instead of panicking or producing output.
func TestRunDecryptMissingEnv(t *testing.T) {
	t.Setenv("REPORT_PRIVATE_KEY", "")
	t.Setenv("REPORT_PUBLIC_KEY", "")
	if err := runDecrypt([]string{"-"}); err == nil {
		t.Fatal("expected error when key env vars are unset, got nil")
	}
}

func TestBuildIssueContainsDecryptHint(t *testing.T) {
	url := "https://sharedinbox.de/api/v1/encrypted-reports/abc/mail.enc"
	_, body := buildIssue(BugReport{Description: "boom"}, url)

	for _, want := range []string{
		"How to decrypt",
		"go run ./server/bugreport decrypt mail.enc",
		url,
		reportEncryptionInfo,
		"REPORT_PRIVATE_KEY",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("issue body missing %q\n---\n%s", want, body)
		}
	}
}
