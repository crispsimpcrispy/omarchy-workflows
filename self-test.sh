#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

printf 'Checking manifest JSON... '
jq -e '.schemaVersion==1 and .id=="io.github.crispsimpcrispy.workflows" and .version=="0.2.1" and (.kinds|index("bar-widget")!=null) and .entryPoints.barWidget=="BarWidget.qml"' manifest.json >/dev/null
printf 'OK\n'

printf 'Checking backend shell syntax... '
bash -n backend.sh
printf 'OK\n'

printf 'Checking required files... '
for f in manifest.json BarWidget.qml Panel.qml backend.sh README.md LICENSE; do
  [[ -f "$f" ]] || { echo "missing $f"; exit 1; }
done
printf 'OK\n'

printf 'Running isolated backend tests...\n'
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
log="$tmp/hypr.log"
clients="$tmp/clients.json"

cat >"$clients" <<'JSON'
[
  {"address":"0x1","workspace":{"id":1},"class":"chromium","initialClass":"chromium","title":"Browser","initialTitle":"Browser","pid":101},
  {"address":"0x2","workspace":{"id":4},"class":"spotify","initialClass":"spotify","title":"Spotify","initialTitle":"Spotify","pid":102},
  {"address":"0x3","workspace":{"id":9},"class":"foot","initialClass":"foot","title":"Terminal","initialTitle":"Terminal","pid":103}
]
JSON

cat >"$tmp/bin/hyprctl" <<'MOCK'
#!/usr/bin/env bash
set -e
if [[ "$1" == "clients" && "$2" == "-j" ]]; then
  cat "$MOCK_CLIENTS"
elif [[ "$1" == "activeworkspace" && "$2" == "-j" ]]; then
  printf '{"id":4}\n'
elif [[ "$1" == "dispatch" ]]; then
  printf '%s\n' "$*" >>"$MOCK_LOG"
else
  exit 0
fi
MOCK
chmod +x "$tmp/bin/hyprctl"

cat >"$tmp/bin/gtk-launch" <<'MOCK'
#!/usr/bin/env bash
printf 'gtk-launch %s\n' "$*" >>"$MOCK_LOG"
MOCK
chmod +x "$tmp/bin/gtk-launch"

export HOME="$tmp/home"
export XDG_CONFIG_HOME="$HOME/.config"
export PATH="$tmp/bin:$PATH"
export MOCK_CLIENTS="$clients"
export MOCK_LOG="$log"
mkdir -p "$HOME"

cfg="$(./backend.sh config)"
jq -e '.version==2 and (.workflows|length)==2 and .workflows[0].shutdownMode=="current"' <<<"$cfg" >/dev/null
printf '  seed/migration: OK\n'

capture="$(./backend.sh capture)"
jq -e '.activeWorkspace==4 and (.windows|length)==3 and .windows[0].class=="chromium"' <<<"$capture" >/dev/null
printf '  desktop capture: OK\n'

raw='{"name":"Research","icon":"R","shutdownMode":"keep","startWorkspace":2,"apps":[{"name":"Zotero","workspace":3,"desktopId":"org.zotero.Zotero","command":"","match":"zotero","reuseExisting":true,"icon":"zotero"}]}'
id="$(./backend.sh create-workflow-json "$raw" | jq -r .id)"
./backend.sh config | jq -e --arg id "$id" '.workflows[]|select(.id==$id and .shutdownMode=="keep" and .apps[0].desktopId=="org.zotero.Zotero")' >/dev/null
printf '  captured/picker data model: OK\n'

# Set Work active, then switch to Relax. Browser is shared/reusable, Spotify is
# part of the old workflow and should close, terminal is unrelated and should stay.
jq '
  .activeWorkflow="work"
  | (.workflows[] | select(.id=="relax") | .apps[] | select(.name=="Browser") | .desktopId)="org.chromium.Chromium"
  | (.workflows[] | select(.id=="relax") | .apps[] | select(.name=="Browser") | .match)="^chromium$"
' "$XDG_CONFIG_HOME/omarchy/workflows/workflows.json" >"$tmp/config.new"
mv "$tmp/config.new" "$XDG_CONFIG_HOME/omarchy/workflows/workflows.json"
: >"$log"
./backend.sh run relax >/dev/null

grep -q 'address:0x2' "$log" || { echo 'Expected Spotify to receive a close request'; exit 1; }
if grep -q 'close.*address:0x1' "$log"; then echo 'Browser should have been preserved for reuse'; exit 1; fi
if grep -q 'close.*address:0x3' "$log"; then echo 'Unrelated terminal should not have been closed'; exit 1; fi
grep -q 'address:0x1' "$log" || { echo 'Expected Browser to be moved/reused'; exit 1; }
printf '  current-workflow close + reuse: OK\n'

# Close-all mode should close every mocked client.
jq --arg id "$id" '(.workflows[]|select(.id==$id)|.shutdownMode)="all"' "$XDG_CONFIG_HOME/omarchy/workflows/workflows.json" >"$tmp/config.new"
mv "$tmp/config.new" "$XDG_CONFIG_HOME/omarchy/workflows/workflows.json"
: >"$log"
./backend.sh run "$id" >/dev/null
for a in 0x1 0x2 0x3; do grep -q "address:$a" "$log" || { echo "Expected $a to close in all mode"; exit 1; }; done
grep -q 'gtk-launch' "$log" || { echo 'Expected desktop entry launch via gtk-launch'; exit 1; }
printf '  close-all + desktop entry launch: OK\n'

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
