#!/usr/bin/env bash
# Stage 0: migrate teale-node + teale-mac-app into a single teale-mono repo
# with git history preserved via git-filter-repo.
#
# Destructive to /tmp/teale-* only; does NOT touch the real source repos
# under ~/conductor/repos/ and does NOT push to GitHub.
#
# Prerequisites:
#   pip3 install git-filter-repo
#   export PATH="$HOME/Library/Python/3.9/bin:$PATH"
#
# Usage:
#   bash scripts/migrate-to-teale-mono.sh [<dest>]
# Default dest: ~/conductor/repos/teale-mono
set -euo pipefail

DEST="${1:-$HOME/conductor/repos/teale-mono}"
WORK=$(mktemp -d /tmp/teale-mono-migrate-XXXXXX)
NODE_SRC="$HOME/conductor/repos/teale-node"
MACAPP_SRC="$HOME/conductor/repos/teale-mac-app"

if ! command -v git-filter-repo >/dev/null 2>&1; then
  echo "git-filter-repo not on PATH" >&2
  echo "install: pip3 install git-filter-repo && export PATH=\"\$HOME/Library/Python/3.9/bin:\$PATH\"" >&2
  exit 1
fi

if [[ -e "$DEST" ]]; then
  echo "destination $DEST exists; delete it or pass a different path" >&2
  exit 1
fi

for src in "$NODE_SRC" "$MACAPP_SRC"; do
  if [[ ! -d "$src/.git" ]]; then
    echo "missing source repo: $src" >&2
    exit 1
  fi
done

echo "==> working in $WORK"
echo "==> destination: $DEST"

# ── 1. Clone each source into a working copy so filter-repo can rewrite. ──
echo "==> cloning sources"
git clone --no-local --no-hardlinks --mirror "$NODE_SRC" "$WORK/node.git"
git clone --no-local --no-hardlinks --mirror "$MACAPP_SRC" "$WORK/macapp.git"

# Convert mirror clones back to normal working copies with default branch checked out.
for repo in "$WORK/node.git" "$WORK/macapp.git"; do
  tmp="${repo%.git}"
  git clone "$repo" "$tmp"
  rm -rf "$repo"
done

NODE_WORK="$WORK/node"
MACAPP_WORK="$WORK/macapp"

# ── 2. Filter teale-node: move everything into node/. ──
echo "==> filtering teale-node -> node/"
(
  cd "$NODE_WORK"
  git-filter-repo --to-subdirectory-filter node --force
)

# ── 3. Filter teale-mac-app: relay/ stays as relay/, everything else to mac-app/. ──
# filter-repo with --path-rename keeps listed paths and moves others; we want to
# keep the whole tree but move non-relay entries under mac-app/.
echo "==> filtering teale-mac-app -> relay/ + mac-app/"
(
  cd "$MACAPP_WORK"
  # First pass: enumerate top-level entries and build rename rules.
  # Everything that isn't relay/ gets moved under mac-app/. relay/ stays.
  TOP_LEVEL=$(git ls-tree -d --name-only HEAD; git ls-tree --name-only HEAD | grep -v '^relay$' | grep -v '^relay/')
  # De-dupe and strip relay.
  MAPPING=$(
    git ls-tree --name-only HEAD | while read -r entry; do
      if [[ "$entry" == "relay" ]]; then
        continue
      fi
      echo "--path-rename $entry:mac-app/$entry"
    done
  )
  # shellcheck disable=SC2086
  git-filter-repo $MAPPING --force
)

# ── 4. Assemble teale-mono. ──
echo "==> assembling $DEST"
mkdir -p "$(dirname "$DEST")"
git init --initial-branch=main "$DEST"

(
  cd "$DEST"
  # Import node history.
  git remote add node-import "$NODE_WORK"
  git fetch node-import
  NODE_BRANCH=$(git ls-remote --heads node-import | awk '{print $2}' | head -n1 | sed 's@refs/heads/@@')
  git merge --allow-unrelated-histories "node-import/${NODE_BRANCH}" -m "teale-mono Stage 0: import teale-node into node/"

  git remote add macapp-import "$MACAPP_WORK"
  git fetch macapp-import
  MACAPP_BRANCH=$(git ls-remote --heads macapp-import | awk '{print $2}' | head -n1 | sed 's@refs/heads/@@')
  git merge --allow-unrelated-histories "macapp-import/${MACAPP_BRANCH}" -m "teale-mono Stage 0: import teale-mac-app into relay/ + mac-app/"

  git remote remove node-import
  git remote remove macapp-import
)

# ── 5. Tag premigration states in the originals for rollback. ──
echo "==> tagging originals for rollback"
(
  cd "$NODE_SRC"
  git tag -f final-premigration
) || echo "warn: could not tag $NODE_SRC"
(
  cd "$MACAPP_SRC"
  git tag -f final-premigration
) || echo "warn: could not tag $MACAPP_SRC"

# ── 6. Clean up. ──
rm -rf "$WORK"

echo
echo "==> done"
echo "    teale-mono at: $DEST"
echo "    next steps:"
echo "      cd $DEST"
echo "      git log --oneline --graph --all | head"
echo "      git remote add origin git@github.com:teale-ai/teale-mono.git"
echo "      git push -u origin main  # after creating the repo on GitHub"
