# Stand-in for the Python adapter of a runtime image: import the customer's module, then serve $PORT.
# It is PID 1 in the pod, and the kernel gives PID 1 no default action for SIGTERM: it exits on SIGTERM itself.
import http.server as h
import os
import signal
import sys

sys.path.insert(0, "/function")
import main  # noqa: E402


class H(h.BaseHTTPRequestHandler):
    def do_GET(self):
        r = main.handler({}, None)
        b = r["body"].encode()
        self.send_response(r["statusCode"])
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def log_message(self, *a):
        pass


signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
h.ThreadingHTTPServer(("", int(os.environ.get("PORT", "8080"))), H).serve_forever()
