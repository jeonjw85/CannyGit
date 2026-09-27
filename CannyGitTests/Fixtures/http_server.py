"""Isolated HTTP fixture: random loopback port, no external requests or files."""
import http.server
import json
import os
import threading


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"directory": os.getcwd()}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
deadline = threading.Timer(30, server.shutdown)
deadline.daemon = True
deadline.start()
print(f"http://127.0.0.1:{server.server_port}", flush=True)
try:
    server.serve_forever(poll_interval=0.05)
except KeyboardInterrupt:
    pass
finally:
    deadline.cancel()
    server.server_close()
