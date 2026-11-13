#!/usr/bin/env python3
"""
Lightweight static server for Flutter web build verification.
Workaround: `python -m http.server` on Python 3.14 + this host doesn't
bind correctly (socket goes straight to CLOSED). Direct TCPServer works.
"""
import http.server
import os
import socketserver
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "client_flutter", "build", "web")
PORT = 8765
HOST = "127.0.0.1"


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def end_headers(self):
        # Flutter web requires these COEP/COOP headers for SharedArrayBuffer
        # (used by some CanvasKit code paths). Harmless even when unused.
        self.send_header("Cross-Origin-Embedder-Policy", "credentialless")
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        # Disable caching during dev so refresh always sees fresh build
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


def main():
    if not os.path.isdir(ROOT):
        print(f"ROOT does not exist: {ROOT}", file=sys.stderr)
        sys.exit(1)
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer((HOST, PORT), Handler) as httpd:
        print(f"serving {ROOT} at http://{HOST}:{PORT}/", flush=True)
        httpd.serve_forever()


if __name__ == "__main__":
    main()
