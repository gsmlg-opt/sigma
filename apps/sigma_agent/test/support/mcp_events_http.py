"""Owned modern MCP Events fixture, including a two-wire MRTR page."""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

log_path = sys.argv[1]
pending = {}
lock = threading.RLock()
next_cursor = "  opaque/+next=汉字\r\n  "
page = {
    "resultType": "complete",
    "events": [
        {"name": "second", "title": "Changed e\u0301 👩‍💻\r\n", "inputSchema": True,
         "payloadSchema": False, "_meta": {"order": 2}},
        {"name": "first", "payloadSchema": {"type": "object", "additionalProperties": True}},
    ],
    "nextCursor": next_cursor,
    "_meta": {"exact": [2, True, None, "  Unicode 汉字\r\n第二行\n"]},
}


def record(value):
    with lock:
        with open(log_path, "a", encoding="utf-8") as output:
            output.write(json.dumps(value, ensure_ascii=False) + "\n")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        wire = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        record(wire)
        method = wire.get("method")
        params = wire.get("params", {})
        if method == "notifications/cancelled":
            with lock:
                event = pending.get(params.get("requestId"))
            if event:
                event.set()
        if "id" not in wire:
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        identifier = wire["id"]
        if method == "server/discover":
            result = {"resultType": "complete", "supportedVersions": ["2026-07-28"],
                      "capabilities": {"events": {}, "resources": {}, "tools": {}},
                      "ttlMs": 0, "cacheScope": "private"}
        elif method == "tools/list":
            result = {"resultType": "complete", "tools": []}
        elif method == "events/list":
            cursor = params.get("cursor")
            if cursor in ["mrtr", "mrtr-cancel"] and params.get("requestState") != "continue":
                result = {"resultType": "input_required", "requestState": "continue"}
            else:
                if cursor == "mrtr-cancel":
                    event = threading.Event()
                    with lock:
                        pending[identifier] = event
                    record({"event": "pending", "id": identifier})
                    event.wait(20)
                result = ({"resultType": "complete", "events": [], "_meta": {"empty": True}}
                          if cursor == next_cursor else page)
            if cursor == "error":
                self.reply({"jsonrpc": "2.0", "id": identifier,
                            "error": {"code": -32603, "message": "actual Events fixture failure 汉字\r\n",
                                      "data": {"exact": [None, False, " é 👩‍💻\r\n"], "empty": {}}}})
                return
            if cursor == "domain-error":
                result = {"resultType": "complete", "isError": True, "events": [],
                          "_meta": {"cause": "domain 汉字\r\n", "values": [True, None]}}
        elif method == "resources/read":
            if params.get("uri") == "mem://survivor-pending":
                event = threading.Event()
                with lock:
                    pending[identifier] = event
                record({"event": "other_pending", "id": identifier})
                event.wait(20)
            if params.get("uri") == "mem://release":
                with lock:
                    for event in pending.values():
                        event.set()
            result = {"resultType": "complete", "contents": [{"uri": params.get("uri"), "text": "ready"}]}
        else:
            self.reply({"jsonrpc": "2.0", "id": identifier,
                        "error": {"code": -32601, "message": "Method not found"}})
            return
        self.reply({"jsonrpc": "2.0", "id": identifier, "result": result})

    def reply(self, value):
        body = json.dumps(value, ensure_ascii=False).encode()
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
threading.Thread(target=lambda: (sys.stdin.readline(), server.shutdown()), daemon=True).start()
print(server.server_port, flush=True)
server.serve_forever(poll_interval=0.05)
server.server_close()
