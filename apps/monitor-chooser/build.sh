#!/usr/bin/env bash
# build.sh — build contract for monitor-chooser (local-bootstrapping deployable app).
#
# Builds the Rust monitor-chooser TUI and places the binary at the stable,
# gitignored canonical path ./bin/monitor-chooser. Invoked by install.sh's
# setup_monitor_chooser(). Safe to re-run.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

if ! command -v cargo >/dev/null 2>&1; then
    echo "build.sh: cargo (Rust toolchain) not found — install rust, then re-run" >&2
    exit 1
fi

echo "monitor-chooser: cargo build --release ..."
cargo build --release

mkdir -p bin
cp -f target/release/monitor-chooser bin/monitor-chooser
echo "monitor-chooser: built ./bin/monitor-chooser"
