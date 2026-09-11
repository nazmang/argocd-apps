#!/usr/bin/env bash
#
# Copy chart-lib/monitoring.yaml into every chart that has a templates/
# directory, and report what changed.
#
# Run this after editing the canonical template. The pre-commit hook
# `monitoring-template-in-sync` refuses a commit where a copy differs, so the
# two cannot drift silently -- this script is how you make them agree again.
#
#   ./chart-lib/sync-monitoring.sh          copy and report
#   ./chart-lib/sync-monitoring.sh --check  report only, exit 1 if any differ

set -euo pipefail

cd "$(dirname "$0")/.."
SRC="chart-lib/monitoring.yaml"
CHECK_ONLY="${1:-}"
rc=0

for chart in helm-*/; do
    [[ -f "${chart}Chart.yaml" ]] || continue
    [[ -d "${chart}templates" ]] || continue
    dst="${chart}templates/monitoring.yaml"

    if [[ -f "$dst" ]] && cmp -s "$SRC" "$dst"; then
        continue
    fi

    if [[ "$CHECK_ONLY" == "--check" ]]; then
        if [[ -f "$dst" ]]; then
            echo "РАСХОЖДЕНИЕ: $dst отличается от $SRC"
        else
            echo "ОТСУТСТВУЕТ: $dst"
        fi
        rc=1
    else
        cp "$SRC" "$dst"
        echo "обновлён: $dst"
    fi
done

exit $rc
