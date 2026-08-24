import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.crispsimpcrispy.workflows"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property string backendPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.crispsimpcrispy.workflows/backend.sh"

  property var configData: ({ workflows: [], activeWorkflow: "", startupWorkflow: "" })
  property string mode: "list" // list | edit | picker
  property string selectedWorkflowId: ""
  property string shutdownModeValue: "current"
  property int pickerReplaceIndex: -1
  property string pickerQuery: ""

  property bool confirmOpen: false
  property string confirmWorkflowId: ""
  property string confirmWorkflowName: ""
  property string confirmShutdownMode: "current"
  property int currentWorkspaceId: 1
  property int confirmWindowCount: 0
  property string confirmAction: "workflow"

  property bool actionBusy: false
  property string statusMessage: ""
  property bool statusError: false
  property string pendingAction: ""
  property string pendingOpenEditorId: ""

  readonly property color foreground: root.bar ? root.bar.foreground : Color.foreground
  readonly property color background: Color.popups.background
  readonly property color borderColor: Color.popups.border
  readonly property color selectedBackground: Color.menu.selectedBackground
  readonly property color selectedText: Color.menu.selectedText
  readonly property color accentBorder: Util.alpha(root.selectedBackground, 0.95)
  readonly property color mutedText: Util.alpha(root.foreground, 0.62)
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property int cornerRadius: Style.cornerRadius

  function parseJson(text, fallback) {
    try { return JSON.parse(String(text || "")) } catch (e) { return fallback }
  }

  function regexEscape(value) {
    return String(value || "").replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  }

  function open(payloadJson) {
    root.mode = "list"
    root.confirmOpen = false
    root.statusMessage = ""
    root.controller.show()
    root.refreshConfig()
  }

  function close() {
    root.confirmOpen = false
    root.controller.hide()
  }

  function toggle(payloadJson) {
    if (root.opened) root.close()
    else root.open(payloadJson || "{}")
  }

  function closeForPopoutSwitch() { root.controller.hide() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  function refreshRuntime() {
    if (!workspaceProc.running) {
      workspaceProc.command = [root.backendPath, "active-workspace"]
      workspaceProc.running = true
    }
  }

  function refreshConfig() {
    root.refreshRuntime()
    if (configProc.running) return
    configProc.command = [root.backendPath, "config"]
    configProc.running = true
  }

  function shutdownLabel(mode) {
    if (mode === "all") return "Close all other windows"
    if (mode === "keep") return "Keep everything"
    return "Close current workflow"
  }

  function rebuildWorkflowModel() {
    workflowModel.clear()
    var rows = root.configData.workflows || []
    for (var i = 0; i < rows.length; ++i) {
      var w = rows[i] || ({})
      var sm = String(w.shutdownMode || (w.closeExisting === false ? "keep" : "all"))
      var wsSeen = ({})
      var wsList = []
      var apps = w.apps || []
      for (var j = 0; j < apps.length; ++j) {
        var ws = String(apps[j].workspace || "")
        if (ws && !wsSeen[ws]) { wsSeen[ws] = true; wsList.push(ws) }
      }
      wsList.sort(function(a, b) { return parseInt(a) - parseInt(b) })
      workflowModel.append({
        workflowId: String(w.id || ""),
        name: String(w.name || "Untitled"),
        icon: String(w.icon || "W"),
        shutdownMode: sm,
        startWorkspace: Number(w.startWorkspace || 1),
        appCount: apps.length,
        workspaceSummary: wsList.join(","),
        isActive: String(root.configData.activeWorkflow || "") === String(w.id || ""),
        isStartup: String(root.configData.startupWorkflow || "") === String(w.id || "")
      })
    }
  }

  function findWorkflow(id) {
    var rows = root.configData.workflows || []
    for (var i = 0; i < rows.length; ++i)
      if (String(rows[i].id) === String(id)) return rows[i]
    return null
  }

  function openEditor(id) {
    var w = root.findWorkflow(id)
    if (!w) return
    root.selectedWorkflowId = String(w.id)
    nameInput.text = String(w.name || "")
    iconInput.text = String(w.icon || "W")
    workspaceInput.text = String(w.startWorkspace || 1)
    root.shutdownModeValue = String(w.shutdownMode || (w.closeExisting === false ? "keep" : "all"))
    appEditModel.clear()
    var apps = w.apps || []
    for (var i = 0; i < apps.length; ++i) {
      var a = apps[i] || ({})
      appEditModel.append({
        appName: String(a.name || "Application"),
        workspace: String(a.workspace || 1),
        desktopId: String(a.desktopId || ""),
        command: String(a.command || ""),
        match: String(a.match || ""),
        reuseExisting: a.reuseExisting !== false,
        icon: String(a.icon || "")
      })
    }
    root.mode = "edit"
    root.statusMessage = ""
  }

  function createWorkflow() {
    root.pendingAction = "open-new"
    root.runAction(["add-workflow", "New Workflow", "W"], "Creating workflow…")
  }

  function appObject(row) {
    return {
      name: String(row.appName || "Application"),
      workspace: Number(row.workspace || 1),
      desktopId: String(row.desktopId || ""),
      command: String(row.command || ""),
      match: String(row.match || ""),
      reuseExisting: row.reuseExisting !== false,
      icon: String(row.icon || "")
    }
  }

  function saveWorkflow() {
    var startWs = parseInt(workspaceInput.text)
    if (isNaN(startWs) || startWs < 1) {
      root.statusError = true
      root.statusMessage = "Start workspace must be 1 or higher."
      return
    }
    if (!nameInput.text.trim()) {
      root.statusError = true
      root.statusMessage = "Workflow name cannot be empty."
      return
    }

    var apps = []
    for (var i = 0; i < appEditModel.count; ++i) {
      var row = appEditModel.get(i)
      var ws = parseInt(row.workspace)
      if (isNaN(ws) || ws < 1) {
        root.statusError = true
        root.statusMessage = "Every application needs a workspace of 1 or higher."
        return
      }
      if (!String(row.desktopId || "").trim() && !String(row.command || "").trim()) {
        root.statusError = true
        root.statusMessage = "Every application needs a desktop entry or custom launch command."
        return
      }
      apps.push(root.appObject(row))
    }

    var workflow = {
      id: root.selectedWorkflowId,
      name: nameInput.text.trim(),
      icon: iconInput.text.trim() || "W",
      shutdownMode: root.shutdownModeValue,
      startWorkspace: startWs,
      apps: apps
    }
    root.pendingAction = "saved"
    root.runAction(["replace-workflow", root.selectedWorkflowId, JSON.stringify(workflow)], "Saving workflow…")
  }

  function requestLaunch(id, name, shutdownMode) {
    root.confirmAction = "workflow"
    root.confirmWorkflowId = id
    root.confirmWorkflowName = name
    root.confirmShutdownMode = shutdownMode || "current"
    if (root.confirmShutdownMode === "keep") {
      root.launchWorkflow(id, name)
      return
    }
    if (countProc.running) return
    countProc.command = [root.backendPath, "count-close", id]
    countProc.running = true
  }

  function requestCloseAll() {
    root.confirmAction = "close-all"
    root.confirmWorkflowId = ""
    root.confirmWorkflowName = ""
    root.confirmShutdownMode = "all"
    if (countProc.running) return
    countProc.command = [root.backendPath, "count-windows"]
    countProc.running = true
  }

  function closeAllNow() {
    root.confirmOpen = false
    root.statusError = false
    root.pendingAction = "close-all"
    root.runAction(["close-all-now"], "Closing all windows…")
  }

  function launchWorkflow(id, name) {
    root.confirmOpen = false
    root.statusError = false
    root.statusMessage = "Switching to " + name + "…"
    root.pendingAction = "run"
    runProc.command = [root.backendPath, "run", id]
    runProc.running = true
    if (root.hostWidget) root.hostWidget.currentWorkflowName = name
    root.close()
  }

  function runAction(args, message) {
    if (actionProc.running) return
    root.actionBusy = true
    root.statusError = false
    root.statusMessage = message || "Working…"
    actionProc.command = [root.backendPath].concat(args)
    actionProc.running = true
  }

  function setStartup(id) {
    root.pendingAction = "startup"
    root.runAction(["set-startup", id], id ? "Setting login workflow…" : "Clearing login workflow…")
  }

  function deleteSelectedWorkflow() {
    root.pendingAction = "deleted"
    root.runAction(["delete-workflow", root.selectedWorkflowId], "Deleting workflow…")
  }

  function openPicker(replaceIndex) {
    root.pickerReplaceIndex = replaceIndex === undefined ? -1 : replaceIndex
    root.pickerQuery = ""
    pickerSearch.text = ""
    root.mode = "picker"
    Qt.callLater(function() { pickerSearch.forceActiveFocus() })
  }

  function matcherForEntry(entry) {
    var parts = []
    if (entry && entry.startupClass) parts.push(root.regexEscape(entry.startupClass))
    if (entry && entry.id) parts.push(root.regexEscape(entry.id))
    if (entry && entry.name) parts.push(root.regexEscape(entry.name))
    var unique = []
    var seen = ({})
    for (var i = 0; i < parts.length; ++i) {
      var key = parts[i].toLowerCase()
      if (!seen[key]) { seen[key] = true; unique.push(parts[i]) }
    }
    return unique.join("|")
  }

  function chooseDesktopEntry(entry) {
    if (!entry) return
    var row = {
      appName: String(entry.name || entry.id || "Application"),
      workspace: "1",
      desktopId: String(entry.id || ""),
      command: "",
      match: root.matcherForEntry(entry),
      reuseExisting: true,
      icon: String(entry.icon || "")
    }
    if (root.pickerReplaceIndex >= 0 && root.pickerReplaceIndex < appEditModel.count) {
      var old = appEditModel.get(root.pickerReplaceIndex)
      row.workspace = String(old.workspace || "1")
      appEditModel.set(root.pickerReplaceIndex, row)
    } else {
      appEditModel.append(row)
    }
    root.mode = "edit"
    root.statusError = false
    root.statusMessage = "Added " + row.appName + " from its desktop entry."
  }

  function addCustomApp() {
    appEditModel.append({
      appName: "Custom command",
      workspace: "1",
      desktopId: "",
      command: "",
      match: "",
      reuseExisting: true,
      icon: ""
    })
    root.mode = "edit"
  }

  function entryForWindow(win) {
    var candidates = [win.initialClass, win.class, win.initialTitle, win.title]
    for (var i = 0; i < candidates.length; ++i) {
      var value = String(candidates[i] || "").trim()
      if (!value) continue
      var entry = DesktopEntries.heuristicLookup(value)
      if (entry) return entry
    }
    return null
  }

  function captureDesktop() {
    if (captureProc.running || actionProc.running) return
    root.statusError = false
    root.statusMessage = "Capturing current desktop…"
    captureProc.command = [root.backendPath, "capture"]
    captureProc.running = true
  }

  function buildCapturedWorkflow(data) {
    var windows = data.windows || data || []
    var apps = []
    var seen = ({})
    var unmatched = 0

    for (var i = 0; i < windows.length; ++i) {
      var win = windows[i] || ({})
      var cls = String(win.initialClass || win.class || "").trim()
      var entry = root.entryForWindow(win)
      var desktopId = entry ? String(entry.id || "") : ""
      var identity = (desktopId ? "desktop:" + desktopId : "class:" + cls).toLowerCase()
      if (!identity || seen[identity]) continue
      seen[identity] = true

      var displayName = entry ? String(entry.name || desktopId) : String(win.title || cls || "Application")
      var matcher = entry ? root.matcherForEntry(entry) : root.regexEscape(cls || displayName)
      var command = ""
      if (!desktopId) {
        // Best effort for unusual apps without a desktop entry. The editor opens
        // immediately after capture so this can be corrected before first use.
        command = cls
        unmatched++
      }

      apps.push({
        name: displayName,
        workspace: Number(win.workspace || 1),
        desktopId: desktopId,
        command: command,
        match: matcher,
        reuseExisting: true,
        icon: entry ? String(entry.icon || "") : ""
      })
    }

    var workflow = {
      name: "Captured Desktop",
      icon: "C",
      shutdownMode: "current",
      startWorkspace: Number(data.activeWorkspace || 1),
      apps: apps
    }

    root.pendingAction = "captured"
    root.statusMessage = unmatched > 0
      ? "Captured desktop; " + unmatched + " app" + (unmatched === 1 ? " needs" : "s need") + " its command checked."
      : "Captured desktop."
    root.runAction(["create-workflow-json", JSON.stringify(workflow)], root.statusMessage)
  }

  function appIconSource(iconName) {
    if (!iconName) return ""
    return Quickshell.iconPath(iconName, true)
  }

  ListModel { id: workflowModel }
  ListModel { id: appEditModel }

  ScriptModel {
    id: pickerModel
    values: [...DesktopEntries.applications.values]
      .filter(function(entry) {
        var query = root.pickerQuery.trim().toLowerCase()
        if (!query) return true
        var hay = [entry.name, entry.id, entry.genericName, entry.comment, entry.startupClass]
          .join(" ").toLowerCase()
        var terms = query.split(/\s+/)
        for (var i = 0; i < terms.length; ++i)
          if (terms[i] && hay.indexOf(terms[i]) < 0) return false
        return true
      })
      .sort(function(a, b) { return String(a.name).localeCompare(String(b.name)) })
  }

  Process {
    id: workspaceProc
    stdout: StdioCollector { id: workspaceOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        var ws = parseInt(String(workspaceOut.text || "1").trim())
        if (!isNaN(ws) && ws > 0) root.currentWorkspaceId = ws
      }
    }
  }

  Process {
    id: configProc
    stdout: StdioCollector { id: configOut; waitForEnd: true }
    stderr: StdioCollector { id: configErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.configData = root.parseJson(configOut.text, { workflows: [], activeWorkflow: "", startupWorkflow: "" })
        root.rebuildWorkflowModel()
        if (root.pendingOpenEditorId) {
          var openId = root.pendingOpenEditorId
          root.pendingOpenEditorId = ""
          Qt.callLater(function() { root.openEditor(openId) })
        }
      } else {
        root.statusError = true
        root.statusMessage = String(configErr.text || "Could not read workflow configuration.").trim()
      }
    }
  }

  Process {
    id: countProc
    stdout: StdioCollector { id: countOut; waitForEnd: true }
    stderr: StdioCollector { id: countErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.statusError = true
        root.statusMessage = String(countErr.text || "Could not inspect open windows.").trim()
        return
      }
      var count = parseInt(String(countOut.text || "0").trim())
      if (isNaN(count)) count = 0
      root.confirmWindowCount = count
      if (root.confirmAction === "close-all") {
        if (count > 0) root.confirmOpen = true
        else {
          root.statusError = false
          root.statusMessage = "No windows are open."
        }
      } else {
        if (count > 0) root.confirmOpen = true
        else root.launchWorkflow(root.confirmWorkflowId, root.confirmWorkflowName)
      }
    }
  }

  Process {
    id: captureProc
    stdout: StdioCollector { id: captureOut; waitForEnd: true }
    stderr: StdioCollector { id: captureErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.statusError = true
        root.statusMessage = String(captureErr.text || "Could not capture desktop.").trim()
        return
      }
      var data = root.parseJson(captureOut.text, { windows: [] })
      root.buildCapturedWorkflow(data)
    }
  }

  Process {
    id: runProc
    stdout: StdioCollector { id: runOut; waitForEnd: true }
    stderr: StdioCollector { id: runErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (root.hostWidget) root.hostWidget.refreshCurrent()
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.actionBusy = false
      if (exitCode !== 0) {
        root.statusError = true
        root.statusMessage = String(actionErr.text || "Action failed.").trim()
        root.pendingAction = ""
        return
      }

      var out = String(actionOut.text || "").trim()
      root.statusError = false
      if (root.pendingAction === "open-new" || root.pendingAction === "captured") {
        var result = root.parseJson(out, {})
        if (result.id) {
          root.selectedWorkflowId = String(result.id)
          root.pendingOpenEditorId = String(result.id)
        }
        root.refreshConfig()
      } else if (root.pendingAction === "saved") {
        root.statusMessage = out || "Saved."
        root.mode = "list"
        root.refreshConfig()
      } else if (root.pendingAction === "deleted") {
        root.statusMessage = out || "Deleted."
        root.mode = "list"
        root.selectedWorkflowId = ""
        root.refreshConfig()
      } else {
        root.statusMessage = out || "Done."
        root.refreshConfig()
      }
      root.pendingAction = ""
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher

    contentWidth: panel.fittedContentWidth(Style.space(800))
    contentHeight: panel.fittedContentHeight(root.mode === "edit" ? Style.space(720) : Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: {
        if (root.mode === "picker") root.mode = "edit"
        else if (root.mode === "edit") root.mode = "list"
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: listPage
        anchors.fill: parent
        spacing: Style.space(10)
        visible: root.mode === "list"

        Row {
          width: parent.width
          spacing: Style.space(8)

          Column {
            width: parent.width - closeAllButton.width - captureButton.width - addWorkflowButton.width - Style.space(24)
            spacing: Style.space(2)
            Text { text: "Workflows"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.subtitle; font.bold: true }
            Text { text: "Switch your whole desktop setup in one click."; color: root.mutedText; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
          }

          Rectangle {
            id: closeAllButton
            width: Style.space(88); height: Style.space(34); radius: Style.space(8)
            color: closeAllMouse.containsMouse ? Util.alpha(root.bar.urgent, 0.24) : Util.alpha(root.bar.urgent, 0.10)
            border.width: 1
            border.color: Util.alpha(root.bar.urgent, 0.42)
            Text { anchors.centerIn: parent; text: "Close All"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
            MouseArea { id: closeAllMouse; anchors.fill: parent; hoverEnabled: true; onClicked: root.requestCloseAll() }
          }

          Rectangle {
            id: captureButton
            width: Style.space(112); height: Style.space(34); radius: Style.space(8)
            color: captureMouse.containsMouse ? Util.alpha(root.foreground, 0.18) : Util.alpha(root.foreground, 0.08)
            border.width: 1
            border.color: Util.alpha(root.foreground, 0.12)
            Text { anchors.centerIn: parent; text: "Capture Desktop"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
            MouseArea { id: captureMouse; anchors.fill: parent; hoverEnabled: true; onClicked: root.captureDesktop() }
          }

          Rectangle {
            id: addWorkflowButton
            width: Style.space(86); height: Style.space(34); radius: Style.space(8)
            color: addWorkflowMouse.containsMouse ? Util.alpha(root.foreground, 0.18) : Util.alpha(root.foreground, 0.08)
            border.width: 1
            border.color: Util.alpha(root.foreground, 0.12)
            Text { anchors.centerIn: parent; text: "+ New"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
            MouseArea { id: addWorkflowMouse; anchors.fill: parent; hoverEnabled: true; onClicked: root.createWorkflow() }
          }
        }

        Rectangle { width: parent.width; height: 1; color: Util.alpha(root.foreground, 0.12) }

        ListView {
          id: workflowList
          width: parent.width
          height: Style.space(455)
          clip: true
          spacing: Style.space(7)
          model: workflowModel

          delegate: Rectangle {
            id: workflowRow
            required property int index
            required property string workflowId
            required property string name
            required property string icon
            required property string shutdownMode
            required property int startWorkspace
            required property int appCount
            required property string workspaceSummary
            required property bool isActive
            required property bool isStartup

            width: workflowList.width
            height: Style.space(98)
            radius: Style.space(10)
            color: workflowRow.isActive ? Util.alpha(root.selectedBackground, 0.18) : Util.alpha(root.foreground, 0.04)
            border.width: 1
            border.color: workflowRow.isActive ? root.accentBorder : Util.alpha(root.foreground, 0.10)

            Rectangle {
              visible: workflowRow.isActive
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              anchors.margins: Style.space(10)
              width: Style.space(4)
              radius: Style.space(2)
              color: root.selectedBackground
            }

            Row {
              anchors.fill: parent
              anchors.margins: Style.space(10)
              spacing: Style.space(10)

              Rectangle {
                width: Style.space(46); height: width; radius: Style.space(9)
                anchors.verticalCenter: parent.verticalCenter
                color: workflowRow.isActive ? Util.alpha(root.selectedBackground, 0.22) : Util.alpha(root.foreground, 0.08)
                border.width: 1
                border.color: workflowRow.isActive ? Util.alpha(root.selectedBackground, 0.55) : Util.alpha(root.foreground, 0.12)
                Text { anchors.centerIn: parent; text: workflowRow.icon; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.subtitle; font.bold: true }
              }

              Column {
                width: parent.width - Style.space(46) - editButton.width - launchButton.width - Style.space(40)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(5)
                Row {
                  spacing: Style.space(6)
                  Text { text: workflowRow.name; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
                  Rectangle {
                    visible: workflowRow.isActive
                    radius: Style.space(5)
                    color: Util.alpha(root.selectedBackground, 0.22)
                    border.width: 1
                    border.color: Util.alpha(root.selectedBackground, 0.55)
                    height: activeText.implicitHeight + Style.space(8)
                    width: activeText.implicitWidth + Style.space(12)
                    Text { id: activeText; anchors.centerIn: parent; text: "ACTIVE"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                  }
                  Rectangle {
                    visible: workflowRow.isStartup
                    radius: Style.space(5)
                    color: Util.alpha(root.foreground, 0.08)
                    border.width: 1
                    border.color: Util.alpha(root.foreground, 0.14)
                    height: loginText.implicitHeight + Style.space(8)
                    width: loginText.implicitWidth + Style.space(12)
                    Text { id: loginText; anchors.centerIn: parent; text: "LOGIN"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                  }
                }
                Text {
                  text: workflowRow.appCount + " apps · " + root.shutdownLabel(workflowRow.shutdownMode) + " · starts on workspace " + workflowRow.startWorkspace
                  color: root.mutedText; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
                }
                Row {
                  spacing: Style.space(5)
                  visible: workflowRow.workspaceSummary.length > 0
                  Repeater {
                    model: workflowRow.workspaceSummary.length > 0 ? workflowRow.workspaceSummary.split(",") : []
                    delegate: Rectangle {
                      required property var modelData
                      readonly property int wsValue: parseInt(modelData)
                      readonly property bool isCurrent: workflowRow.isActive && wsValue === root.currentWorkspaceId
                      height: workspaceChipText.implicitHeight + Style.space(8)
                      width: workspaceChipText.implicitWidth + Style.space(14)
                      radius: Style.space(5)
                      color: isCurrent ? Util.alpha(root.selectedBackground, 0.28) : Util.alpha(root.foreground, 0.06)
                      border.width: 1
                      border.color: isCurrent ? Util.alpha(root.selectedBackground, 0.72) : Util.alpha(root.foreground, 0.12)
                      Text {
                        id: workspaceChipText
                        anchors.centerIn: parent
                        text: isCurrent ? ("WS " + wsValue + " • open") : ("WS " + wsValue)
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: isCurrent
                      }
                    }
                  }
                }
              }

              Rectangle {
                id: editButton
                width: Style.space(62); height: Style.space(34); radius: Style.space(7); anchors.verticalCenter: parent.verticalCenter
                color: editMouse.containsMouse ? Util.alpha(root.foreground, 0.16) : Util.alpha(root.foreground, 0.07)
                border.width: 1
                border.color: Util.alpha(root.foreground, 0.12)
                Text { anchors.centerIn: parent; text: "Edit"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
                MouseArea { id: editMouse; anchors.fill: parent; hoverEnabled: true; onClicked: root.openEditor(workflowRow.workflowId) }
              }

              Rectangle {
                id: launchButton
                width: Style.space(76); height: Style.space(34); radius: Style.space(7); anchors.verticalCenter: parent.verticalCenter
                color: launchMouse.containsMouse ? Util.alpha(root.selectedBackground, 0.26) : Util.alpha(root.selectedBackground, 0.14)
                border.width: 1
                border.color: Util.alpha(root.selectedBackground, 0.55)
                Text { anchors.centerIn: parent; text: "Launch"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true }
                MouseArea { id: launchMouse; anchors.fill: parent; hoverEnabled: true; onClicked: root.requestLaunch(workflowRow.workflowId, workflowRow.name, workflowRow.shutdownMode) }
              }
            }
          }

          Text {
            anchors.centerIn: parent
            visible: workflowModel.count === 0
            text: "No workflows yet. Capture your desktop or create one."
            color: root.mutedText; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
          }
        }

        Rectangle {
          width: parent.width
          radius: Style.space(8)
          color: Util.alpha(root.foreground, 0.035)
          border.width: 1
          border.color: Util.alpha(root.foreground, 0.10)
          implicitHeight: statusText.implicitHeight + Style.space(18)
          Text {
            id: statusText
            anchors.fill: parent
            anchors.margins: Style.space(9)
            text: root.statusMessage || "Capture Desktop creates a workflow from the windows you have open right now."
            color: root.statusError ? root.bar.urgent : root.mutedText
            font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap
          }
        }
      }

      Column {
        id: editPage
        anchors.fill: parent
        spacing: Style.space(9)
        visible: root.mode === "edit"

        Row {
          width: parent.width; spacing: Style.space(8)
          Rectangle {
            width: Style.space(64); height: Style.space(32); radius: Style.space(5)
            color: backEditMouse.containsMouse ? Util.alpha(root.foreground, 0.16) : Util.alpha(root.foreground, 0.07)
            Text { anchors.centerIn: parent; text: "← Back"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
            MouseArea { id: backEditMouse; anchors.fill: parent; hoverEnabled: true; onClicked: root.mode = "list" }
          }
          Text { anchors.verticalCenter: parent.verticalCenter; text: "Edit Workflow"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.subtitle; font.bold: true }
        }

        Row {
          width: parent.width; spacing: Style.space(8)
          Column { width: Style.space(390); spacing: Style.space(3)
            Text { text: "Name"; color: root.mutedText; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            Rectangle { width: parent.width; height: Style.space(34); radius: Style.space(5); color: Util.alpha(root.foreground, 0.07)
              TextInput { id: nameInput; anchors.fill: parent; anchors.margins: Style.space(6); color: root.foreground; font.family: root.fontFamily; verticalAlignment: TextInput.AlignVCenter; selectByMouse: true }
            }
          }
          Column { width: Style.space(70); spacing: Style.space(3)
            Text { text: "Icon"; color: root.mutedText; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            Rectangle { width: parent.width; height: Style.space(34); radius: Style.space(5); color: Util.alpha(root.foreground, 0.07)
              TextInput { id: iconInput; anchors.fill: parent; anchors.margins: Style.space(6); color: root.foreground; font.family: root.fontFamily; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter; selectByMouse: true }
            }
          }
          Column { width: Style.space(92); spacing: Style.space(3)
            Text { text: "Start WS"; color: root.mutedText; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            Rectangle { width: parent.width; height: Style.space(34); radius: Style.space(5); color: Util.alpha(root.foreground, 0.07)
              TextInput { id: workspaceInput; anchors.fill: parent; anchors.margins: Style.space(6); color: root.foreground; font.family: root.fontFamily; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter; inputMethodHints: Qt.ImhDigitsOnly; selectByMouse: true }
            }
          }
        }

        Text { text: "When switching to this workflow"; color: root.mutedText; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
        Row {
          width: parent.width; spacing: Style.space(7)
          Repeater {
            model: [
              { value: "current", label: "Close current workflow" },
              { value: "keep", label: "Keep existing windows" },
              { value: "all", label: "Close all other windows" }
            ]
            delegate: Rectangle {
              required property var modelData
              width: Style.space(180); height: Style.space(34); radius: Style.space(6)
              color: root.shutdownModeValue === modelData.value ? Util.alpha(root.foreground, 0.18) : Util.alpha(root.foreground, 0.06)
              border.width: root.shutdownModeValue === modelData.value ? 1 : 0
              border.color: Util.alpha(root.foreground, 0.28)
              Text { anchors.centerIn: parent; text: modelData.label; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
              MouseArea { anchors.fill: parent; onClicked: root.shutdownModeValue = modelData.value }
            }
          }
        }

        Row {
          width: parent.width; spacing: Style.space(8)
          Text { anchors.verticalCenter: parent.verticalCenter; text: "Applications"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
          Item { width: parent.width - Style.space(330); height: 1 }
          Rectangle {
            width: Style.space(104); height: Style.space(30); radius: Style.space(5)
            color: customMouse.containsMouse ? Util.alpha(root.foreground, 0.16) : Util.alpha(root.foreground, 0.07)
            Text { anchors.centerIn: parent; text: "+ Custom"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
            MouseArea { id: customMouse; anchors.fill: parent; hoverEnabled: true; onClicked: root.addCustomApp() }
          }
          Rectangle {
            width: Style.space(118); height: Style.space(30); radius: Style.space(5)
            color: addAppMouse.containsMouse ? Util.alpha(root.foreground, 0.18) : Util.alpha(root.foreground, 0.08)
            Text { anchors.centerIn: parent; text: "+ Pick Application"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
            MouseArea { id: addAppMouse; anchors.fill: parent; hoverEnabled: true; onClicked: root.openPicker(-1) }
          }
        }

        ListView {
          id: appList
          width: parent.width
          height: Style.space(390)
          clip: true
          spacing: Style.space(7)
          model: appEditModel

          delegate: Rectangle {
            id: appRow
            required property int index
            required property string appName
            required property string workspace
            required property string desktopId
            required property string command
            required property string match
            required property bool reuseExisting
            required property string icon
            width: appList.width
            height: Style.space(126)
            radius: Style.space(7)
            color: Util.alpha(root.foreground, 0.04)

            Column {
              anchors.fill: parent; anchors.margins: Style.space(7); spacing: Style.space(5)

              Row {
                width: parent.width; spacing: Style.space(7)
                Item {
                  width: Style.space(32); height: Style.space(32)
                  Image { anchors.fill: parent; source: root.appIconSource(appRow.icon); fillMode: Image.PreserveAspectFit; asynchronous: true }
                  Text { anchors.centerIn: parent; visible: !appRow.icon; text: "•"; color: root.mutedText; font.pixelSize: Style.font.subtitle }
                }
                Rectangle {
                  width: Style.space(46); height: Style.space(31); radius: Style.space(5); color: Util.alpha(root.foreground, 0.07)
                  TextInput {
                    anchors.fill: parent; anchors.margins: Style.space(5); text: appRow.workspace; color: root.foreground; font.family: root.fontFamily; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter; inputMethodHints: Qt.ImhDigitsOnly; selectByMouse: true
                    onTextEdited: appEditModel.setProperty(appRow.index, "workspace", text)
                  }
                }
                Rectangle {
                  width: Style.space(175); height: Style.space(31); radius: Style.space(5); color: Util.alpha(root.foreground, 0.07)
                  TextInput {
                    anchors.fill: parent; anchors.margins: Style.space(5); text: appRow.appName; color: root.foreground; font.family: root.fontFamily; verticalAlignment: TextInput.AlignVCenter; selectByMouse: true; clip: true
                    onTextEdited: appEditModel.setProperty(appRow.index, "appName", text)
                  }
                }
                Text {
                  width: parent.width - Style.space(32) - Style.space(46) - Style.space(175) - changeAppButton.width - removeAppButton.width - Style.space(42)
                  anchors.verticalCenter: parent.verticalCenter
                  text: appRow.desktopId ? "Desktop: " + appRow.desktopId : "Command: " + (appRow.command || "not set")
                  color: root.mutedText; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; elide: Text.ElideMiddle
                }
                Rectangle {
                  id: changeAppButton
                  width: Style.space(64); height: Style.space(31); radius: Style.space(5); color: changeAppMouse.containsMouse ? Util.alpha(root.foreground, 0.16) : Util.alpha(root.foreground, 0.07)
                  Text { anchors.centerIn: parent; text: "Change"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                  MouseArea { id: changeAppMouse; anchors.fill: parent; hoverEnabled: true; onClicked: root.openPicker(appRow.index) }
                }
                Rectangle {
                  id: removeAppButton
                  width: Style.space(30); height: Style.space(31); radius: Style.space(5); color: removeAppMouse.containsMouse ? Util.alpha(root.foreground, 0.16) : "transparent"
                  Text { anchors.centerIn: parent; text: "×"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body }
                  MouseArea { id: removeAppMouse; anchors.fill: parent; hoverEnabled: true; onClicked: appEditModel.remove(appRow.index) }
                }
              }

              Row {
                width: parent.width; spacing: Style.space(7)
                Text { width: Style.space(92); anchors.verticalCenter: parent.verticalCenter; text: "Window match"; color: root.mutedText; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                Rectangle {
                  width: parent.width - Style.space(250); height: Style.space(29); radius: Style.space(5); color: Util.alpha(root.foreground, 0.06)
                  TextInput {
                    anchors.fill: parent; anchors.margins: Style.space(5); text: appRow.match; color: root.foreground; font.family: root.fontFamily; verticalAlignment: TextInput.AlignVCenter; selectByMouse: true; clip: true
                    onTextEdited: appEditModel.setProperty(appRow.index, "match", text)
                  }
                }
                Rectangle {
                  width: Style.space(142); height: Style.space(29); radius: Style.space(5)
                  color: appRow.reuseExisting ? Util.alpha(root.foreground, 0.16) : Util.alpha(root.foreground, 0.055)
                  Text { anchors.centerIn: parent; text: appRow.reuseExisting ? "Reuse existing: ON" : "Reuse existing: OFF"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                  MouseArea { anchors.fill: parent; onClicked: appEditModel.setProperty(appRow.index, "reuseExisting", !appRow.reuseExisting) }
                }
              }

              Row {
                width: parent.width; spacing: Style.space(7); visible: !appRow.desktopId
                Text { width: Style.space(92); anchors.verticalCenter: parent.verticalCenter; text: "Command"; color: root.mutedText; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                Rectangle {
                  width: parent.width - Style.space(99); height: Style.space(29); radius: Style.space(5); color: Util.alpha(root.foreground, 0.06)
                  TextInput {
                    anchors.fill: parent; anchors.margins: Style.space(5); text: appRow.command; color: root.foreground; font.family: root.fontFamily; verticalAlignment: TextInput.AlignVCenter; selectByMouse: true; clip: true
                    onTextEdited: appEditModel.setProperty(appRow.index, "command", text)
                  }
                }
              }
            }
          }
        }

        Row {
          width: parent.width; spacing: Style.space(8)
          Rectangle {
            width: Style.space(122); height: Style.space(34); radius: Style.space(6)
            color: startupMouse.containsMouse ? Util.alpha(root.foreground, 0.16) : Util.alpha(root.foreground, 0.07)
            Text { anchors.centerIn: parent; text: String(root.configData.startupWorkflow || "") === root.selectedWorkflowId ? "Clear login" : "Run at login"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
            MouseArea { id: startupMouse; anchors.fill: parent; hoverEnabled: true; onClicked: root.setStartup(String(root.configData.startupWorkflow || "") === root.selectedWorkflowId ? "" : root.selectedWorkflowId) }
          }
          Rectangle {
            width: Style.space(82); height: Style.space(34); radius: Style.space(6)
            color: deleteWorkflowMouse.containsMouse ? Util.alpha(root.bar.urgent, 0.22) : Util.alpha(root.bar.urgent, 0.10)
            Text { anchors.centerIn: parent; text: "Delete"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
            MouseArea { id: deleteWorkflowMouse; anchors.fill: parent; hoverEnabled: true; onClicked: root.deleteSelectedWorkflow() }
          }
          Item { width: parent.width - Style.space(122) - Style.space(82) - saveWorkflowButton.width - Style.space(24); height: 1 }
          Rectangle {
            id: saveWorkflowButton
            width: Style.space(118); height: Style.space(34); radius: Style.space(6)
            color: saveWorkflowMouse.containsMouse ? Util.alpha(root.foreground, 0.22) : Util.alpha(root.foreground, 0.11)
            Text { anchors.centerIn: parent; text: "Save Workflow"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true }
            MouseArea { id: saveWorkflowMouse; anchors.fill: parent; hoverEnabled: true; onClicked: root.saveWorkflow() }
          }
        }

        Text {
          width: parent.width
          text: root.statusMessage || "Picker apps use their .desktop entry, so native apps, Flatpaks and Omarchy web apps launch the same way as the normal app menu."
          color: root.statusError ? root.bar.urgent : root.mutedText
          font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap
        }
      }

      Column {
        id: pickerPage
        anchors.fill: parent
        spacing: Style.space(9)
        visible: root.mode === "picker"

        Row {
          width: parent.width; spacing: Style.space(8)
          Rectangle {
            width: Style.space(64); height: Style.space(32); radius: Style.space(5)
            color: backPickerMouse.containsMouse ? Util.alpha(root.foreground, 0.16) : Util.alpha(root.foreground, 0.07)
            Text { anchors.centerIn: parent; text: "← Back"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
            MouseArea { id: backPickerMouse; anchors.fill: parent; hoverEnabled: true; onClicked: root.mode = "edit" }
          }
          Text { anchors.verticalCenter: parent.verticalCenter; text: root.pickerReplaceIndex >= 0 ? "Change Application" : "Add Application"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.subtitle; font.bold: true }
        }

        Rectangle {
          width: parent.width; height: Style.space(38); radius: Style.space(6); color: Util.alpha(root.foreground, 0.07)
          TextInput {
            id: pickerSearch
            anchors.fill: parent; anchors.margins: Style.space(7)
            color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; verticalAlignment: TextInput.AlignVCenter; selectByMouse: true
            onTextChanged: root.pickerQuery = text
          }
          Text { anchors.left: parent.left; anchors.leftMargin: Style.space(8); anchors.verticalCenter: parent.verticalCenter; visible: !pickerSearch.text; text: "Search installed applications, Flatpaks and web apps…"; color: root.mutedText; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
        }

        Text { text: pickerModel.values.length + " matching applications"; color: root.mutedText; font.family: root.fontFamily; font.pixelSize: Style.font.caption }

        ListView {
          width: parent.width
          height: Style.space(455)
          clip: true
          spacing: Style.space(5)
          model: pickerModel

          delegate: Rectangle {
            id: pickerRow
            required property var modelData
            width: ListView.view.width
            height: Style.space(62)
            radius: Style.space(6)
            color: pickerMouse.containsMouse ? Util.alpha(root.foreground, 0.09) : Util.alpha(root.foreground, 0.035)

            Row {
              anchors.fill: parent; anchors.margins: Style.space(7); spacing: Style.space(9)
              Item {
                width: Style.space(38); height: width; anchors.verticalCenter: parent.verticalCenter
                Image { anchors.fill: parent; source: pickerRow.modelData.icon ? Quickshell.iconPath(pickerRow.modelData.icon, true) : ""; fillMode: Image.PreserveAspectFit; asynchronous: true }
              }
              Column {
                width: parent.width - Style.space(48); anchors.verticalCenter: parent.verticalCenter; spacing: Style.space(2)
                Text { width: parent.width; text: pickerRow.modelData.name; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true; elide: Text.ElideRight }
                Text { width: parent.width; text: pickerRow.modelData.id + (pickerRow.modelData.comment ? " · " + pickerRow.modelData.comment : ""); color: root.mutedText; font.family: root.fontFamily; font.pixelSize: Style.font.caption; elide: Text.ElideRight }
              }
            }
            MouseArea { id: pickerMouse; anchors.fill: parent; hoverEnabled: true; onClicked: root.chooseDesktopEntry(pickerRow.modelData) }
          }
        }

        Text { width: parent.width; text: "Applications are launched by desktop-file ID with gtk-launch, preserving Flatpak and Omarchy web-app launch behaviour."; color: root.mutedText; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
      }

      Rectangle {
        anchors.fill: parent
        z: 100
        visible: root.confirmOpen
        color: Util.alpha(root.background, 0.96)
        MouseArea { anchors.fill: parent }

        Column {
          width: Math.min(parent.width - Style.space(60), Style.space(500))
          anchors.centerIn: parent
          spacing: Style.space(12)

          Text { width: parent.width; text: root.confirmAction === "close-all" ? "Close every open window?" : ("Switch to " + root.confirmWorkflowName + "?"); color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.subtitle; font.bold: true; horizontalAlignment: Text.AlignHCenter }
          Text {
            width: parent.width
            text: root.confirmAction === "close-all"
              ? "This will send a normal close request to " + root.confirmWindowCount + " currently open window" + (root.confirmWindowCount === 1 ? "" : "s") + ". Unsaved apps may ask you to save before closing."
              : (root.confirmShutdownMode === "all"
                ? "This will close " + root.confirmWindowCount + " window" + (root.confirmWindowCount === 1 ? "" : "s") + " that are not part of the target workflow. Reusable workflow apps stay open and are moved into place."
                : "This will close " + root.confirmWindowCount + " window" + (root.confirmWindowCount === 1 ? "" : "s") + " from the currently active workflow. Applications marked Reuse existing in the new workflow are kept and moved instead.")
            color: root.mutedText; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter
          }
          Row {
            anchors.horizontalCenter: parent.horizontalCenter; spacing: Style.space(10)
            Rectangle {
              width: Style.space(90); height: Style.space(36); radius: Style.space(6); color: cancelMouse.containsMouse ? Util.alpha(root.foreground, 0.16) : Util.alpha(root.foreground, 0.07)
              Text { anchors.centerIn: parent; text: "Cancel"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
              MouseArea { id: cancelMouse; anchors.fill: parent; hoverEnabled: true; onClicked: root.confirmOpen = false }
            }
            Rectangle {
              width: Style.space(122); height: Style.space(36); radius: Style.space(6); color: switchMouse.containsMouse ? Util.alpha(root.foreground, 0.24) : Util.alpha(root.foreground, 0.12)
              Text { anchors.centerIn: parent; text: root.confirmAction === "close-all" ? "Close everything" : "Switch"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true }
              MouseArea { id: switchMouse; anchors.fill: parent; hoverEnabled: true; onClicked: { if (root.confirmAction === "close-all") root.closeAllNow(); else root.launchWorkflow(root.confirmWorkflowId, root.confirmWorkflowName) } }
            }
          }
        }
      }
    }
  }
}
