# Omarchy Workflows

A top-bar workflow launcher for Omarchy Quattro.

Pick a workflow and the plugin can gracefully close the current application windows, launch a new set of applications into assigned Hyprland workspaces, and leave you on the workflow's chosen starting workspace.

## Included starter workflows

### Work

- Workspace 1 — Browser (`omarchy-launch-browser`)
- Workspace 2 — Obsidian (`obsidian`)
- Workspace 3 — Zotero (`zotero`)
- Workspace 4 — Spotify (`omarchy-launch-spotify`)

### Relax

- Workspace 1 — Browser
- Workspace 2 — Steam (`steam`)

Everything is editable from the panel.

## Features

- Omarchy Quattro `bar-widget` with an anchored popup panel
- Unlimited named workflows
- Add/remove applications within each workflow
- Assign each application to a numeric Hyprland workspace
- Optional "close current windows first" per workflow
- Graceful window closing — no SIGKILL
- Confirmation showing how many open windows will receive a close request
- Configurable start workspace
- Optional workflow to run automatically at Hyprland login
- Window-class/title matcher fallback for Chromium/Electron/single-instance applications
- Tracks the most recently launched workflow for the bar tooltip

## Why the window matcher exists

Hyprland can launch an application with a one-shot workspace rule. Some applications hand window creation to an already-running or forked process, which can cause that rule to be missed. Workflows therefore supports an optional case-insensitive regex in **Window match**. It looks at the new window's `class`, `initialClass`, `title`, and `initialTitle`, then silently relocates matching windows to the requested workspace.

Examples:

```text
Obsidian: obsidian|md\.obsidian\.Obsidian
Spotify: spotify
Steam: steam
Browser: chromium|firefox|zen|brave|google-chrome|helium
```

You can inspect live window properties with:

```bash
hyprctl clients
```

## Safety

When `Close current application windows` is enabled, the plugin reads current Hyprland clients and sends each one a **graceful close request**. It does not use Hyprland's kill dispatcher and does not send SIGKILL.

Applications with unsaved work may therefore remain open and present their normal save confirmation. The new workflow still launches; this is intentional to avoid destroying unsaved work.

## Configuration

Workflow data is kept outside the plugin checkout so Git updates do not overwrite your workflows:

```text
~/.config/omarchy/workflows/workflows.json
```

If you enable **Run at login**, the plugin manages:

```text
~/.config/hypr/omarchy_workflows_startup.lua
```

and adds/removes only this marked block in `~/.config/hypr/autostart.lua`:

```lua
-- BEGIN omarchy-workflows
require("hypr.omarchy_workflows_startup")
-- END omarchy-workflows
```

## Validate before publishing

On your Omarchy machine:

```bash
omarchy plugin validate .
qmllint -I "$OMARCHY_PATH/shell" BarWidget.qml Panel.qml
bash -n backend.sh
```

## Suggested GitHub repository

```text
https://github.com/crispsimpcrispy/omarchy-workflows
```

Create it from this folder with:

```bash
git init
git branch -M main
git add .
git commit -m "Initial release"

gh repo create crispsimpcrispy/omarchy-workflows \
  --public \
  --source=. \
  --remote=origin \
  --push
```

Then install the GitHub-managed copy:

```bash
omarchy plugin add \
  https://github.com/crispsimpcrispy/omarchy-workflows.git \
  --enable

omarchy restart shell
```

Future updates:

```bash
omarchy plugin update io.github.crispsimpcrispy.workflows --yes
omarchy restart shell
```

## Troubleshooting

Check the backend:

```bash
~/.config/omarchy/plugins/io.github.crispsimpcrispy.workflows/backend.sh diagnose
```

Check plugin/QML validation:

```bash
omarchy plugin validate ~/.config/omarchy/plugins/io.github.crispsimpcrispy.workflows
qmllint -I "$OMARCHY_PATH/shell" \
  ~/.config/omarchy/plugins/io.github.crispsimpcrispy.workflows/BarWidget.qml \
  ~/.config/omarchy/plugins/io.github.crispsimpcrispy.workflows/Panel.qml
```

Check the Omarchy shell log:

```bash
qs log -p "$OMARCHY_PATH/shell" --tail 100
```

## Uninstall cleanup

Removing the plugin does not delete your workflows. To remove its generated configuration too:

```bash
rm -rf ~/.config/omarchy/workflows
rm -f ~/.config/hypr/omarchy_workflows_startup.lua
```

Then remove the marked `omarchy-workflows` block from `~/.config/hypr/autostart.lua` if you had enabled a login workflow.
