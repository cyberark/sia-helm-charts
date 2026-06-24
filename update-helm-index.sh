#!/usr/bin/env bash
set -euo pipefail

CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/sia-k8s-connector" && pwd)"

helm repo index "$CHART_DIR" --merge "$CHART_DIR/index.yaml"

echo "index.yaml updated:"
cat "$CHART_DIR/index.yaml"
