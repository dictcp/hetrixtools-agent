#!/usr/bin/env python3
"""
End-to-end test for the OutgoingPings / oping payload feature.

Covers:
  - ICMP ping (to 127.0.0.1 loopback) — runs concurrently with stats collection
  - TCP port ping (to an ephemeral localhost listener started by this test)

The test builds the Nim agent, configures OutgoingPings with both an ICMP and a
TCP entry, runs the agent once, and asserts the oping field contains valid results
with 0% packet loss for both reachable targets.
"""

import base64
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading

sys.path.insert(0, os.path.dirname(__file__))
from server_fixture import CaptureServer

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
NIM_SOURCE = os.path.join(ROOT, "hetrixtools_agent.nim")
CFG_TEMPLATE = os.path.join(ROOT, "hetrixtools.cfg")


# ── Helpers ──────────────────────────────────────────────────────────────────

def build_nim(tmpdir):
    nim = shutil.which("nim")
    if not nim:
        raise RuntimeError("nim compiler not found — skipping oping test")
    out_bin = os.path.join(tmpdir, "hetrixtools_agent_oping")
    subprocess.check_call(
        [nim, "c", "-d:release", "--opt:speed", "-o:" + out_bin, NIM_SOURCE],
        cwd=ROOT,
    )
    return out_bin


def find_free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        return s.getsockname()[1]


def parse_oping(oping_b64):
    """Decode base64 oping field into a list of result dicts."""
    raw = base64.b64decode(oping_b64).decode("utf-8")
    results = []
    for entry in raw.split(";"):
        entry = entry.strip()
        if not entry:
            continue
        parts = entry.split(",")
        assert len(parts) == 4, f"unexpected oping entry format: {entry!r}"
        results.append({
            "name":   parts[0],
            "target": parts[1],
            "loss":   int(parts[2]),
            "rtt":    int(parts[3]),
        })
    return results


# ── TCP listener ─────────────────────────────────────────────────────────────

class TcpListener:
    """Minimal TCP server that accepts and immediately closes connections."""

    def __init__(self, port):
        self.port = port
        self._sock = None
        self._thread = None
        self._stop = threading.Event()

    def start(self):
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._sock.bind(("127.0.0.1", self.port))
        self._sock.listen(32)
        self._sock.settimeout(1.0)
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def _serve(self):
        while not self._stop.is_set():
            try:
                conn, _ = self._sock.accept()
                conn.close()
            except socket.timeout:
                continue
            except OSError:
                break

    def stop(self):
        self._stop.set()
        if self._sock:
            try:
                self._sock.close()
            except OSError:
                pass
        if self._thread:
            self._thread.join(timeout=3)


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    tcp_port = find_free_port()
    listener = TcpListener(tcp_port)
    listener.start()

    try:
        with tempfile.TemporaryDirectory() as tmp:
            nim_bin = build_nim(tmp)

            work_dir = os.path.join(tmp, "run")
            os.makedirs(work_dir)

            cfg = open(CFG_TEMPLATE, "r", encoding="utf-8").read()
            cfg = cfg.replace('SID=""', 'SID="0123456789abcdef0123456789abcdef"')
            cfg = cfg.replace("CollectEveryXSeconds=3", "CollectEveryXSeconds=2")
            cfg = cfg.replace(
                'OutgoingPings=""',
                (
                    f'OutgoingPings="loopback_a,127.0.0.1|'
                    f'tcptest_a,127.0.0.1,{tcp_port}|'
                    f'loopback_b,127.0.0.1|'
                    f'tcptest_b,127.0.0.1,{tcp_port}"'
                ),
            )
            cfg = cfg.replace("OutgoingPingsCount=20", "OutgoingPingsCount=10")

            cfg_path = os.path.join(work_dir, "hetrixtools.cfg")
            log_path = os.path.join(work_dir, "hetrixtools_agent.log")
            open(cfg_path, "w", encoding="utf-8").write(cfg)

            server = CaptureServer()
            server.start()
            try:
                env = os.environ.copy()
                env["HETRIXTOOLS_POST_URL"] = server.url()
                subprocess.check_call(
                    [
                        nim_bin,
                        "--once",
                        f"--config={cfg_path}",
                        f"--log={log_path}",
                    ],
                    cwd=work_dir,
                    env=env,
                )
            finally:
                server.stop()

            payload = server.last_payload()
            assert payload is not None, "Nim agent did not POST to capture server"

            # ── oping field must be present and non-empty ──────────────────
            oping_b64 = payload.get("oping", "")
            assert oping_b64, "oping field is missing or empty in the agent payload"

            results = parse_oping(oping_b64)
            assert len(results) == 4, (
                f"expected 4 oping results (2 ICMP + 2 TCP), got {len(results)}: {results}"
            )
            assert [r["name"] for r in results] == [
                "tcptest_a",
                "tcptest_b",
                "loopback_a",
                "loopback_b",
            ], (
                "oping results should emit TCP entries first, then ICMP entries, "
                f"preserving config order within each group: {results}"
            )

            # ── ICMP result ────────────────────────────────────────────────
            icmp_results = [r for r in results if r["name"].startswith("loopback_")]
            for icmp in icmp_results:
                assert icmp["target"] == "127.0.0.1", (
                    f"unexpected ICMP target: {icmp['target']!r}"
                )
                assert icmp["loss"] == 0, (
                    f"{icmp['name']} ICMP ping reported {icmp['loss']}% packet loss (expected 0%)"
                )
                assert icmp["rtt"] >= 0, f"{icmp['name']} ICMP RTT is negative: {icmp['rtt']}"

            # ── TCP result ─────────────────────────────────────────────────
            tcp_results = [r for r in results if r["name"].startswith("tcptest_")]
            for tcp in tcp_results:
                assert tcp["target"] == f"127.0.0.1_{tcp_port}", (
                    f"unexpected TCP target: {tcp['target']!r}"
                )
                assert tcp["loss"] == 0, (
                    f"{tcp['name']} TCP ping reported {tcp['loss']}% packet loss (expected 0%)"
                )
                assert tcp["rtt"] >= 0, f"{tcp['name']} TCP RTT is negative: {tcp['rtt']}"
                assert tcp["rtt"] < 1_000_000, (
                    f"{tcp['name']} TCP RTT unreasonably large: {tcp['rtt']} µs"
                )

            print(f"PASS: oping order — {[r['name'] for r in results]}")
            print(f"PASS: ICMP loopback results — {icmp_results}")
            print(f"PASS: TCP 127.0.0.1:{tcp_port} results — {tcp_results}")

    finally:
        listener.stop()


if __name__ == "__main__":
    main()
