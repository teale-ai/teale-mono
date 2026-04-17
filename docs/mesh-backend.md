# Mesh-LLM backend

[Mesh-LLM](https://github.com/Mesh-LLM/mesh-llm) is a distributed inference
runtime (Apache-2.0, Rust, built on llama.cpp) that shards a single model
across multiple machines and exposes the cluster as one
OpenAI-compatible endpoint at `http://localhost:9337/v1`.

teale-node can use a mesh-llm cluster as its inference backend, surfacing
the cluster's aggregate capacity to TealeNet as a single supply node.

## When to use this backend

Use `backend = "mesh"` when **no single device in a group has enough RAM
or VRAM to host the target model alone** but several devices *together*
do. The canonical case for teale-node is a set of Android phones
collaborating to serve a model larger than any one phone could hold.

If one machine can run the model comfortably, prefer `backend = "llama"`
(lower overhead, no cluster coordination).

## Install

Follow the upstream install docs:

```bash
curl -fsSL https://raw.githubusercontent.com/Mesh-LLM/mesh-llm/main/install.sh | bash
```

This installs the `mesh-llm` binary. Start a node with:

```bash
mesh-llm serve --auto
```

The web console for topology and per-node capacity is at
<http://localhost:3131>. teale-node does not proxy this — view it
directly on the host running mesh-llm.

## Attach vs. spawn

Two lifecycle modes are supported:

- **Attach (recommended)** — run `mesh-llm serve` yourself (e.g. as a
  systemd service or via the upstream installer's supervisor) and have
  teale-node connect to the existing endpoint. Leave `[mesh].binary`
  unset. This is the cleanest split of concerns and keeps the mesh-llm
  web console independent of teale-node's lifecycle.

- **Spawn** — set `[mesh].binary = "mesh-llm"` (or an absolute path) and
  teale-node will launch `mesh-llm serve <serve_args...>` as a
  subprocess. If you pass serving flags in `serve_args` (e.g. a
  non-default `--port`), make sure they agree with `endpoint` / `port`
  in the config.

In either mode, teale-node polls `GET /v1/models` as its readiness probe
(mesh-llm does not expose `/health`).

## Example config

See [`teale-node.mesh.toml`](../teale-node.mesh.toml) in the repo root.

## Model id reporting

The node advertises one `model_id` to the relay. Configure it explicitly
via `[mesh].model_id`, or omit it and teale-node will query `/v1/models`
once at startup and use the first entry returned. Changing the mesh's
served model currently requires restarting teale-node.

## Verified: 2-node sharding (Mac ↔ Mac)

Tested 2026-04-16 with mesh-llm v0.60.3 (metal flavor) on a single
Apple M4 Pro, two processes with isolated `HOME` directories so each
gets a distinct node identity. Steps:

```bash
# Pre-download the model once
mesh-llm download Llama-3.2-3B-Instruct-Q4_K_M

# Node A — host, capped so it can't solo-host the 2GB model
mesh-llm serve --model Llama-3.2-3B-Instruct-Q4_K_M \
  --port 9337 --console 3131 --max-vram 1.5 --split --no-draft
# prints: "Invite: eyJ..."

# Node B — separate identity via fresh HOME; joins with -j
HOME=/tmp/mesh-b-home mesh-llm serve \
  --port 9338 --console 3132 --max-vram 1.5 --split \
  --model Llama-3.2-3B-Instruct-Q4_K_M --no-draft -j <invite>
```

Expected log on the elected host (in this run, node B):

```
🗳 Elected as host (3.0GB capacity for 2.0GB model, 2 node(s), split)
  ✓ Adding 3b51ddabcc — 1.5GB capacity, RTT 0ms
  Tensor split: 0.50,0.50 (2 node(s), 3GB total)
✅ llama-server ready
```

A `POST /v1/chat/completions` to either endpoint streams tokens
normally — the OpenAI-compatible surface hides the sharding.

Notes:

- Two mesh-llm processes on one host **must** use separate `HOME`
  directories (mesh-llm stores the node key at `~/.mesh-llm/key`). With
  a shared `HOME` both processes advertise the same node id and the
  planner treats them as one node.
- `--split` alone is not enough to force sharding when the model fits —
  combine with `--max-vram` low enough that no single node can solo-host.
- `--no-draft` skips the auto-downloaded speculative-decoding draft
  model, which saves ~800MB per node during setup but isn't required.

## Android

Upstream releases only ship glibc-linked Linux binaries
(`mesh-llm-aarch64-unknown-linux-gnu`, interpreter
`/lib/ld-linux-aarch64.so.1`). Android's bionic libc can't load them —
`adb push` + run gives `No such file or directory` (the kernel reporting
a missing interpreter, not a missing executable).

**Solution:** cross-compile mesh-llm from source against the Android NDK.
Use [`scripts/build-mesh-llm-android.sh`](../scripts/build-mesh-llm-android.sh)
in this repo, which clones upstream, applies two minimal patches
(reqwest → rustls-tls to avoid openssl-sys vendoring; stub `ui/dist`
for headless builds), and cross-compiles via the same NDK toolchain
teale-node already uses.

```bash
./scripts/build-mesh-llm-android.sh
adb push build/mesh-llm-android/mesh-llm /data/local/tmp/mesh-llm
adb shell chmod 755 /data/local/tmp/mesh-llm
```

Verified 2026-04-17 on a Pixel 9 Pro Fold (Android 15 / API 36) —
`mesh-llm --version` prints `mesh-llm 0.62.1`.

**HOME gotcha on Android shell:** Android's `adb shell` sets `HOME=/`
(read-only). mesh-llm tries to create `~/.mesh-llm/run/plugins` at
startup and fails. Always run with an explicit writable HOME:

```bash
adb shell "cd /data/local/tmp && HOME=/data/local/tmp ./mesh-llm serve --help"
```

### Worker role on Android (rpc-server)

To have a phone contribute GPU/CPU as a *shard worker* (not just a
client proxy), mesh-llm also needs `rpc-server` and `llama-server`
binaries in the same directory, passed via `--bin-dir`. Upstream
doesn't ship Android builds of these either. The teale-node Pixel
already has an Android-native `llama-server` at `/data/local/tmp/`;
rpc-server must be built from llama.cpp @ the SHA pinned by mesh-llm
(`mesh-llm/LLAMA_CPP_SHA`) with `-DGGML_RPC=ON`.

A minimal CPU-only cross-compile from mesh-llm's source tree:

```bash
git clone https://github.com/ggml-org/llama.cpp.git
cd llama.cpp
git checkout $(cat /path/to/mesh-llm-src/LLAMA_CPP_SHA)
cmake -B build-android \
    -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-35 \
    -DGGML_RPC=ON -DLLAMA_CURL=OFF -DBUILD_SHARED_LIBS=OFF
cmake --build build-android --target rpc-server llama-server -j
```

Then on the Pixel, run mesh-llm with `--bin-dir /data/local/tmp` so it
finds the Android-native rpc-server/llama-server. A Vulkan-enabled
build (`-DGGML_VULKAN=ON`) would use the Tensor G4 GPU — the existing
Pixel `libggml-vulkan.so` shows this works — but the CPU-only build is
the lower-friction starting point.

### Client-only fallback

If only a few phones in the fleet need to participate in a specific
mesh, the phone can run `mesh-llm serve --client -j <invite>` and just
proxy API traffic without contributing compute. This is enough to
prove the transport works and gives the phone access to the pooled
cluster.
