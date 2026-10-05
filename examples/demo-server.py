#!/usr/bin/env python3
"""A disposable localhost HTTP server for trying Socket Manager."""
import argparse
import html
import http.server
import json
import signal
import socket

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--port", type=int, default=3001)
parser.add_argument("--bind", choices=["127.0.0.1", "::1"], default="127.0.0.1")
parser.add_argument("--name", default="Socket Manager demo")
parser.add_argument("--json", action="store_true", help="serve a JSON response")
parser.add_argument("--ignore-term", action="store_true", help="ignore SIGTERM to exercise SIGKILL escalation")
args = parser.parse_args()

if args.ignore_term:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if args.json:
            body = json.dumps({"server": args.name, "port": args.port, "status": "ok", "demo": True,
                               "items": [{"id": 1, "name": "Coffee"}, {"id": 2, "name": "Tea"}]}, indent=2).encode()
            content_type = "application/json; charset=utf-8"
        else:
            body = ("<!doctype html><html lang='en'><meta charset='utf-8'><title>" + html.escape(args.name)
                    + "</title><body><h1>" + html.escape(args.name) + "</h1><p>Disposable Socket Manager test server.</p>"
                    + "<p>Port: " + str(args.port) + "</p>"
                    + ("<p>Ignores SIGTERM. Socket Manager will escalate to SIGKILL after two seconds.</p>" if args.ignore_term else "")
                    + "</body></html>").encode()
            content_type = "text/html; charset=utf-8"
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class Server(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6 if args.bind == "::1" else socket.AF_INET


host = "[::1]" if args.bind == "::1" else args.bind
print(f"{args.name}: http://{host}:{args.port}/", flush=True)
Server((args.bind, args.port), Handler).serve_forever()
