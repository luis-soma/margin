#!/usr/bin/env python3
"""A stand-in for Figma's desktop MCP server, for Margin's tests.

Speaks MCP over Streamable HTTP like http://127.0.0.1:3845/mcp does.
Prints the port it listens on as the first line of stdout.

Options:
  --sse            answer with Server-Sent Events and keep the stream open
  --images url     get_screenshot answers with a URL instead of base64
  --selection X    'block' (default): "Currently selected nodes:" block
                   'xml': old servers, XML of the selection
                   'none': nothing selected
  --legacy         call the screenshot tool get_image (older servers)
  --motion         the selected frame has animation (get_motion_context)
  --video          offer export_video (renders after one "processing" reply)
"""
import argparse
import base64
import json
import struct
import sys
import threading
import time
import uuid
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def tiny_png(width=4, height=3):
    raw = b"".join(b"\x00" + b"\xff\x00\x00" * width for _ in range(height))

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw))
            + chunk(b"IEND", b""))


PNG = tiny_png()
MP4 = b"\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2" + b"\x00" * 64
video_jobs = set()
args = None
sessions = set()
calls = []


def metadata_text(node_id):
    if args.selection == "none":
        return '<canvas id="0:1" name="Page 1" />\n<canvas id="5:0" name="Archive" />'
    if node_id and node_id.replace("-", ":") == "0:1":
        selected = "" if args.selection == "xml" else "Currently selected nodes:\n- 12:34 Home &amp; Hero (FRAME)\n\n"
        return selected + '<canvas id="0:1" name="Page 1">\n  <frame id="12:34" name="Home &amp; Hero" x="0" y="0" width="1440" height="900" />\n</canvas>'
    if node_id:
        return '<frame id="%s" name="Home &amp; Hero" x="0" y="0" width="1440" height="900">\n  <text id="12:35" name="Title" />\n</frame>' % node_id.replace("-", ":")
    if args.selection == "xml":
        return '<frame id="12:34" name="Home &amp; Hero" x="0" y="0" width="1440" height="900" />'
    return 'Currently selected nodes:\n- 12:34 Home & Hero (FRAME)\n\nPages:\n<canvas id="0:1" name="Page 1" />'


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path.startswith("/video.mp4"):
            self.send_response(200)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Content-Length", str(len(MP4)))
            self.end_headers()
            self.wfile.write(MP4)
            return
        if self.path.startswith("/shot.png"):
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(PNG)))
            self.end_headers()
            self.wfile.write(PNG)
        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        message = json.loads(self.rfile.read(length) or b"{}")
        method = message.get("method")
        session = self.headers.get("Mcp-Session-Id")
        accept = self.headers.get("Accept", "")
        calls.append(method)

        if "text/event-stream" not in accept or "application/json" not in accept:
            return self.reply_status(406, "Accept must list application/json and text/event-stream")

        if method == "initialize":
            session = str(uuid.uuid4())
            sessions.add(session)
            return self.reply(message["id"], {
                "protocolVersion": "2025-06-18",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "Figma Dev Mode MCP (mock)", "version": "1.0"},
            }, session)

        if session not in sessions:
            return self.reply_status(400, "Bad Request: No valid session ID provided")
        if self.headers.get("MCP-Protocol-Version") != "2025-06-18":
            return self.reply_status(400, "missing MCP-Protocol-Version")

        if "id" not in message:  # notification
            return self.reply_status(202, "")

        if method == "tools/list":
            shot = "get_image" if args.legacy else "get_screenshot"
            shot_props = {"nodeId": {"type": "string"}, "clientLanguages": {"type": "string"}, "clientFrameworks": {"type": "string"}}
            if not args.legacy:
                shot_props["enableBase64Response"] = {"type": "boolean"}
                shot_props["maxDimension"] = {"type": "integer"}
            extra = []
            extra.append({"name": "get_motion_context", "inputSchema": {"type": "object", "properties": {"nodeId": {"type": "string"}, "fileKey": {"type": "string"}, "recursive": {"type": "boolean"}}, "required": ["nodeId"]}})
            if args.video:
                extra.append({"name": "export_video", "inputSchema": {"type": "object", "properties": {"nodeId": {"type": "string"}, "jobId": {"type": "string"}, "fileKey": {"type": "string"}, "quality": {"type": "string"}, "ttlSeconds": {"type": "integer"}}, "required": []}})
            return self.reply(message["id"], {"tools": extra + [
                {"name": "get_design_context", "inputSchema": {"type": "object", "properties": {"nodeId": {"type": "string"}}}},
                {"name": "get_metadata", "inputSchema": {"type": "object", "properties": {"nodeId": {"type": "string"}, "clientLanguages": {"type": "string"}, "clientFrameworks": {"type": "string"}}}},
                {"name": shot, "inputSchema": {"type": "object", "properties": shot_props, "required": []}},
            ]})

        if method == "tools/call":
            name = message["params"]["name"]
            arguments = message["params"].get("arguments", {})
            if name == "get_motion_context":
                node = arguments.get("nodeId")
                if args.motion and arguments.get("recursive"):
                    body = {"nodes": [{"nodeId": "139:223", "nodeName": "margin", "nodeType": "FRAME", "codeSnippets": {"css": "animation: kf 2s linear;", "motionDev": "<motion.div />"}}]}
                else:
                    body = {"nodes": [{"nodeId": node, "nodeName": "desktop", "nodeType": "FRAME", "timelineDurationMs": None, "transformOrigin": {"x": 0.5, "y": 0.5}, "motionSummary": None, "codeSnippets": {}}]}
                return self.reply(message["id"], {"content": [{"type": "text", "text": json.dumps(body)}]})
            if name == "export_video":
                port = self.server.server_address[1]
                if arguments.get("jobId") in video_jobs:
                    return self.reply(message["id"], {"content": [{"type": "text", "text": json.dumps({"downloadUrl": "http://127.0.0.1:%d/video.mp4" % port, "availableUntil": "2026-10-17T17:38:11Z", "instructions": "Download it."})}]})
                job = str(uuid.uuid4())
                video_jobs.add(job)
                return self.reply(message["id"], {"content": [{"type": "text", "text": json.dumps({"jobId": job, "status": "processing"})}]})
            if name == "get_metadata":
                return self.reply(message["id"], {"content": [{"type": "text", "text": metadata_text(arguments.get("nodeId"))}]})
            if name in ("get_screenshot", "get_image"):
                if args.selection == "none" and not arguments.get("nodeId"):
                    return self.reply(message["id"], {"isError": True, "content": [{"type": "text", "text": "Nothing is selected. Select a layer in Figma."}]})
                if arguments.get("enableBase64Response") or args.legacy:
                    if args.images != "url":
                        return self.reply(message["id"], {"content": [
                            {"type": "text", "text": json.dumps({"width": 4, "height": 3})},
                            {"type": "image", "data": base64.b64encode(PNG).decode(), "mimeType": "image/png"},
                        ]})
                port = self.server.server_address[1]
                return self.reply(message["id"], {"content": [{"type": "text", "text":
                    "Screenshot ready: http://127.0.0.1:%d/shot.png\nDownload with: curl -o shot.png 'http://127.0.0.1:%d/shot.png'" % (port, port)}]})
            return self.reply(message["id"], {"isError": True, "content": [{"type": "text", "text": "unknown tool"}]})

        return self.reply_error(message["id"], -32601, "Method not found")

    def reply_status(self, code, text):
        body = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def reply_error(self, id_, code, text):
        self.send_json({"jsonrpc": "2.0", "id": id_, "error": {"code": code, "message": text}}, None)

    def reply(self, id_, result, session=None):
        self.send_json({"jsonrpc": "2.0", "id": id_, "result": result}, session)

    def send_json(self, payload, session):
        if args.sse:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            if session:
                self.send_header("Mcp-Session-Id", session)
            self.send_header("Connection", "close")
            self.end_headers()
            # A notification first, like servers that stream progress.
            self.wfile.write(b'event: message\ndata: {"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"working"}}\n\n')
            # Spread the JSON over several data lines, which SSE allows: the
            # client joins them with newlines, which JSON treats as whitespace.
            lines = json.dumps(payload, indent=1).split("\n")
            self.wfile.write(("event: message\n" + "".join("data: %s\n" % line for line in lines) + "\n").encode())
            self.wfile.flush()
            # Keep the stream open: the client must not wait for it to end.
            time.sleep(4)
            self.close_connection = True
        else:
            body = json.dumps(payload).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            if session:
                self.send_header("Mcp-Session-Id", session)
            self.end_headers()
            self.wfile.write(body)


def main():
    global args
    parser = argparse.ArgumentParser()
    parser.add_argument("--sse", action="store_true")
    parser.add_argument("--images", default="base64")
    parser.add_argument("--selection", default="block")
    parser.add_argument("--legacy", action="store_true")
    parser.add_argument("--motion", action="store_true")
    parser.add_argument("--video", action="store_true")
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    print(server.server_address[1], flush=True)
    # Exit when the test process goes away.
    threading.Thread(target=lambda: (sys.stdin.read(), server.shutdown()), daemon=True).start()
    server.serve_forever()


if __name__ == "__main__":
    main()
