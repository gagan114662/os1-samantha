#!/usr/bin/env python3
"""Run WUPHF behind a localhost proxy that owns native OS1 webhook routes."""

from __future__ import annotations

import argparse
import http.client
import json
import shutil
import signal
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOP_BY_HOP_HEADERS = {
    "connection",
    "content-length",
    "host",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
}

SAFE_CONTENT_TYPES = {
    "application/javascript": "application/javascript",
    "application/json": "application/json; charset=utf-8",
    "image/jpeg": "image/jpeg",
    "image/png": "image/png",
    "image/svg+xml": "image/svg+xml",
    "image/x-icon": "image/x-icon",
    "text/css": "text/css; charset=utf-8",
    "text/html": "text/html; charset=utf-8",
    "text/javascript": "text/javascript",
    "text/plain": "text/plain; charset=utf-8",
}


class ProxyState:
    def __init__(self, upstream_port: int, voice_port_file: Path) -> None:
        self.upstream_port = upstream_port
        self.voice_port_file = voice_port_file

    def voice_port(self) -> int:
        path = self.voice_port_file
        if not path.exists():
            legacy_path = path.with_name("voice-port")
            if legacy_path.exists():
                path = legacy_path
        return int(path.read_text(encoding="utf-8").strip())


class WuphfProxyHandler(BaseHTTPRequestHandler):
    server_version = "OS1WuphfStripeProxy/1.0"
    state: ProxyState

    def log_message(self, fmt: str, *args: object) -> None:
        sys.stdout.write("INFO wuphf_proxy " + (fmt % args) + "\n")
        sys.stdout.flush()

    def do_GET(self) -> None:
        if self.path.split("?", 1)[0] == "/api/stripe/status":
            self.forward_to_voice()
        else:
            self.forward_to_wuphf()

    def do_POST(self) -> None:
        if self.path.split("?", 1)[0] == "/webhooks/stripe":
            self.forward_to_voice(log_stripe=True)
        else:
            self.forward_to_wuphf()

    def forward_to_voice(self, log_stripe: bool = False) -> None:
        try:
            port = self.state.voice_port()
        except Exception as exc:
            self.send_json_error(502, f"OS1 voice server unavailable: {exc}")
            return
        self.forward("127.0.0.1", port, log_stripe=log_stripe)

    def forward_to_wuphf(self) -> None:
        self.forward("127.0.0.1", self.state.upstream_port)

    def forward(self, host: str, port: int, log_stripe: bool = False) -> None:
        body = self.rfile.read(int(self.headers.get("Content-Length", "0") or "0"))
        headers = {
            key: value
            for key, value in self.headers.items()
            if key.lower() not in HOP_BY_HOP_HEADERS
        }
        headers["Host"] = f"{host}:{port}"
        try:
            conn = http.client.HTTPConnection(host, port, timeout=30)
            conn.request(self.command, self.path, body=body, headers=headers)
            response = conn.getresponse()
            response_body = response.read()
        except Exception as exc:
            self.send_json_error(502, f"Upstream unavailable: {exc}")
            return

        if log_stripe:
            fields = [f"INFO stripe_webhook status={response.status}", f"path={self.path}"]
            try:
                payload = json.loads(response_body.decode("utf-8"))
                if payload.get("event_id"):
                    fields.append(f"id={payload['event_id']}")
                if payload.get("event_type"):
                    fields.append(f"event={payload['event_type']}")
                if payload.get("company_id"):
                    fields.append(f"company={payload['company_id']}")
            except json.JSONDecodeError:
                fields.append("parse_error=true")
            sys.stdout.write(" ".join(fields) + "\n")
            sys.stdout.flush()

        self.send_response(response.status, response.reason)
        self.send_header("Content-Type", safe_content_type(response.getheader("Content-Type")))
        self.send_header("Content-Length", str(len(response_body)))
        self.end_headers()
        self.wfile.write(response_body)

    def send_json_error(self, status: int, message: str) -> None:
        body = ('{"ok":false,"error":"' + message.replace('"', "'") + '"}\n').encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--public-port", type=int, default=7891)
    parser.add_argument("--upstream-port", type=int, default=7892)
    parser.add_argument("--voice-port-file", default=str(Path.home() / ".os1/local-server-port"))
    parser.add_argument("--wuphf-bin", default=shutil.which("wuphf") or "/opt/homebrew/bin/wuphf")
    parser.add_argument("wuphf_args", nargs=argparse.REMAINDER)
    return parser.parse_args()


def safe_content_type(value: str | None) -> str:
    if not value:
        return "application/octet-stream"
    media_type = value.split(";", 1)[0].strip().lower()
    return SAFE_CONTENT_TYPES.get(media_type, "application/octet-stream")


def main() -> int:
    args = parse_args()
    wuphf_args = args.wuphf_args[1:] if args.wuphf_args[:1] == ["--"] else args.wuphf_args
    command = [args.wuphf_bin, "--web-port", str(args.upstream_port), *wuphf_args]
    child = subprocess.Popen(command)

    def stop_child(_signum: int, _frame: object) -> None:
        child.terminate()
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop_child)
    signal.signal(signal.SIGINT, stop_child)

    WuphfProxyHandler.state = ProxyState(args.upstream_port, Path(args.voice_port_file))
    server = ThreadingHTTPServer(("127.0.0.1", args.public_port), WuphfProxyHandler)
    sys.stdout.write(
        f"INFO wuphf_proxy listening=127.0.0.1:{args.public_port} "
        f"wuphf=127.0.0.1:{args.upstream_port}\n"
    )
    sys.stdout.flush()
    try:
        server.serve_forever()
    finally:
        child.terminate()
        child.wait(timeout=10)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
