#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

printf 'Checking manifest JSON... '
jq -e '.schemaVersion==1 and .id=="io.github.crispsimpcrispy.workflows" and (.kinds|index("bar-widget")!=null) and .entryPoints.barWidget=="BarWidget.qml"' manifest.json >/dev/null
printf 'OK\n'

printf 'Checking backend shell syntax... '
bash -n backend.sh
printf 'OK\n'

printf 'Checking required files... '
for f in manifest.json BarWidget.qml Panel.qml backend.sh README.md LICENSE; do
  [[ -f "$f" ]] || { echo "missing $f"; exit 1; }
done
printf 'OK\n'

if command -v omarchy >/dev/null 2>&1; then
  printf 'Running Omarchy manifest validation...\n'
  omarchy plugin validate .
fi

if command -v qmllint >/dev/null 2>&1 && [[ -n "${OMARCHY_PATH:-}" ]]; then
  printf 'Running qmllint against Omarchy shell imports...\n'
  qmllint -I "$OMARCHY_PATH/shell" BarWidget.qml Panel.qml
else
  printf 'Skipping qmllint (qmllint or OMARCHY_PATH unavailable).\n'
fi

printf 'Self-test complete.\n'
