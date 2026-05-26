"""In-process HTTP capture server for use in tests."""
import base64
import gzip
import json
import socket
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs


def _find_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        return s.getsockname()[1]


def _decode_post_body(raw_body: str) -> dict:
    data = parse_qs(raw_body, keep_blank_values=True, strict_parsing=False)
    encoded = data.get("j", [""])[0]
    gz_bytes = base64.b64decode(encoded)
    payload = gzip.decompress(gz_bytes).decode("utf-8")
    return json.loads(payload)


class CaptureServer:
    """Minimal HTTP server that captures POST payloads for testing.

    Usage::

        server = CaptureServer()
        server.start()
        try:
            env = os.environ.copy()
            env["HETRIXTOOLS_POST_URL"] = server.url()
            subprocess.check_call([agent, "--once", ...], env=env)
        finally:
            server.stop()

        payload = server.last_payload()
        assert payload is not None
    """

    def __init__(self):
        self._payloads: list = []
        self._lock = threading.Lock()
        self._server: HTTPServer | None = None
        self._thread: threading.Thread | None = None
        self.port: int | None = None

    def start(self) -> None:
        self.port = _find_free_port()
        parent = self

        class _Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers.get("Content-Length", "0"))
                raw = self.rfile.read(length).decode("utf-8", errors="replace")
                try:
                    payload = _decode_post_body(raw)
                    with parent._lock:
                        parent._payloads.append(payload)
                    body = b'{"ok":true}\n'
                    self.send_response(200)
                except Exception:
                    body = b'{"error":"decode failed"}\n'
                    self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, fmt, *args):
                pass

        self._server = HTTPServer(("127.0.0.1", self.port), _Handler)
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        if self._server:
            self._server.shutdown()

    def url(self) -> str:
        return f"http://127.0.0.1:{self.port}/v2/"

    def last_payload(self) -> dict | None:
        with self._lock:
            return self._payloads[-1] if self._payloads else None

    def all_payloads(self) -> list:
        with self._lock:
            return list(self._payloads)
