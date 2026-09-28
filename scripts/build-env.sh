#!/bin/zsh
# Source from the project root to use the rustup toolchain rather than Homebrew Rust.
export MACOSX_DEPLOYMENT_TARGET=26.0
if ! command -v rustup >/dev/null 2>&1; then
    echo "Install rustup and its stable toolchain before building DiskScope." >&2
    return 1
fi
rust_cargo="$(rustup which --toolchain stable cargo)" || return 1
export PATH="${rust_cargo:h}:$PATH"
