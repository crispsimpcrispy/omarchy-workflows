#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ID="io.github.crispsimpcrispy.workflows"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
STATE_DIR="$CONFIG_HOME/omarchy/workflows"
CONFIG_FILE="$STATE_DIR/workflows.json"
HYPR_DIR="$CONFIG_HOME/hypr"
AUTOSTART_FILE="$HYPR_DIR/autostart.lua"
STARTUP_FILE="$HYPR_DIR/omarchy_workflows_startup.lua"
PLUGIN_BACKEND="$CONFIG_HOME/omarchy/plugins/$PLUGIN_ID/backend.sh"
HOOK_BEGIN="-- BEGIN omarchy-workflows"
HOOK_END="-- END omarchy-workflows"
HOOK_LINE='require("hypr.omarchy_workflows_startup")'

mkdir -p "$STATE_DIR" "$HYPR_DIR"

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"; }

seed_config() {
  [[ -f "$CONFIG_FILE" ]] && return 0
  cat >"$CONFIG_FILE" <<'JSON'
{
  "version": 1,
  "activeWorkflow": "",
  "startupWorkflow": "",
  "workflows": [
    {
      "id": "work",
      "name": "Work",
      "icon": "W",
      "closeExisting": true,
      "startWorkspace": 1,
      "apps": [
        {"name":"Browser","workspace":1,"command":"omarchy-launch-browser","match":"chromium|firefox|zen|brave|google-chrome|helium"},
        {"name":"Obsidian","workspace":2,"command":"obsidian","match":"obsidian|md\\.obsidian\\.Obsidian"},
        {"name":"Zotero","workspace":3,"command":"zotero","match":"zotero"},
        {"name":"Spotify","workspace":4,"command":"omarchy-launch-spotify","match":"spotify"}
      ]
    },
    {
      "id": "relax",
      "name": "Relax",
      "icon": "R",
      "closeExisting": true,
      "startWorkspace": 1,
      "apps": [
        {"name":"Browser","workspace":1,"command":"omarchy-launch-browser","match":"chromium|firefox|zen|brave|google-chrome|helium"},
        {"name":"Steam","workspace":2,"command":"steam","match":"steam"}
      ]
    }
  ]
}
JSON
}

atomic_jq() {
  local filter="$1"; shift
  local tmp
  tmp="$(mktemp "$STATE_DIR/.workflows.XXXXXX")"
  if jq "$@" "$filter" "$CONFIG_FILE" >"$tmp"; then
    mv "$tmp" "$CONFIG_FILE"
  else
    rm -f "$tmp"
    return 1
  fi
}

lua_long_quote() {
  local value="${1:-}" eq=""
  local i close
  for i in {0..8}; do
    close="]${eq}]"
    if [[ "$value" != *"$close"* ]]; then
      printf '[%s[%s]%s]' "$eq" "$value" "$eq"
      return 0
    fi
    eq+="="
  done
  fail "Could not safely quote a command for Hyprland Lua"
}

hypr_close_window() {
  local selector="$1" q
  q="$(lua_long_quote "$selector")"
  hyprctl dispatch "hl.dsp.window.close({ window = $q })" >/dev/null 2>&1 \
    || hyprctl dispatch closewindow "$selector" >/dev/null 2>&1 \
    || true
}

hypr_move_window() {
  local workspace="$1" selector="$2" wq sq
  wq="$(lua_long_quote "$workspace")"
  sq="$(lua_long_quote "$selector")"
  hyprctl dispatch "hl.dsp.window.move({ workspace = $wq, follow = false, window = $sq })" >/dev/null 2>&1 \
    || hyprctl dispatch movetoworkspacesilent "$workspace,$selector" >/dev/null 2>&1 \
    || true
}

hypr_focus_workspace() {
  local workspace="$1" q
  q="$(lua_long_quote "$workspace")"
  hyprctl dispatch "hl.dsp.focus({ workspace = $q })" >/dev/null 2>&1 \
    || hyprctl dispatch workspace "$workspace" >/dev/null 2>&1 \
    || true
}

hypr_launch_workspace() {
  local workspace="$1" command="$2" cq wq
  cq="$(lua_long_quote "$command")"
  wq="$(lua_long_quote "$workspace silent")"
  hyprctl dispatch "hl.dsp.exec_cmd($cq, { workspace = $wq })" >/dev/null 2>&1 \
    || hyprctl dispatch exec "[workspace $workspace silent] $command" >/dev/null 2>&1
}

config() {
  seed_config
  cat "$CONFIG_FILE"
}

current() {
  seed_config
  jq -r '.activeWorkflow as $id | (.workflows[]? | select(.id == $id) | .name) // ""' "$CONFIG_FILE"
}

