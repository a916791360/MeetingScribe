#!/usr/bin/env python3
"""Loopback-only audit fixtures. Records only synthetic requests from audit tests."""
import http.server
import json
import pathlib
import sys
import threading

root = pathlib.Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
lock = threading.Lock()
marker = "REVIEW_SYNTHETIC_CREDENTIAL_NOT_A_REAL_KEY"

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.handle_request()

    def do_POST(self):
        self.handle_request()

    def handle_request(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        with lock, (root / "requests.jsonl").open("a") as log:
            log.write(json.dumps({"port": self.server.server_port, "path": self.path,
                                  "authorization": self.headers.get("Authorization"),
                                  "body": body.decode("utf-8", errors="replace")}) + "\n")
        mode = self.path.split("/")[1]
        if mode == "redirect" or mode.startswith("redirect-"):
            code = int(mode.split("-")[-1]) if mode.split("-")[-1].isdigit() else 307
            target = f"http://127.0.0.1:{recipient.server_port}/receive/chat/completions"
            if mode == "redirect-host":
                target = f"http://localhost:{origin.server_port}/receive/chat/completions"
            elif mode == "redirect-scheme":
                target = f"https://127.0.0.1:{origin.server_port}/receive/chat/completions"
            elif mode == "redirect-relative":
                target = "/buffered/chat/completions"
            self.send_response(code)
            self.send_header("Location", target)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path.startswith("/error/"):
            payload = json.dumps({"error": {"message": "debug Authorization: Bearer " + marker}}).encode()
            self.reply(500, "application/json", payload)
            return
        if self.path.startswith("/oversize/"):
            self.reply(200, "application/json", b"x" * (2 * 1024 * 1024 + 1))
            return
        facts = json.dumps({"headline": "合成结论：测试已完成", "overview": "审查合成材料的处理结果", "confidence": 0.9}, ensure_ascii=False)
        request = json.loads(body) if body else {}
        prompt = request.get("messages", [{}])[-1].get("content", "")
        if "连接正常" in prompt:
            content = "连接正常"
        elif '只根据给定材料输出 JSON' in prompt:
            content = facts
        else:
            content = "合成纪要只输出了半句，后续内容尚未生成"
        if self.path.startswith("/buffered/"):
            payload = json.dumps({"choices": [{"message": {"content": content}, "finish_reason": "stop"}]}, ensure_ascii=False).encode()
            self.reply(200, "application/json", payload)
            return
        chunk = {"choices": [{"delta": {"content": content}, "finish_reason": None}]}
        payload = "data: " + json.dumps(chunk, ensure_ascii=False) + "\n\n"
        if self.path.startswith("/malformed/"):
            payload += "data: {malformed-event}\n\n"
        elif not self.path.startswith("/eof/"):
            payload += 'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n'
        self.reply(200, "text/event-stream", payload.encode())

    def reply(self, status, content_type, payload):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass  # The response-limit test intentionally cancels reading.

origin = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
recipient = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=recipient.serve_forever, daemon=True).start()
(root / "ports.json").write_text(json.dumps({"origin": origin.server_port, "recipient": recipient.server_port}))
origin.serve_forever()
