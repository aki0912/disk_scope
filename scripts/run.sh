#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
./scripts/build.sh
open build/DiskScope.app
