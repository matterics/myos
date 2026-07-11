#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash "$root/scripts/build-packages.sh"
profile="$(bash "$root/scripts/prepare-archiso-profile.sh")"

# Install ollama in the build container so we can manage models
pacman -S --noconfirm --needed ollama nodejs npm

# Bake OpenCode into the ISO without running npm's postinstall on the
# Windows-backed profile mount (hardlink replacement is unreliable there).
echo "Installing OpenCode CLI into ISO rootfs..."
opencode_stage="$(mktemp -d)"
trap 'rm -rf "$opencode_stage"' EXIT
npm install --prefix "$opencode_stage" --ignore-scripts --no-audit --no-fund opencode-ai
# Use the baseline build so the ISO also boots on x86_64 CPUs without AVX2.
opencode_bin="$opencode_stage/node_modules/opencode-linux-x64-baseline/bin/opencode"
file "$opencode_bin" | grep -q 'ELF 64-bit' || {
    echo "OpenCode package did not produce a Linux executable" >&2
    exit 1
}
"$opencode_bin" --version
install -Dm755 "$opencode_bin" "$profile/airootfs/usr/bin/opencode"

# Only this model is bundled into the ISO.
MODEL_NAME="${MYOS_LOCAL_MODEL:-gemma:2b}"
model_repo="${MODEL_NAME%%:*}"
model_tag="${MODEL_NAME##*:}"

HOST_MODELS="/root/.ollama_host/models"
TARGET_MODELS="$profile/airootfs/var/lib/ollama"
host_manifest="$HOST_MODELS/manifests/registry.ollama.ai/library/$model_repo/$model_tag"
mkdir -p "$TARGET_MODELS/blobs"

if [ -f "$host_manifest" ]; then
    # Copy exactly this model from the host: its manifest plus the blobs it
    # references. No download, and other host models never enter the ISO.
    echo "Host model $MODEL_NAME found — copying it into the ISO (no download)."
    mkdir -p "$TARGET_MODELS/manifests/registry.ollama.ai/library/$model_repo"
    cp "$host_manifest" \
       "$TARGET_MODELS/manifests/registry.ollama.ai/library/$model_repo/$model_tag"
    for digest in $(jq -r '.config.digest, .layers[].digest' "$host_manifest"); do
        cp -n "$HOST_MODELS/blobs/sha256-${digest#sha256:}" "$TARGET_MODELS/blobs/"
    done
else
    # No host copy: pull once into a persistent workspace cache, reuse forever.
    echo "Host model $MODEL_NAME not found — using the build cache."
    CACHE_DIR="$root/.cache/ollama"
    mkdir -p "$CACHE_DIR"
    export OLLAMA_MODELS="$CACHE_DIR"
    ollama serve >/tmp/ollama.log 2>&1 &
    OLLAMA_PID=$!
    echo "Waiting for Ollama daemon to start..."
    for i in {1..30}; do
      if curl -s http://127.0.0.1:11434/ >/dev/null; then
        break
      fi
      sleep 1
    done
    if ! ollama list | grep -q "$MODEL_NAME"; then
        echo "Pulling $MODEL_NAME (happens only once, cached in .cache/ollama)..."
        ollama pull "$MODEL_NAME"
    else
        echo "✅ $MODEL_NAME found in build cache! Skipping download."
    fi
    kill $OLLAMA_PID
    wait $OLLAMA_PID || true
    cp -a "$CACHE_DIR/." "$TARGET_MODELS/"
fi

# Fix permissions for the ollama service user inside the ISO
chmod -R 777 "$TARGET_MODELS"

# Override systemd service to look in /var/lib/ollama
mkdir -p "$profile/airootfs/etc/systemd/system/ollama.service.d"
echo -e "[Service]\nEnvironment=\"OLLAMA_MODELS=/var/lib/ollama\"" > "$profile/airootfs/etc/systemd/system/ollama.service.d/override.conf"

mkdir -p "$root/out"
mkarchiso -v -r -w /tmp/myos-mkarchiso -o "$root/out" "$profile"
