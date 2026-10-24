#!/usr/bin/env python3
"""Unit tests for fault_proxy.py: every mode against a local echo server.

    python3 scripts/test_fault_proxy.py
"""
from __future__ import annotations

import socket
import sys
import threading
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fault_proxy as fp  # noqa: E402

LOCAL = "127.0.0.1"


class EchoServer:
    def __init__(self):
        self.sock = socket.create_server((LOCAL, 0))
        self.addr = self.sock.getsockname()
        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self._echo, args=(conn,), daemon=True).start()

    @staticmethod
    def _echo(conn):
        with conn:
            while data := conn.recv(65536):
                conn.sendall(data)

    def close(self):
        self.sock.close()


class FaultProxyTest(unittest.TestCase):
    def setUp(self):
        self.echo = EchoServer()
        self.logged: list[str] = []
        self.proxy = fp.Proxy({"imap": ((LOCAL, 0), self.echo.addr),
                               "smtp": ((LOCAL, 0), self.echo.addr)},
                              log=self.logged.append)
        self.proxy.start()
        self.addr = self.proxy.listeners["imap"].listen

    def tearDown(self):
        self.proxy.stop()
        self.echo.close()

    def connect(self, timeout=2.0) -> socket.socket:
        sock = socket.create_connection(self.addr, timeout=timeout)
        self.addCleanup(sock.close)
        return sock

    def roundtrip(self, sock, payload=b"ping") -> bytes:
        sock.sendall(payload)
        got = b""
        while len(got) < len(payload):
            chunk = sock.recv(65536)
            if not chunk:
                break
            got += chunk
        return got

    def wait_open(self, n, name="imap"):
        deadline = time.monotonic() + 2
        while len(self.proxy.listeners[name].conns) != n:
            if time.monotonic() > deadline:
                self.fail(f"expected {n} open connections, "
                          f"have {len(self.proxy.listeners[name].conns)}")
            time.sleep(0.02)

    def assert_refused(self):
        # The test listens on an ephemeral port, so with nothing listening a
        # connect can pick that same port as its source and connect to itself
        # (TCP simultaneous open). Real proxy ports are not ephemeral.
        for _ in range(5):
            try:
                sock = socket.create_connection(self.addr, timeout=2)
            except ConnectionRefusedError:
                return
            with sock:
                if sock.getsockname() != sock.getpeername():
                    self.fail("connected while down")
        self.fail("could not get a refused connection")

    def test_up_forwards(self):
        self.assertEqual(self.roundtrip(self.connect()), b"ping")
        self.wait_open(1)
        self.assertIn("mode=up  open=1 total=1", self.proxy.status())

    def test_down_refuses_and_closes(self):
        sock = self.connect()
        self.assertEqual(self.roundtrip(sock), b"ping")
        self.wait_open(1)
        out = self.proxy.set("down", "imap")
        self.assertIn("net imap: up -> down (closed 1 connections)", out)
        self.assertEqual(self.logged, [out.strip()])
        self.assertEqual(sock.recv(10), b"")  # orderly close
        self.assert_refused()
        # The other protocol is untouched.
        other = socket.create_connection(self.proxy.listeners["smtp"].listen, timeout=2)
        self.addCleanup(other.close)
        self.assertEqual(self.roundtrip(other), b"ping")
        # And up brings the same port back.
        self.proxy.set("up", "imap")
        self.assertEqual(self.roundtrip(self.connect()), b"ping")

    def test_reset_sends_rst_once(self):
        sock = self.connect()
        self.assertEqual(self.roundtrip(sock), b"ping")
        self.wait_open(1)
        out = self.proxy.set("reset", "imap")
        self.assertIn("(reset 1 connections), now up", out)
        with self.assertRaises(ConnectionResetError):
            for _ in range(20):  # the RST may race the first recv
                if sock.recv(10) == b"":
                    self.fail("got a FIN, expected an RST")
        self.assertIn("mode=up", self.proxy.status())
        self.assertEqual(self.roundtrip(self.connect()), b"ping")

    def test_blackhole_holds_bytes_until_up(self):
        sock = self.connect(timeout=0.5)
        self.assertEqual(self.roundtrip(sock), b"ping")
        self.proxy.set("blackhole")
        time.sleep(fp.POLL * 3)  # let the pump notice
        sock.sendall(b"lost?")
        with self.assertRaises(TimeoutError):
            sock.recv(10)
        # A new connection is accepted but gets nothing either.
        fresh = self.connect(timeout=0.5)
        fresh.sendall(b"hello")
        with self.assertRaises(TimeoutError):
            fresh.recv(10)
        self.proxy.set("up")
        sock.settimeout(2)
        fresh.settimeout(2)
        self.assertEqual(sock.recv(10), b"lost?")  # delivered after healing
        self.assertEqual(fresh.recv(10), b"hello")

    def test_slow_delays_each_chunk(self):
        sock = self.connect()
        self.proxy.set("slow", "imap", delay_ms=200)
        self.assertIn("mode=slow delay_ms=200 rate=0", self.proxy.status())
        start = time.monotonic()
        self.assertEqual(self.roundtrip(sock), b"ping")
        # One delay each way.
        self.assertGreaterEqual(time.monotonic() - start, 0.35)

    def test_slow_caps_bandwidth(self):
        sock = self.connect(timeout=5)
        self.proxy.set("slow", "imap", rate=20_000)
        start = time.monotonic()
        self.assertEqual(self.roundtrip(sock, b"x" * 10_000), b"x" * 10_000)
        # 10 kB at 20 kB/s, through two throttled hops (there and back).
        self.assertGreaterEqual(time.monotonic() - start, 0.8)

    def test_slow_defaults_to_a_delay(self):
        self.assertIn("slow delay_ms=500 rate=0", self.proxy.set("slow"))

    def test_rejects_bad_input(self):
        with self.assertRaises(ValueError):
            self.proxy.set("flaky")
        with self.assertRaises(ValueError):
            self.proxy.set("down", "pop3")
        with self.assertRaises(ValueError):
            self.proxy.set("slow", delay_ms=-1)

    def test_upstream_down_closes_client(self):
        self.echo.close()
        dead = socket.create_server((LOCAL, 0))
        self.proxy.listeners["imap"].target = dead.getsockname()
        dead.close()
        sock = self.connect()
        self.assertEqual(sock.recv(10), b"")
        self.assertIn("unreachable", self.logged[-1])


if __name__ == "__main__":
    unittest.main()
