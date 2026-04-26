#!/usr/bin/env python3
import argparse
import json
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def build_app(device: str):
    try:
        from opf._api import OPF
    except Exception as exc:  # pragma: no cover - import failure path depends on host
        return {"ready": False, "error": f"failed to import opf: {exc}", "redactor": None}

    try:
        redactor = OPF(device=device, output_mode="typed", output_text_only=False)
        redactor.get_runtime()
        return {"ready": True, "error": None, "redactor": redactor}
    except Exception as exc:  # pragma: no cover - runtime failure path depends on host
        return {"ready": False, "error": f"failed to initialize opf: {exc}", "redactor": None}


class Handler(BaseHTTPRequestHandler):
    state = None
    state_lock = threading.Lock()

    def log_message(self, format, *args):  # noqa: A003 - stdlib signature
        return

    def _json(self, status: int, payload: dict):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802 - stdlib signature
        if self.path != "/health":
            self._json(HTTPStatus.NOT_FOUND, {"ok": False, "error": "not found"})
            return

        with self.state_lock:
            ready = bool(self.state["ready"])
            error = self.state["error"]

        self._json(
            HTTPStatus.OK,
            {
                "ok": True,
                "ready": ready,
                "device": self.server.device,
                "output_mode": "typed",
                "error": error,
            },
        )

    def do_POST(self):  # noqa: N802 - stdlib signature
        if self.path != "/v1/redact":
            self._json(HTTPStatus.NOT_FOUND, {"ok": False, "error": "not found"})
            return

        try:
            content_length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._json(HTTPStatus.BAD_REQUEST, {"ok": False, "error": "invalid content length"})
            return

        raw = self.rfile.read(content_length)
        try:
            payload = json.loads(raw.decode("utf-8"))
        except Exception:
            self._json(HTTPStatus.BAD_REQUEST, {"ok": False, "error": "invalid json payload"})
            return

        text = payload.get("text")
        if not isinstance(text, str):
            self._json(HTTPStatus.BAD_REQUEST, {"ok": False, "error": "`text` must be a string"})
            return

        with self.state_lock:
            ready = bool(self.state["ready"])
            error = self.state["error"]
            redactor = self.state["redactor"]

        if not ready or redactor is None:
            self._json(
                HTTPStatus.SERVICE_UNAVAILABLE,
                {"ok": False, "error": error or "privacy filter is not ready"},
            )
            return

        try:
            result = redactor.redact(text)
            spans = [
                {
                    "label": span.label,
                    "start": span.start,
                    "end": span.end,
                    "text": span.text,
                }
                for span in result.detected_spans
            ]
            self._json(HTTPStatus.OK, {"ok": True, "spans": spans})
        except Exception as exc:  # pragma: no cover - depends on runtime
            self._json(
                HTTPStatus.INTERNAL_SERVER_ERROR,
                {"ok": False, "error": f"redaction failed: {exc}"},
            )


def main():
    parser = argparse.ArgumentParser(description="Local helper for OpenAI Privacy Filter")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=11439)
    parser.add_argument("--device", default="cpu")
    args = parser.parse_args()

    Handler.state = build_app(args.device)

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.device = args.device
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
