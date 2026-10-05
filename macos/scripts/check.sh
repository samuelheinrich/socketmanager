#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
"$PROJECT_DIR/macos/scripts/test.sh"
"$PROJECT_DIR/macos/scripts/build-app.sh"
