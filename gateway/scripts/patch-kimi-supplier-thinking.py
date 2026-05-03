#!/usr/bin/env python3
"""Patch the kimi run-mlx-server.sh to set enable_thinking=false."""
import os, pathlib, re, subprocess, sys

candidates = [
    pathlib.Path("/Users/tailor512/teale-kimi-q8/run-mlx-server.sh"),
    pathlib.Path("/Users/tailor512g1/teale-kimi-q8/run-mlx-server.sh"),
]
target = next((p for p in candidates if p.exists()), None)
if target is None:
    sys.exit("could not find run-mlx-server.sh")

s = target.read_text()
# Strip any prior --chat-template-args lines (prevents stacking on re-run).
s = re.sub(r"\n\s*--chat-template-args [^\n]*\\\n", "\n", s)
# Insert the false-thinking arg right after the --min-p line. Use a literal
# replacement string with no backslash-escapes — mlx_lm.server needs real
# double quotes inside the single-quoted arg.
INJECT = "  --chat-template-args '{\"enable_thinking\": false}' \\\n"
def repl(m):
    return m.group(0) + INJECT
s = re.sub(r"--min-p [\d\.]+ \\\n", repl, s, count=1)
target.write_text(s)

for i, line in enumerate(s.splitlines(), 1):
    if "min-p" in line or "enable_thinking" in line:
        print(f"  L{i}: {line}")

uid = os.getuid()
r = subprocess.run(
    ["launchctl", "kickstart", "-k", f"gui/{uid}/com.teale.kimi-k26-mlx-server"],
    capture_output=True, text=True,
)
print(f"kickstart rc={r.returncode}", r.stderr.strip() or "OK")