add_workflow() {
  seed_config
  local name="${1:-New Workflow}" icon="${2:-W}" id
  id="workflow-$(date +%s)-$RANDOM"
  atomic_jq '.workflows += [{id:$id,name:$name,icon:$icon,closeExisting:true,startWorkspace:1,apps:[]}]' \
    --arg id "$id" --arg name "$name" --arg icon "$icon"
  jq -nc --arg id "$id" '{id:$id}'
}

replace_workflow() {
  seed_config
  local id="${1:?workflow id required}" raw="${2:?workflow JSON required}" normalized
  jq -e . >/dev/null 2>&1 <<<"$raw" || fail "Workflow data is not valid JSON"
  normalized="$(jq -c --arg id "$id" '
    .id=$id
    | .name=(.name|tostring)
    | .icon=((.icon // "W")|tostring)
    | .closeExisting=(.closeExisting != false)
    | .startWorkspace=((.startWorkspace|tonumber) // 1)
    | .apps=((.apps // []) | map({
        name: ((.name // "Application")|tostring),
        workspace: ((.workspace|tonumber) // 1),
        command: ((.command // "")|tostring),
        match: ((.match // "")|tostring)
      }))
    | select(.startWorkspace >= 1)
    | select(all(.apps[]?; .workspace >= 1 and (.command|length) > 0))
  ' <<<"$raw")" || fail "Workflow contains an invalid workspace or empty command"

  jq -e --arg id "$id" '.workflows[] | select(.id==$id)' "$CONFIG_FILE" >/dev/null || fail "Unknown workflow: $id"
  atomic_jq '.workflows |= map(if .id==$id then $workflow else . end)' --arg id "$id" --argjson workflow "$normalized"
  printf 'Saved.\n'
}

delete_workflow() {
  seed_config
  local id="${1:?workflow id required}"
  atomic_jq '.workflows |= map(select(.id != $id)) | if .activeWorkflow==$id then .activeWorkflow="" else . end | if .startupWorkflow==$id then .startupWorkflow="" else . end' --arg id "$id"
  sync_startup_hook
  printf 'Deleted.\n'
}

count_windows() {
  require_cmd hyprctl
  require_cmd jq
  hyprctl clients -j 2>/dev/null | jq 'length'
}

close_all_windows() {
  local addresses
  addresses="$(hyprctl clients -j 2>/dev/null | jq -r '.[].address // empty')"
  while IFS= read -r addr; do
    [[ -n "$addr" ]] || continue
    hypr_close_window "address:$addr"
  done <<<"$addresses"

  # Give normal close requests a short chance to complete. Windows with unsaved
  # data are deliberately left to show their application's own save prompt.
  local i
  for i in {1..15}; do
    [[ "$(count_windows)" -eq 0 ]] && break
    sleep 0.12
  done
}

relocate_new_windows() {
  local baseline="$1" apps_json="$2" attempt app workspace matcher addr
  for attempt in {1..8}; do
    while IFS= read -r app; do
      [[ -n "$app" ]] || continue
      workspace="$(jq -r '.workspace|tostring' <<<"$app")"
      matcher="$(jq -r '.match // ""' <<<"$app")"
      [[ -n "$matcher" ]] || continue

      while IFS= read -r addr; do
        [[ -n "$addr" ]] || continue
        if ! grep -Fxq "$addr" "$baseline"; then
          hypr_move_window "$workspace" "address:$addr"
        fi
      done < <(hyprctl clients -j 2>/dev/null | jq -r --arg re "$matcher" --arg target "$workspace" '
        .[]
        | select(
            ((.class // "") | test($re; "i")) or
            ((.initialClass // "") | test($re; "i")) or
            ((.title // "") | test($re; "i")) or
            ((.initialTitle // "") | test($re; "i"))
          )
        | select(((.workspace.id // -1) | tostring) != $target)
        | .address // empty
      ' 2>/dev/null || true)
    done < <(jq -c '.[]' <<<"$apps_json")
    sleep 0.35
  done
}

run_workflow() {
  seed_config
  require_cmd hyprctl
  require_cmd jq
  local id="${1:?workflow id required}" workflow close_existing start_ws apps baseline app ws command
  workflow="$(jq -c --arg id "$id" '.workflows[]? | select(.id==$id)' "$CONFIG_FILE")"
  [[ -n "$workflow" ]] || fail "Unknown workflow: $id"
  close_existing="$(jq -r '.closeExisting != false' <<<"$workflow")"
  start_ws="$(jq -r '.startWorkspace|tostring' <<<"$workflow")"
  apps="$(jq -c '.apps // []' <<<"$workflow")"

  if [[ "$close_existing" == "true" ]]; then
    close_all_windows
  fi

  baseline="$(mktemp "$STATE_DIR/.baseline.XXXXXX")"
  hyprctl clients -j 2>/dev/null | jq -r '.[].address // empty' | sort -u >"$baseline"

  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    ws="$(jq -r '.workspace|tostring' <<<"$app")"
    command="$(jq -r '.command' <<<"$app")"
    [[ -n "$command" ]] || continue
    hypr_launch_workspace "$ws" "$command" || true
    sleep 0.12
  done < <(jq -c '.[]' <<<"$apps")

  # One-shot exec rules can be lost when an app forks or delegates window
  # creation (notably Chromium/Electron). Match only windows created after the
  # workflow started and silently relocate them as a fallback.
  relocate_new_windows "$baseline" "$apps"
  hypr_focus_workspace "$start_ws"

  rm -f "$baseline"
  atomic_jq '.activeWorkflow=$id' --arg id "$id"
  printf 'Launched %s.\n' "$(jq -r '.name' <<<"$workflow")"
}

write_startup_file() {
  cat >"$STARTUP_FILE" <<EOF
-- Generated by Omarchy Workflows. Do not edit this file by hand.
hl.on("hyprland.start", function()
  hl.exec_cmd("bash -lc 'sleep 2; ${PLUGIN_BACKEND} run-startup >/dev/null 2>&1 &'" )
end)
EOF
}

remove_hook_block() {
  [[ -f "$AUTOSTART_FILE" ]] || return 0
  local tmp
  tmp="$(mktemp "$HYPR_DIR/.autostart.XXXXXX")"
  awk -v begin="$HOOK_BEGIN" -v end="$HOOK_END" '
    $0 == begin { skip=1; next }
    $0 == end   { skip=0; next }
    !skip { print }
  ' "$AUTOSTART_FILE" >"$tmp"
  mv "$tmp" "$AUTOSTART_FILE"
}

sync_startup_hook() {
  seed_config
  local id
  id="$(jq -r '.startupWorkflow // ""' "$CONFIG_FILE")"
  remove_hook_block
  if [[ -z "$id" ]]; then
    rm -f "$STARTUP_FILE"
    return 0
  fi

  write_startup_file
  touch "$AUTOSTART_FILE"
  {
    printf '\n%s\n' "$HOOK_BEGIN"
    printf '%s\n' "$HOOK_LINE"
    printf '%s\n' "$HOOK_END"
  } >>"$AUTOSTART_FILE"
}

set_startup() {
  seed_config
  local id="${1:-}"
  if [[ -n "$id" ]]; then
    jq -e --arg id "$id" '.workflows[] | select(.id==$id)' "$CONFIG_FILE" >/dev/null || fail "Unknown workflow: $id"
  fi
  atomic_jq '.startupWorkflow=$id' --arg id "$id"
  sync_startup_hook
  if [[ -n "$id" ]]; then printf 'This workflow will run at your next Hyprland login.\n'; else printf 'Login workflow cleared.\n'; fi
}

run_startup() {
  seed_config
  local id
  id="$(jq -r '.startupWorkflow // ""' "$CONFIG_FILE")"
  [[ -n "$id" ]] || exit 0
  run_workflow "$id"
}

diagnose() {
  seed_config
  printf 'Config: %s\n' "$CONFIG_FILE"
  jq -e . "$CONFIG_FILE" >/dev/null && printf 'JSON: OK\n'
  command -v hyprctl >/dev/null && printf 'hyprctl: OK\n' || printf 'hyprctl: MISSING\n'
  command -v jq >/dev/null && printf 'jq: OK\n' || printf 'jq: MISSING\n'
  printf 'Workflows: %s\n' "$(jq '.workflows|length' "$CONFIG_FILE")"
  printf 'Current: %s\n' "$(current)"
  printf 'Open windows: %s\n' "$(count_windows 2>/dev/null || echo '?')"
}

seed_config

case "${1:-config}" in
  config) config ;;
  current) current ;;
  add-workflow) shift; add_workflow "$@" ;;
  replace-workflow) shift; replace_workflow "$@" ;;
  delete-workflow) shift; delete_workflow "$@" ;;
  count-windows) count_windows ;;
  run) shift; run_workflow "$@" ;;
  set-startup) shift; set_startup "$@" ;;
  run-startup) run_startup ;;
  sync-startup) sync_startup_hook ;;
  diagnose) diagnose ;;
  *) fail "Usage: $0 {config|current|add-workflow|replace-workflow|delete-workflow|count-windows|run|set-startup|run-startup|sync-startup|diagnose}" ;;
esac
