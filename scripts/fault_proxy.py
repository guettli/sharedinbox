#!/usr/bin/env python3
"""Fault-injecting TCP proxy between the app and Stalwart, for exploratory tests.

scripts/explore_server.py starts one Listener per protocol on the localhost
ports the app is configured with (IMAP 1430, SMTP 1025, JMAP 8080, Sieve 4190)
and exposes Proxy.set / Proxy.status as `POST /net` and `GET /net`. The
tester's own ports (seeding, inspection) bypass this proxy; see
explore_entrypoint.sh.

Modes, per protocol:

    up         forward normally
    down       close the listening socket (new connections get "connection
               refused") and close the open connections with a FIN
    reset      abort the open connections with an RST, then behave as up
    blackhole  accept connections and keep them open, but move no bytes in
               either direction (data waits in the kernel buffers and flows
               again after `up`, like a healed partition): exposes missing
               timeouts and dead IDLE connections
    slow       forward, but wait delay_ms before every chunk and cap each
               direction at rate bytes per second (0 = no cap)

Stdlib only, one thread per connection. Every blocking call polls with a
short timeout, so a mode change takes effect within POLL seconds.
"""
from __future__ import annotations

import select
import socket
import struct
import threading
from dataclasses import dataclass
from typing import Callable

MODES = ("up", "down", "reset", "blackhole", "slow")
POLL = 0.1
CHUNK = 65536


@dataclass
class Fault:
    mode: str = "up"
    delay_ms: int = 0
    rate: int = 0  # bytes per second and direction, 0 = unlimited

    def describe(self) -> str:
        if self.mode != "slow":
            return self.mode
        return f"slow delay_ms={self.delay_ms} rate={self.rate}"


class _Conn:
    """One proxied client connection and its upstream."""

    def __init__(self, client: socket.socket):
        self.client = client
        self.upstream: socket.socket | None = None
        # Set by the controller, acted on by the connection's own thread, so
        # only that thread ever closes the sockets.
        self.action: str | None = None  # "close" or "reset"
        self.wake = threading.Event()

    def abort(self, action: str) -> None:
        self.action = action
        self.wake.set()


