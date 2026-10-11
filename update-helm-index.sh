#!/usr/bin/env bash
set -euo pipefail

CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/sia-k8s-connector" && pwd)"
BASE_URL="https://raw.githubusercontent.com/cyberark/sia-helm-charts/main/sia-k8s-connector"

helm repo index "$CHART_DIR" --url "$BASE_URL" --merge "$CHART_DIR/index.yaml"

echo "index.yaml updated:"
cat "$CHART_DIR/index.yaml"
