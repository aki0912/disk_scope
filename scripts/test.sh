#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
source scripts/build-env.sh
python3 -m unittest discover -s Tests/Release -v
cargo fmt --check --manifest-path rust/Cargo.toml
cargo clippy --manifest-path rust/Cargo.toml --all-targets -- -D warnings
cargo test --manifest-path rust/Cargo.toml
cargo build --release --manifest-path rust/Cargo.toml
swift test
python3 scripts/verify_scanner.py
python3 scripts/verify_model.py
