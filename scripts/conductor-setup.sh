#!/usr/bin/env bash

set -euo pipefail

mkdir -p .claude/skills

if [ ! -d .claude/skills/gstack/.git ]; then
  git clone https://github.com/garrytan/gstack.git .claude/skills/gstack
fi

(
  cd .claude/skills/gstack
  ./setup --host codex -q
)

swift build
