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
  cat >"$CONFIG_FILE" <<'JSON_EOF'
{
  "version": 2,
  "activeWorkflow": "",
  "startupWorkflow": "",
  "workflows": [
    {
      "id": "work",
      "name": "Work",
      "icon": "W",
      "shutdownMode": "current",
      "startWorkspace": 1,
      "apps": [
        {"name":"Browser","workspace":1,"desktopId":"","command":"omarchy-launch-browser","match":"chromium|firefox|zen|brave|google-chrome|helium","reuseExisting":true,"icon":""},
        {"name":"Obsidian","workspace":2,"desktopId":"","command":"obsidian","match":"obsidian|md\\.obsidian\\.Obsidian","reuseExisting":true,"icon":"obsidian"},
        {"name":"Zotero","workspace":3,"desktopId":"org.zotero.Zotero","command":"","match":"org\\.zotero\\.Zotero|zotero","reuseExisting":true,"icon":"zotero"},
        {"name":"Spotify","workspace":4,"desktopId":"","command":"omarchy-launch-spotify","match":"spotify","reuseExisting":true,"icon":"spotify"}
      ]
    },
    {
      "id": "relax",
      "name": "Relax",
      "icon": "R",
      "shutdownMode": "current",
      "startWorkspace": 1,
      "apps": [
        {"name":"Browser","workspace":1,"desktopId":"","command":"omarchy-launch-browser","match":"chromium|firefox|zen|brave|google-chrome|helium","reuseExisting":true,"icon":""},
        {"name":"Steam","workspace":2,"desktopId":"steam","command":"steam","match":"steam","reuseExisting":true,"icon":"steam"}
      ]
    }
  ]
}
JSON_EOF
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

