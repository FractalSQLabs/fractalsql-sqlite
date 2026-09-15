"""tests/_mock_llm_server.py — deterministic OpenAI-chat-completions-shaped
HTTP stub for fuzz-testing fractal_text_to_sql() without a real LLM.

fractalsql-reasoning-http only speaks OpenAI chat-completions JSON
regardless of provider, so a stub that always returns one canned response
is enough to drive fractal_text_to_sql() into every ALLOWLIST/EXPLAIN
rejection path deterministically -- real models are unreliable for
eliciting one SPECIFIC adversarial output on demand, which is exactly what
fuzz testing needs.

HTTPServer(...) binds the socket synchronously in its constructor, so by
the time __enter__ returns the port is genuinely listening -- no
sleep-and-hope startup race for callers (that exact bug class already bit
fractalsql-reasoning-http's own arm64 test suite once; do not reintroduce
it here).
"""
import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer


class MockLLMServer:
    """Always answers every POST with the same canned assistant message."""

    def __init__(self, content: str):
        self._content = content
        self._httpd = None
        self._thread = None
        self.port = None

    def __enter__(self):
        content = self._content

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, fmt, *args):
                pass  # keep test output quiet

            def do_POST(self):
                length = int(self.headers.get("Content-Length", 0))
                self.rfile.read(length)  # drain the request body, unused
                body = json.dumps({
                    "choices": [{"message": {"content": content}}]
                }).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        self._httpd = HTTPServer(("127.0.0.1", 0), Handler)
        self.port = self._httpd.server_address[1]
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)
        self._thread.start()
        return self

    @property
    def url(self):
        return f"http://127.0.0.1:{self.port}/v1/chat/completions"

    def __exit__(self, *exc):
        if self._httpd is not None:
            self._httpd.shutdown()
            self._httpd.server_close()
        return False


class MockEmbedServer:
    """Deterministic OpenAI-embeddings-shaped HTTP stub for testing
    fractal_embed() / the vectorizer without a real embedding provider.

    Same synchronous-bind-in-constructor / serve_forever-in-a-background-
    thread shape as MockLLMServer above (one instance serves any number
    of requests during the `with` block, not just one) -- reused here
    rather than duplicated because the only real difference is the
    response body shape (data[0].embedding vs. choices[0].message.content).

    body=None (the default) serves the real success shape. Pass a raw
    dict for body to test how fractal_embed()/fractal_vectorizer_
    process_queue() handle a malformed response (e.g. missing the
    "data" key entirely) -- exercises fractalsql-reasoning-http's own
    extract_embedding() failure path for real, not just this
    extension's own "no plugin configured" precondition checks.
    """

    def __init__(self, vector: list[float] | None = None, body: dict | None = None):
        if body is not None:
            self._body = body
        else:
            self._body = {"data": [{"embedding": vector if vector is not None else [0.1, 0.2, 0.3]}]}
        self._httpd = None
        self._thread = None
        self.port = None

    def __enter__(self):
        body_bytes = json.dumps(self._body).encode("utf-8")

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, fmt, *args):
                pass  # keep test output quiet

            def do_POST(self):
                length = int(self.headers.get("Content-Length", 0))
                self.rfile.read(length)  # drain the request body, unused
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body_bytes)))
                self.end_headers()
                self.wfile.write(body_bytes)

        self._httpd = HTTPServer(("127.0.0.1", 0), Handler)
        self.port = self._httpd.server_address[1]
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)
        self._thread.start()
        return self

    @property
    def url(self):
        return f"http://127.0.0.1:{self.port}/v1/embeddings"

    def __exit__(self, *exc):
        if self._httpd is not None:
            self._httpd.shutdown()
            self._httpd.server_close()
        return False


if __name__ == "__main__":
    # CI runner: serve one canned chat reply forever so the easy_install workflows
    # can point the reasoning plugin at it. Prints the bound port on
    # stdout (single line, flushed) and blocks until killed.
    import sys
    import threading

    reply = sys.argv[1] if len(sys.argv) > 1 else "pong-from-mock"
    with MockLLMServer(reply) as mock:
        print(mock.port, flush=True)
        threading.Event().wait()  # serve until the CI job kills us
