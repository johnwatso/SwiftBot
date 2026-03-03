#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

exec env SWIFTBOT_ROOT="$ROOT_DIR" swift run --package-path "$ROOT_DIR" SparklePublisher "$@"