migrate_config() {
  seed_config
  local version
  version="$(jq -r '.version // 1' "$CONFIG_FILE" 2>/dev/null || echo 1)"
  [[ "$version" -ge 2 ]] && return 0
  atomic_jq '
    .version=2
    | .workflows |= map(
        .shutdownMode=(if has("shutdownMode") then .shutdownMode elif (.closeExisting // true) then "all" else "keep" end)
        | del(.closeExisting)
        | .apps=((.apps // []) | map(
            .desktopId=(.desktopId // "")
            | .reuseExisting=(.reuseExisting // true)
            | .icon=(.icon // "")
          ))
      )
  '
}

normalize_shutdown_mode() {
  case "${1:-}" in
    keep|current|all) printf '%s' "$1" ;;
    *) printf 'current' ;;
  esac
}

lua_long_quote() {
  local value="${1:-}" eq="" i close
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

shell_quote() { printf '%q' "${1:-}"; }

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

app_launch_command() {
  local app="$1" desktop_id command
  desktop_id="$(jq -r '.desktopId // ""' <<<"$app")"
  command="$(jq -r '.command // ""' <<<"$app")"
  if [[ -n "$desktop_id" ]]; then
    printf 'gtk-launch %s' "$(shell_quote "$desktop_id")"
  else
    printf '%s' "$command"
  fi
}

config() { migrate_config; cat "$CONFIG_FILE"; }

current() {
  migrate_config
  jq -r '.activeWorkflow as $id | (.workflows[]? | select(.id == $id) | .name) // ""' "$CONFIG_FILE"
}

add_workflow() {
  migrate_config
  local name="${1:-New Workflow}" icon="${2:-W}" id
  id="workflow-$(date +%s)-$RANDOM"
  atomic_jq '.workflows += [{id:$id,name:$name,icon:$icon,shutdownMode:"current",startWorkspace:1,apps:[]}]' \
    --arg id "$id" --arg name "$name" --arg icon "$icon"
  jq -nc --arg id "$id" '{id:$id}'
}

normalize_workflow() {
  local id="$1" raw="$2"
  jq -c --arg id "$id" '
    .id=$id
    | .name=((.name // "Workflow")|tostring)
    | .icon=((.icon // "W")|tostring)
    | (.shutdownMode // "current") as $mode
    | .shutdownMode=(if (["keep","current","all"] | index($mode)) then $mode else "current" end)
    | .startWorkspace=((.startWorkspace|tonumber) // 1)
    | .apps=((.apps // []) | map({
        name: ((.name // "Application")|tostring),
        workspace: ((.workspace|tonumber) // 1),
        desktopId: ((.desktopId // "")|tostring),
        command: ((.command // "")|tostring),
        match: ((.match // "")|tostring),
        reuseExisting: (.reuseExisting != false),
        icon: ((.icon // "")|tostring)
      }))
    | select(.startWorkspace >= 1)
    | select(all(.apps[]?; .workspace >= 1 and (((.desktopId|length) > 0) or ((.command|length) > 0))))
  ' <<<"$raw" || fail "Workflow contains an invalid workspace or an app with no desktop entry/command"
}

create_workflow_json() {
  migrate_config
  local raw="${1:?workflow JSON required}" id normalized
  jq -e . >/dev/null 2>&1 <<<"$raw" || fail "Workflow data is not valid JSON"
  id="workflow-$(date +%s)-$RANDOM"
  normalized="$(normalize_workflow "$id" "$raw")"
  atomic_jq '.workflows += [$workflow]' --argjson workflow "$normalized"
  jq -nc --arg id "$id" '{id:$id}'
}

replace_workflow() {
  migrate_config
  local id="${1:?workflow id required}" raw="${2:?workflow JSON required}" normalized
  jq -e . >/dev/null 2>&1 <<<"$raw" || fail "Workflow data is not valid JSON"
  normalized="$(normalize_workflow "$id" "$raw")"
  jq -e --arg id "$id" '.workflows[] | select(.id==$id)' "$CONFIG_FILE" >/dev/null || fail "Unknown workflow: $id"
  atomic_jq '.workflows |= map(if .id==$id then $workflow else . end)' --arg id "$id" --argjson workflow "$normalized"
  printf 'Saved.\n'
}

delete_workflow() {
  migrate_config
  local id="${1:?workflow id required}"
  atomic_jq '.workflows |= map(select(.id != $id)) | if .activeWorkflow==$id then .activeWorkflow="" else . end | if .startupWorkflow==$id then .startupWorkflow="" else . end' --arg id "$id"
  sync_startup_hook
  printf 'Deleted.\n'
}

clients_json() {
  require_cmd hyprctl
  require_cmd jq
  hyprctl clients -j 2>/dev/null || printf '[]\n'
}

count_windows() { clients_json | jq 'length'; }

window_matches_regex() {
  local matcher="$1"
  clients_json | jq -r --arg re "$matcher" '
    .[]
    | select(
        ((.class // "") | test($re; "i")) or
        ((.initialClass // "") | test($re; "i")) or
        ((.title // "") | test($re; "i")) or
        ((.initialTitle // "") | test($re; "i"))
      )
    | .address // empty
  ' 2>/dev/null || true
}

first_existing_window() {
  local matcher="$1"
  [[ -n "$matcher" ]] || return 0
  window_matches_regex "$matcher" | head -n1
}

move_existing_windows() {
  local matcher="$1" workspace="$2" addr found=1
  [[ -n "$matcher" ]] || return 1
  while IFS= read -r addr; do
    [[ -n "$addr" ]] || continue
    found=0
    hypr_move_window "$workspace" "address:$addr"
  done < <(window_matches_regex "$matcher")
  return "$found"
}

app_identity() {
  local app="$1" desktop match name
  desktop="$(jq -r '.desktopId // ""' <<<"$app")"
  match="$(jq -r '.match // ""' <<<"$app")"
  name="$(jq -r '.name // ""' <<<"$app")"
  if [[ -n "$desktop" ]]; then printf 'desktop:%s' "${desktop,,}"
  elif [[ -n "$match" ]]; then printf 'match:%s' "${match,,}"
  else printf 'name:%s' "${name,,}"
  fi
}

target_reuses_identity() {
  local target_apps="$1" identity="$2" app reuse
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    reuse="$(jq -r '.reuseExisting != false' <<<"$app")"
    [[ "$reuse" == "true" ]] || continue
    [[ "$(app_identity "$app")" == "$identity" ]] && return 0
  done < <(jq -c '.[]' <<<"$target_apps")
  return 1
}

# Resolve the *actual currently-open Hyprland window addresses* that the target
# workflow wants to reuse.  Address-based protection is more reliable than
# comparing saved desktop IDs/matchers because the same app can be represented
# differently after using the application picker (for example a legacy custom
# matcher in one workflow and a desktop-entry ID in another).
reusable_target_addresses() {
  local target_apps="$1" app reuse matcher addr seen=""
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    reuse="$(jq -r '.reuseExisting != false' <<<"$app")"
    [[ "$reuse" == "true" ]] || continue
    matcher="$(jq -r '.match // ""' <<<"$app")"
    [[ -n "$matcher" ]] || continue
    while IFS= read -r addr; do
      [[ -n "$addr" ]] || continue
      if ! grep -Fxq "$addr" <<<"$seen"; then
        printf '%s\n' "$addr"
        seen+="$addr"$'\n'
      fi
    done < <(window_matches_regex "$matcher")
  done < <(jq -c '.[]' <<<"$target_apps")
}

close_all_windows() {
  local target_apps="${1:-[]}" addr protected
  protected="$(reusable_target_addresses "$target_apps")"
  while IFS= read -r addr; do
    [[ -n "$addr" ]] || continue
    # `Reuse existing` is authoritative: even the broad shutdown mode keeps
    # concrete windows required by the target workflow.
    grep -Fxq "$addr" <<<"$protected" && continue
    hypr_close_window "address:$addr"
  done < <(clients_json | jq -r '.[].address // empty')
}

close_current_workflow_windows() {
  local target_apps="$1" active_id old apps app matcher addr seen="" protected
  protected="$(reusable_target_addresses "$target_apps")"
  active_id="$(jq -r '.activeWorkflow // ""' "$CONFIG_FILE")"
  [[ -n "$active_id" ]] || return 0
  old="$(jq -c --arg id "$active_id" '.workflows[]? | select(.id==$id)' "$CONFIG_FILE")"
  [[ -n "$old" ]] || return 0
  apps="$(jq -c '.apps // []' <<<"$old")"
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    matcher="$(jq -r '.match // ""' <<<"$app")"
    [[ -n "$matcher" ]] || continue
    while IFS= read -r addr; do
      [[ -n "$addr" ]] || continue
      # Never close a concrete window the target workflow intends to reuse,
      # even if the old and new workflow store different app identities.
      grep -Fxq "$addr" <<<"$protected" && continue
      if ! grep -Fxq "$addr" <<<"$seen"; then
        hypr_close_window "address:$addr"
        seen+="$addr"$'\n'
      fi
    done < <(window_matches_regex "$matcher")
  done < <(jq -c '.[]' <<<"$apps")
}

count_current_workflow_windows() {
  local target_apps="$1" active_id old apps app matcher addr seen="" protected
  protected="$(reusable_target_addresses "$target_apps")"
  active_id="$(jq -r '.activeWorkflow // ""' "$CONFIG_FILE")"
  [[ -n "$active_id" ]] || { echo 0; return; }
  old="$(jq -c --arg id "$active_id" '.workflows[]? | select(.id==$id)' "$CONFIG_FILE")"
  [[ -n "$old" ]] || { echo 0; return; }
  apps="$(jq -c '.apps // []' <<<"$old")"
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    matcher="$(jq -r '.match // ""' <<<"$app")"
    [[ -n "$matcher" ]] || continue
    while IFS= read -r addr; do
      [[ -n "$addr" ]] || continue
      grep -Fxq "$addr" <<<"$protected" && continue
      if ! grep -Fxq "$addr" <<<"$seen"; then seen+="$addr"$'\n'; fi
    done < <(window_matches_regex "$matcher")
  done < <(jq -c '.[]' <<<"$apps")
  grep -cve '^$' <<<"$seen" || true
}

count_close_for_target() {
  migrate_config
  local id="${1:?workflow id required}" workflow mode apps active_id protected all_count protected_count
  workflow="$(jq -c --arg id "$id" '.workflows[]? | select(.id==$id)' "$CONFIG_FILE")"
  [[ -n "$workflow" ]] || fail "Unknown workflow: $id"
  mode="$(normalize_shutdown_mode "$(jq -r '.shutdownMode // "current"' <<<"$workflow")")"
  apps="$(jq -c '.apps // []' <<<"$workflow")"
  active_id="$(jq -r '.activeWorkflow // ""' "$CONFIG_FILE")"

  # Re-selecting the active workflow is a reconcile operation.  "keep" and
  # "current" do not tear it down, but "all" is an enforce-workflow mode:
  # reusable target windows are protected and every other open window closes.
  if [[ "$active_id" == "$id" ]]; then
    case "$mode" in
      keep|current) echo 0 ;;
      all)
        all_count="$(count_windows)"
        protected="$(reusable_target_addresses "$apps")"
        protected_count="$(grep -cve '^$' <<<"$protected" || true)"
        (( all_count > protected_count )) && echo $((all_count - protected_count)) || echo 0
        ;;
    esac
    return 0
  fi

  case "$mode" in
    keep) echo 0 ;;
    all)
      all_count="$(count_windows)"
      protected="$(reusable_target_addresses "$apps")"
      protected_count="$(grep -cve '^$' <<<"$protected" || true)"
      (( all_count > protected_count )) && echo $((all_count - protected_count)) || echo 0
      ;;
    current) count_current_workflow_windows "$apps" ;;
  esac
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
        if ! grep -Fxq "$addr" "$baseline"; then hypr_move_window "$workspace" "address:$addr"; fi
      done < <(clients_json | jq -r --arg re "$matcher" --arg target "$workspace" '
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
    sleep 0.30
  done
}

run_workflow() {
  migrate_config
  require_cmd hyprctl
  require_cmd jq
  local id="${1:?workflow id required}" workflow mode start_ws apps baseline app ws matcher reuse command desktop_id active_id same_workflow=false
  workflow="$(jq -c --arg id "$id" '.workflows[]? | select(.id==$id)' "$CONFIG_FILE")"
  [[ -n "$workflow" ]] || fail "Unknown workflow: $id"
  mode="$(normalize_shutdown_mode "$(jq -r '.shutdownMode // "current"' <<<"$workflow")")"
  start_ws="$(jq -r '.startWorkspace|tostring' <<<"$workflow")"
  apps="$(jq -c '.apps // []' <<<"$workflow")"
  active_id="$(jq -r '.activeWorkflow // ""' "$CONFIG_FILE")"
  [[ "$active_id" == "$id" ]] && same_workflow=true

  # Selecting the workflow that is already active normally means "put this
  # workflow back where it belongs".  In broad/enforce mode, however, also
  # close windows that are not reusable members of the target workflow.
  if [[ "$same_workflow" == "true" ]]; then
    case "$mode" in
      all) close_all_windows "$apps"; sleep 0.5 ;;
      current|keep) : ;;
    esac
  else
    case "$mode" in
      all) close_all_windows "$apps"; sleep 1 ;;
      current) close_current_workflow_windows "$apps"; sleep 1 ;;
      keep) : ;;
    esac
  fi

  baseline="$(mktemp "$STATE_DIR/.baseline.XXXXXX")"
  clients_json | jq -r '.[].address // empty' | sort -u >"$baseline"

  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    ws="$(jq -r '.workspace|tostring' <<<"$app")"
    matcher="$(jq -r '.match // ""' <<<"$app")"
    reuse="$(jq -r '.reuseExisting != false' <<<"$app")"
    if [[ "$reuse" == "true" && -n "$matcher" ]]; then
      # Reuse every matching window, not only the first one. This keeps, for
      # example, multiple browser windows together on the workflow workspace.
      if move_existing_windows "$matcher" "$ws"; then
        continue
      fi
    fi
    desktop_id="$(jq -r '.desktopId // ""' <<<"$app")"
    [[ -z "$desktop_id" ]] || require_cmd gtk-launch
    command="$(app_launch_command "$app")"
    [[ -n "$command" ]] || continue
    hypr_launch_workspace "$ws" "$command" || true
    sleep 0.12
  done < <(jq -c '.[]' <<<"$apps")

  relocate_new_windows "$baseline" "$apps"
  hypr_focus_workspace "$start_ws"
  rm -f "$baseline"
  atomic_jq '.activeWorkflow=$id' --arg id "$id"
  if [[ "$same_workflow" == "true" ]]; then
    printf 'Reconciled %s.\n' "$(jq -r '.name' <<<"$workflow")"
  else
    printf 'Launched %s.\n' "$(jq -r '.name' <<<"$workflow")"
  fi
}

active_workspace() {
  require_cmd hyprctl
  require_cmd jq
  hyprctl activeworkspace -j 2>/dev/null | jq -r '.id // 1' 2>/dev/null || echo 1
}

close_all_now() {
  require_cmd hyprctl
  require_cmd jq
  close_all_windows '[]'
  atomic_jq '.activeWorkflow=""'
  printf 'Closed all windows.
'
}

capture_windows() {
  require_cmd hyprctl
  require_cmd jq
  local clients active_ws
  clients="$(clients_json)"
  active_ws="$(active_workspace)"
  jq -n --argjson activeWorkspace "$active_ws" --argjson clients "$clients" '{
    activeWorkspace: $activeWorkspace,
    windows: [
      $clients[]
      | select((.mapped // true) != false)
      | {
          address:(.address // ""),
          workspace:((.workspace.id // 1) | tonumber),
          class:(.class // ""),
          initialClass:(.initialClass // ""),
          title:(.title // ""),
          initialTitle:(.initialTitle // ""),
          pid:(.pid // 0)
        }
    ]
  }'
}

write_startup_file() {
  cat >"$STARTUP_FILE" <<STARTUP_EOF
-- Generated by Omarchy Workflows. Do not edit this file by hand.
hl.on("hyprland.start", function()
  hl.exec_cmd("bash -lc 'sleep 2; ${PLUGIN_BACKEND} run-startup >/dev/null 2>&1 &'" )
end)
STARTUP_EOF
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
  migrate_config
  local id
  id="$(jq -r '.startupWorkflow // ""' "$CONFIG_FILE")"
  remove_hook_block
  if [[ -z "$id" ]]; then rm -f "$STARTUP_FILE"; return 0; fi
  write_startup_file
  touch "$AUTOSTART_FILE"
  {
    printf '\n%s\n' "$HOOK_BEGIN"
    printf '%s\n' "$HOOK_LINE"
    printf '%s\n' "$HOOK_END"
  } >>"$AUTOSTART_FILE"
}

set_startup() {
  migrate_config
  local id="${1:-}"
  if [[ -n "$id" ]]; then
    jq -e --arg id "$id" '.workflows[] | select(.id==$id)' "$CONFIG_FILE" >/dev/null || fail "Unknown workflow: $id"
  fi
  atomic_jq '.startupWorkflow=$id' --arg id "$id"
  sync_startup_hook
  if [[ -n "$id" ]]; then printf 'This workflow will run at your next Hyprland login.\n'; else printf 'Login workflow cleared.\n'; fi
}

run_startup() {
  migrate_config
  local id
  id="$(jq -r '.startupWorkflow // ""' "$CONFIG_FILE")"
  [[ -n "$id" ]] || exit 0
  run_workflow "$id"
}

diagnose() {
  migrate_config
  printf 'Config: %s\n' "$CONFIG_FILE"
  jq -e . "$CONFIG_FILE" >/dev/null && printf 'JSON: OK\n'
  command -v hyprctl >/dev/null && printf 'hyprctl: OK\n' || printf 'hyprctl: MISSING\n'
  command -v jq >/dev/null && printf 'jq: OK\n' || printf 'jq: MISSING\n'
  command -v gtk-launch >/dev/null && printf 'gtk-launch: OK\n' || printf 'gtk-launch: MISSING (application picker entries need gtk3)\n'
  printf 'Version: %s\n' "$(jq -r '.version // 1' "$CONFIG_FILE")"
  printf 'Workflows: %s\n' "$(jq '.workflows|length' "$CONFIG_FILE")"
  printf 'Current: %s\n' "$(current)"
  printf 'Open windows: %s\n' "$(count_windows 2>/dev/null || echo '?')"
}

migrate_config

case "${1:-config}" in
  config) config ;;
  current) current ;;
  add-workflow) shift; add_workflow "$@" ;;
  create-workflow-json) shift; create_workflow_json "$@" ;;
  replace-workflow) shift; replace_workflow "$@" ;;
  delete-workflow) shift; delete_workflow "$@" ;;
  count-windows) count_windows ;;
  count-close) shift; count_close_for_target "$@" ;;
  capture) capture_windows ;;
  active-workspace) active_workspace ;;
  close-all-now) close_all_now ;;
  run) shift; run_workflow "$@" ;;
  set-startup) shift; set_startup "$@" ;;
  run-startup) run_startup ;;
  sync-startup) sync_startup_hook ;;
  diagnose) diagnose ;;
  *) fail "Usage: $0 {config|current|add-workflow|create-workflow-json|replace-workflow|delete-workflow|count-windows|count-close|capture|active-workspace|close-all-now|run|set-startup|run-startup|sync-startup|diagnose}" ;;
esac
