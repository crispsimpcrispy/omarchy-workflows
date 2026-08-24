# Omarchy Workflows

> **v0.2.4:** fixes reuse across workflows by protecting the actual open Hyprland window addresses before the shutdown phase.

A top-bar workflow/session launcher for Omarchy Quattro.

Workflows lets you capture or build reusable desktop setups, then switch between them with one click. Each application can be assigned to a Hyprland workspace and can either reuse an existing window or launch a new one.

## v0.2.4 highlights

- Searchable **application picker** powered by Quickshell `DesktopEntries`
- Picker works with normal apps, Flatpaks and Omarchy web apps that expose `.desktop` entries
- **Capture Desktop** creates a workflow from your currently open Hyprland windows
- **Reuse existing** per app: move an existing matching window instead of launching a duplicate
- Three workflow shutdown modes:
  - **Close current workflow** — close apps belonging to the previously active workflow, but preserve apps the new workflow will reuse
  - **Keep existing windows** — close nothing
  - **Close all windows** — graceful close request to every current Hyprland client
- Existing v0.1 configuration is migrated automatically to the v2 data format
- Desktop-entry apps are launched via `gtk-launch`, so Flatpak/web-app launcher details stay inside their normal desktop file

## Example

### Work

- Workspace 1 — Browser
- Workspace 2 — Obsidian
- Workspace 3 — Zotero Flatpak
- Workspace 4 — Spotify

### Relax

- Workspace 1 — Browser
- Workspace 2 — Steam

If Browser is already open when switching from Work to Relax and **Reuse existing** is enabled, Workflows moves that existing browser window to Relax's requested workspace instead of opening another browser.

## Application picker

Choose **Edit → Pick Application** and search your installed application database.

The picker uses the desktop-entry ID instead of requiring you to know commands such as:

```text
flatpak run org.zotero.Zotero
omarchy-launch-webapp https://chatgpt.com
```

For example, selecting Zotero stores its desktop entry (`org.zotero.Zotero`) and selecting the Omarchy ChatGPT web app stores the ChatGPT desktop entry. At launch time Workflows uses:

```bash
gtk-launch <desktop-entry-id>
```

You can still use **Custom** when you genuinely want an arbitrary command.

## Capture Desktop

Arrange your desktop how you want it, then choose **Capture Desktop**.

Workflows reads `hyprctl clients -j`, records each application's workspace, and uses Quickshell's desktop-entry lookup to identify the application where possible. The captured workflow opens immediately in the editor so you can review it before relying on it.

Multiple windows from the same detected application are collapsed to one workflow app entry. Applications that cannot be matched to a desktop entry are captured on a best-effort basis and should have their command checked in the editor.

## Reuse existing applications

Each app row has **Reuse existing: ON/OFF**.

When ON and a matcher finds an existing window, Workflows:

1. does not launch a duplicate;
2. silently moves the matching existing window to the requested workspace;
3. keeps that app alive when using **Close current workflow** and the same app is part of the new workflow.

The matcher is a case-insensitive regex against Hyprland `class`, `initialClass`, `title`, and `initialTitle`.

The picker creates a matcher from the desktop entry's `StartupWMClass`, desktop-file ID and application name. You can edit it manually when an app has unusual window behaviour.

## Shutdown behaviour

### Close current workflow

Recommended default.

Only windows belonging to the plugin's previously active workflow are closed. Windows unrelated to that workflow are left alone. Apps present in both workflows and marked **Reuse existing** are preserved and moved.

### Keep existing windows

Nothing is closed. Workflows reuses matching apps when possible and launches missing apps.

### Close all windows

Sends a normal close request to every current Hyprland client before setting up the new workflow.

This is deliberately not a force-kill. Applications with unsaved work can show their normal save prompt.

## Configuration

Workflow data lives outside the Git checkout:

```text
~/.config/omarchy/workflows/workflows.json
```

Updating the plugin does not overwrite your workflows.

v0.1 configurations are migrated to version 2 automatically. The old `closeExisting: true` behaviour migrates to **Close all windows** to preserve its previous meaning; you can then change individual workflows to **Close current workflow** in the editor.

## Login workflow

A workflow can still be marked **Run at login**.

The plugin manages:

```text
~/.config/hypr/omarchy_workflows_startup.lua
```

and only this marked block in `~/.config/hypr/autostart.lua`:

```lua
-- BEGIN omarchy-workflows
require("hypr.omarchy_workflows_startup")
-- END omarchy-workflows
```

## Validate on Omarchy

Before pushing/installing a release:

```bash
./self-test.sh
omarchy plugin validate .
qmllint -I "$OMARCHY_PATH/shell" BarWidget.qml Panel.qml
```

The included backend self-test covers configuration migration, desktop capture data, desktop-entry launching, reuse/move behaviour, close-current-workflow behaviour and close-all behaviour.

## GitHub workflow

Recommended repository:

```text
https://github.com/crispsimpcrispy/omarchy-workflows
```

From your development checkout:

```bash
git add .
git commit -m "Add app picker, capture and smarter workflow switching"
git push
```

Then update the installed plugin:

```bash
omarchy plugin update io.github.crispsimpcrispy.workflows --yes
omarchy restart shell
```

## Troubleshooting

```bash
~/.config/omarchy/plugins/io.github.crispsimpcrispy.workflows/backend.sh diagnose
```

```bash
omarchy plugin validate ~/.config/omarchy/plugins/io.github.crispsimpcrispy.workflows
qmllint -I "$OMARCHY_PATH/shell" \
  ~/.config/omarchy/plugins/io.github.crispsimpcrispy.workflows/BarWidget.qml \
  ~/.config/omarchy/plugins/io.github.crispsimpcrispy.workflows/Panel.qml
```

```bash
qs log -p "$OMARCHY_PATH/shell" --tail 100
```

## Uninstall cleanup

Removing the plugin intentionally leaves your workflow data behind. To remove everything it generated:

```bash
rm -rf ~/.config/omarchy/workflows
rm -f ~/.config/hypr/omarchy_workflows_startup.lua
```

Then remove the marked `omarchy-workflows` block from `~/.config/hypr/autostart.lua` if a login workflow was enabled.

## v0.2.4 reuse semantics

- Selecting the workflow that is already active is **idempotent**: no windows are closed. Existing matching windows are moved back to their configured workspaces and only missing apps are launched.
- `Reuse existing` now protects matching target windows before shutdown, including in the broad close mode.
- All matching existing windows are moved to the configured workspace, not just the first match.
- The broad shutdown option therefore means "close all other windows"; reusable target windows survive.


## v0.2.4 behaviour clarification

`Close all other windows` is the **enforce workflow** mode.

If Work is already active and you select Work again, reusable Work applications
stay open and are moved back to their configured workspaces. Any unrelated open
windows are closed. Missing Work applications are then launched.

`Close current workflow` intentionally preserves unrelated windows when
switching workflows. `Keep existing windows` never performs cleanup.
