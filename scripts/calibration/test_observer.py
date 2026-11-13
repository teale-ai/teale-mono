import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCRIPT = Path(__file__).with_name("observe_llama.py")
spec = importlib.util.spec_from_file_location("observer", SCRIPT)
observer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(observer)


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        b = json.dumps({"content": "synthetic test response", "timings": {
            "predicted_n": 128, "predicted_ms": 2000}}).encode()
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b)

    def log_message(self, *args):
        pass


class Tests(unittest.TestCase):
    def test_origins(self):
        self.assertEqual(observer.local_url("http://127.0.0.1:12345"), "http://127.0.0.1:12345")
        for value in ["https://127.0.0.1:1", "http://localhost:1", "http://8.8.8.8:80",
                      "http://127.0.0.1:1/v1", "http://user:x@127.0.0.1:1"]:
            with self.assertRaises(ValueError):
                observer.local_url(value)

    def test_timings(self):
        self.assertEqual(observer.extract_timings({"timings": {"predicted_n": 100, "predicted_ms": 2000}})["serverReportedDecodeTps"], 50)
        for value in [{}, {"predicted_n": 0, "predicted_ms": 1},
                      {"predicted_n": True, "predicted_ms": 1},
                      {"predicted_n": 128, "predicted_ms": float("nan")},
                      {"predicted_n": 128, "predicted_ms": 0}]:
            self.assertIsNone(observer.extract_timings({"timings": value}))

    def test_binary_smoke_digest_and_no_overwrite(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as tmp:
                p = Path(tmp)
                (p / "model").write_bytes(b"synthetic model")
                (p / "binary").write_bytes(b"synthetic binary, never executed")
                (p / "prompt").write_text("synthetic prompt")
                identity = {"deviceId": "synthetic", "backendBinarySha256": observer.digest(p / "binary"),
                            "artifactSha256": observer.digest(p / "model"), "backendRevision": "synthetic",
                            "configurationSha256": "c" * 64, "contextTokens": 4096, "concurrency": 2}
                (p / "identity").write_text(json.dumps(identity))
                cmd = [sys.executable, str(SCRIPT), "--origin", f"http://127.0.0.1:{server.server_port}",
                       "--identity", str(p / "identity"), "--model-file", str(p / "model"),
                       "--binary-file", str(p / "binary"), "--prompt-file", str(p / "prompt"),
                       "--out", str(p / "result"), "--concurrency", "2"]
                subprocess.run(cmd, check=True, capture_output=True)
                result = json.loads((p / "result").read_text())
                self.assertEqual(result["verdict"], "not_calibrated")
                self.assertEqual(len(result["observations"]), 2)
                self.assertEqual(result["observations"][0]["generationCounters"]["decodeTokens"], 128)
                self.assertNotEqual(subprocess.run(cmd, capture_output=True).returncode, 0)
                (p / "model").write_bytes(b"changed model")
                (p / "result").unlink()
                self.assertNotEqual(subprocess.run(cmd, capture_output=True).returncode, 0)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    unittest.main()
