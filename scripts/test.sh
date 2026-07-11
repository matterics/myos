#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

buf format --diff --exit-code
buf lint
cargo fmt --manifest-path daemon/Cargo.toml --all --check
cargo test --manifest-path daemon/Cargo.toml --workspace
bash -n scripts/*.sh
bash scripts/test-archiso-profile.sh