class Listener:
    def __init__(self, name: str, listen: tuple[str, int],
                 target: tuple[str, int], proxy: "Proxy"):
        self.name = name
        self.listen = listen
        self.target = target
        self.proxy = proxy
        self.fault = Fault()
        self.conns: set[_Conn] = set()
        self.total = 0
        self._sock: socket.socket | None = None
        self._lock = threading.Lock()

    # -- listening socket -------------------------------------------------

    def start(self) -> None:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(self.listen)
        sock.listen(64)
        sock.settimeout(POLL)
        if self.listen[1] == 0:  # tests: an ephemeral port
            self.listen = sock.getsockname()
        self._sock = sock
        threading.Thread(target=self._accept_loop, args=(sock,),
                         name=f"net-{self.name}", daemon=True).start()

    def stop(self) -> None:
        sock, self._sock = self._sock, None
        if sock is None:
            return
        # close() alone leaves the socket listening until the accept loop's
        # poll returns, and connections in that window would succeed;
        # shutdown() stops listening at once (Linux).
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        sock.close()

    def _accept_loop(self, sock: socket.socket) -> None:
        while self._sock is sock:
            try:
                client, _ = sock.accept()
            except TimeoutError:
                continue
            except OSError:
                return  # closed by stop()
            if self._sock is not sock:  # went down while accepting
                client.close()
                return
            client.settimeout(None)
            conn = _Conn(client)
            with self._lock:
                self.conns.add(conn)
                self.total += 1
            threading.Thread(target=self._serve, args=(conn,),
                             name=f"net-{self.name}-conn", daemon=True).start()

    # -- mode changes -----------------------------------------------------

    def set(self, fault: Fault) -> int:
        """Apply fault; return how many open connections it closed."""
        if fault.mode == "down":
            self.stop()  # first, so no new connection slips in meanwhile
        # reset is one-shot: the open connections go, the network stays up.
        self.fault = Fault() if fault.mode == "reset" else fault
        with self._lock:
            conns = list(self.conns)
        if fault.mode in ("down", "reset"):
            for conn in conns:
                conn.abort("close" if fault.mode == "down" else "reset")
            return len(conns)
        if self._sock is None:
            self.start()
        for conn in conns:
            conn.wake.set()  # end a slow-mode pause early
        return 0

    # -- one connection ---------------------------------------------------

    def _serve(self, conn: _Conn) -> None:
        try:
            self._pump(conn)
        except OSError:
            pass
        finally:
            self._close(conn)
            with self._lock:
                self.conns.discard(conn)

    def _wait(self, conn: _Conn, seconds: float) -> bool:
        """Sleep, but return False at once when the connection is aborted."""
        conn.wake.clear()
        if conn.action is None and seconds > 0:
            conn.wake.wait(seconds)
        return conn.action is None

    def _pump(self, conn: _Conn) -> None:
        # Blackhole: hold the accepted client without even dialing upstream.
        while self.fault.mode == "blackhole":
            if not self._wait(conn, POLL):
                return
        if conn.action is not None:
            return
        try:
            conn.upstream = socket.create_connection(self.target, timeout=10)
        except OSError as exc:
            self.proxy.log(f"net {self.name}: upstream {self.target[0]}:"
                           f"{self.target[1]} unreachable: {exc}")
            return
        conn.upstream.settimeout(None)
        peer = {conn.client: conn.upstream, conn.upstream: conn.client}
        while conn.action is None:
            if self.fault.mode == "blackhole":
                # Do not read: the bytes stay queued in the kernel, and the
                # sender stalls once its window is full, as on a dead link.
                self._wait(conn, POLL)
                continue
            readable, _, _ = select.select(list(peer), [], [], POLL)
            fault = self.fault  # after the wait: it may have changed meanwhile
            for src in readable:
                size = CHUNK
                if fault.mode == "slow" and fault.rate:
                    # Small chunks keep the throttled stream smooth.
                    size = max(1, min(CHUNK, fault.rate // 10))
                data = src.recv(size)
                if not data:
                    return
                if fault.mode == "slow":
                    pause = fault.delay_ms / 1000
                    if fault.rate:
                        pause += len(data) / fault.rate
                    if not self._wait(conn, pause):
                        return
                peer[src].sendall(data)

    def _close(self, conn: _Conn) -> None:
        if conn.action == "reset":
            # SO_LINGER with a zero timeout turns close() into an RST.
            conn.client.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                                   struct.pack("ii", 1, 0))
        for sock in (conn.client, conn.upstream):
            if sock is None:
                continue
            try:
                sock.close()
            except OSError:
                pass

    def status(self) -> str:
        with self._lock:
            open_ = len(self.conns)
        host, port = self.listen
        return (f"{self.name:<6} {host}:{port} -> {self.target[0]}:{self.target[1]}"
                f"  mode={self.fault.describe()}  open={open_} total={self.total}")


class Proxy:
    def __init__(self, routes: dict[str, tuple[tuple[str, int], tuple[str, int]]],
                 log: Callable[[str], None] = print):
        """routes maps a protocol name to (listen address, target address)."""
        self.log = log
        self.listeners = {name: Listener(name, listen, target, self)
                          for name, (listen, target) in routes.items()}
        self._lock = threading.Lock()

    def start(self) -> None:
        for listener in self.listeners.values():
            listener.start()

    def stop(self) -> None:
        for listener in self.listeners.values():
            listener.set(Fault("down"))

    def set(self, mode: str, proto: str = "all", delay_ms: int = 0,
            rate: int = 0) -> str:
        if mode not in MODES:
            raise ValueError(f"mode must be one of {', '.join(MODES)}, got {mode!r}")
        if proto == "all":
            names = list(self.listeners)
        elif proto in self.listeners:
            names = [proto]
        else:
            raise ValueError(f"proto must be all or one of "
                             f"{', '.join(self.listeners)}, got {proto!r}")
        if delay_ms < 0 or rate < 0:
            raise ValueError("delay_ms and rate must not be negative")
        if mode == "slow" and not (delay_ms or rate):
            delay_ms = 500
        lines = []
        with self._lock:
            for name in names:
                listener = self.listeners[name]
                before = listener.fault.describe()
                fault = Fault(mode, delay_ms, rate) if mode == "slow" else Fault(mode)
                closed = listener.set(fault)
                line = f"net {name}: {before} -> {fault.describe()}"
                if mode in ("down", "reset"):
                    line += f" ({'reset' if mode == 'reset' else 'closed'} {closed} connections)"
                    if mode == "reset":
                        line += ", now up"
                lines.append(line)
        for line in lines:
            self.log(line)
        return "\n".join(lines) + "\n"

    def status(self) -> str:
        return "\n".join(listener.status()
                         for listener in self.listeners.values()) + "\n"
