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
  property string mode: "list"
  property string selectedWorkflowId: ""
  property bool confirmOpen: false
  property string confirmWorkflowId: ""
  property string confirmWorkflowName: ""
  property int confirmWindowCount: 0
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
  readonly property color mutedText: Util.alpha(root.foreground, 0.62)
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property int cornerRadius: Style.cornerRadius

  function parseJson(text, fallback) {
    try { return JSON.parse(String(text || "")) } catch (e) { return fallback }
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

  function closeForPopoutSwitch() {
    root.controller.hide()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  function refreshConfig() {
    if (configProc.running) return
    configProc.command = [root.backendPath, "config"]
    configProc.running = true
  }

  function rebuildWorkflowModel() {
    workflowModel.clear()
    var rows = root.configData.workflows || []
    for (var i = 0; i < rows.length; ++i) {
      var w = rows[i] || ({})
      workflowModel.append({
        workflowId: String(w.id || ""),
        name: String(w.name || "Untitled"),
        icon: String(w.icon || "W"),
        closeExisting: w.closeExisting !== false,
        startWorkspace: Number(w.startWorkspace || 1),
        appCount: (w.apps || []).length,
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
    closeToggle.checked = w.closeExisting !== false
    appEditModel.clear()
    var apps = w.apps || []
    for (var i = 0; i < apps.length; ++i) {
      var a = apps[i] || ({})
      appEditModel.append({
        appName: String(a.name || "Application"),
        workspace: String(a.workspace || 1),
        command: String(a.command || ""),
        match: String(a.match || "")
      })
    }
    root.mode = "edit"
    root.statusMessage = ""
  }

  function createWorkflow() {
    root.pendingAction = "open-new"
    root.runAction(["add-workflow", "New Workflow", "W"], "Creating workflow…")
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
      if (!String(row.command || "").trim()) {
        root.statusError = true
        root.statusMessage = "Every application needs a launch command."
        return
      }
      apps.push({
        name: String(row.appName || "Application"),
        workspace: ws,
        command: String(row.command || ""),
        match: String(row.match || "")
      })
    }

    var workflow = {
      id: root.selectedWorkflowId,
      name: nameInput.text.trim(),
      icon: iconInput.text.trim() || "W",
      closeExisting: closeToggle.checked,
      startWorkspace: startWs,
      apps: apps
    }
    root.pendingAction = "saved"
    root.runAction(["replace-workflow", root.selectedWorkflowId, JSON.stringify(workflow)], "Saving workflow…")
  }

  function requestLaunch(id, name, closeExisting) {
    root.confirmWorkflowId = id
    root.confirmWorkflowName = name
    if (!closeExisting) {
      root.launchWorkflow(id, name)
      return
    }
    if (countProc.running) return
    countProc.command = [root.backendPath, "count-windows"]
    countProc.running = true
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

  ListModel { id: workflowModel }
  ListModel { id: appEditModel }

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
    onExited: function(exitCode) {
      var count = parseInt(String(countOut.text || "0").trim())
      if (isNaN(count)) count = 0
      root.confirmWindowCount = count
      if (count > 0) root.confirmOpen = true
      else root.launchWorkflow(root.confirmWorkflowId, root.confirmWorkflowName)
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
        return
      }

      var out = String(actionOut.text || "").trim()
      root.statusError = false
      root.statusMessage = out || "Done."

      if (root.pendingAction === "open-new") {
        var result = root.parseJson(out, {})
        if (result.id) {
          root.selectedWorkflowId = String(result.id)
          root.pendingOpenEditorId = String(result.id)
        }
        root.refreshConfig()
      } else if (root.pendingAction === "saved") {
        root.mode = "list"
        root.refreshConfig()
      } else if (root.pendingAction === "deleted") {
        root.mode = "list"
        root.selectedWorkflowId = ""
        root.refreshConfig()
      } else {
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

    contentWidth: panel.fittedContentWidth(Style.space(760))
    contentHeight: panel.fittedContentHeight(root.mode === "edit" ? Style.space(650) : Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
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
            width: parent.width - addWorkflowButton.width - Style.space(8)
            spacing: Style.space(2)
            Text {
              text: "Workflows"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }
            Text {
              text: "Close the current desktop and build a new workspace layout."
              color: root.mutedText
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          Rectangle {
            id: addWorkflowButton
            width: Style.space(112)
            height: Style.space(34)
            radius: Style.space(6)
            color: addWorkflowMouse.containsMouse ? Util.alpha(root.foreground, 0.17) : Util.alpha(root.foreground, 0.08)
            Text { anchors.centerIn: parent; text: "+ Workflow"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true }
            MouseArea { id: addWorkflowMouse; anchors.fill: parent; hoverEnabled: true; onClicked: root.createWorkflow() }
          }
        }

        Rectangle { width: parent.width; height: 1; color: Util.alpha(root.foreground, 0.12) }

        ListView {
          id: workflowList
          width: parent.width
          height: Style.space(410)
          clip: true
          spacing: Style.space(8)
          model: workflowModel

          delegate: Rectangle {
            id: workflowRow
            required property int index
            required property string workflowId
            required property string name
            required property string icon
            required property bool closeExisting
            required property int startWorkspace
            required property int appCount
            required property bool isActive
            required property bool isStartup

            width: workflowList.width
            height: Style.space(82)
            radius: Style.space(8)
            color: rowMouse.containsMouse ? Util.alpha(root.foreground, 0.075) : Util.alpha(root.foreground, 0.035)
            border.width: isActive ? 1 : 0
            border.color: isActive ? Util.alpha(root.foreground, 0.32) : "transparent"

            MouseArea { id: rowMouse; anchors.fill: parent; hoverEnabled: true }

            Row {
              anchors.fill: parent
              anchors.margins: Style.space(10)
              spacing: Style.space(10)

              Rectangle {
                width: Style.space(48); height: width; radius: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                color: Util.alpha(root.foreground, 0.08)
                Text {
                  anchors.centerIn: parent
                  text: workflowRow.icon
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
              }

              Column {
                width: parent.width - Style.space(48) - launchButton.width - editButton.width - Style.space(40)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(3)
                Row {
                  spacing: Style.space(7)
                  Text { text: workflowRow.name; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
                  Text { visible: workflowRow.isActive; text: "ACTIVE"; color: root.mutedText; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                  Text { visible: workflowRow.isStartup; text: "LOGIN"; color: root.mutedText; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                }
                Text {
                  text: workflowRow.appCount + " apps · starts on workspace " + workflowRow.startWorkspace + (workflowRow.closeExisting ? " · closes current windows" : " · keeps current windows")
                  color: root.mutedText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }

              Rectangle {
                id: editButton
                width: Style.space(62); height: Style.space(34); radius: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                color: editMouse.containsMouse ? Util.alpha(root.foreground, 0.16) : Util.alpha(root.foreground, 0.07)
                Text { anchors.centerIn: parent; text: "Edit"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
                MouseArea { id: editMouse; anchors.fill: parent; hoverEnabled: true; onClicked: root.openEditor(workflowRow.workflowId) }
              }

              Rectangle {
                id: launchButton
                width: Style.space(78); height: Style.space(34); radius: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                color: launchMouse.containsMouse ? Util.alpha(root.foreground, 0.22) : Util.alpha(root.foreground, 0.11)
                Text { anchors.centerIn: parent; text: "Launch"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true }
                MouseArea {
                  id: launchMouse; anchors.fill: parent; hoverEnabled: true
                  onClicked: root.requestLaunch(workflowRow.workflowId, workflowRow.name, workflowRow.closeExisting)
                }
              }
            }
          }
        }

        Rectangle { width: parent.width; height: 1; color: Util.alpha(root.foreground, 0.12) }
        Text {
          width: parent.width
          text: root.statusMessage || "Tip: window class matchers make Chromium/Electron apps land reliably on the requested workspace."
          color: root.statusError ? root.bar.urgent : root.mutedText
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
      }

      Column {
        id: editPage
        anchors.fill: parent
        spacing: Style.space(9)
        visible: root.mode === "edit"

        Row {
          width: parent.width
          spacing: Style.space(8)
          Rectangle {
            width: Style.space(70); height: Style.space(34); radius: Style.space(6)
            color: backMouse.containsMouse ? Util.alpha(root.foreground, 0.16) : Util.alpha(root.foreground, 0.07)
            Text { anchors.centerIn: parent; text: "← Back"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
            MouseArea { id: backMouse; anchors.fill: parent; hoverEnabled: true; onClicked: { root.mode = "list"; root.refreshConfig() } }
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Edit Workflow"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(8)
          Column {
            width: Style.space(80); spacing: Style.space(3)
            Text { text: "Icon"; color: root.mutedText; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            Rectangle {
              width: parent.width; height: Style.space(34); radius: Style.space(5); color: Util.alpha(root.foreground, 0.07)
              TextInput { id: iconInput; anchors.fill: parent; anchors.margins: Style.space(7); color: root.foreground; font.family: root.fontFamily; verticalAlignment: TextInput.AlignVCenter; selectByMouse: true }
            }
          }
          Column {
            width: parent.width - Style.space(80) - Style.space(120) - Style.space(16); spacing: Style.space(3)
            Text { text: "Name"; color: root.mutedText; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            Rectangle {
              width: parent.width; height: Style.space(34); radius: Style.space(5); color: Util.alpha(root.foreground, 0.07)
              TextInput { id: nameInput; anchors.fill: parent; anchors.margins: Style.space(7); color: root.foreground; font.family: root.fontFamily; verticalAlignment: TextInput.AlignVCenter; selectByMouse: true }
            }
          }
          Column {
            width: Style.space(120); spacing: Style.space(3)
            Text { text: "Start workspace"; color: root.mutedText; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            Rectangle {
              width: parent.width; height: Style.space(34); radius: Style.space(5); color: Util.alpha(root.foreground, 0.07)
              TextInput { id: workspaceInput; anchors.fill: parent; anchors.margins: Style.space(7); color: root.foreground; font.family: root.fontFamily; verticalAlignment: TextInput.AlignVCenter; horizontalAlignment: TextInput.AlignHCenter; inputMethodHints: Qt.ImhDigitsOnly; selectByMouse: true }
            }
          }
        }

        Row {
          spacing: Style.space(8)
          Rectangle {
            id: closeToggle
            property bool checked: true
            width: Style.space(42); height: Style.space(24); radius: height / 2
            color: checked ? Util.alpha(root.foreground, 0.30) : Util.alpha(root.foreground, 0.09)
            Rectangle { width: Style.space(16); height: width; radius: width/2; anchors.verticalCenter: parent.verticalCenter; x: closeToggle.checked ? parent.width - width - Style.space(4) : Style.space(4); color: root.foreground }
            MouseArea { anchors.fill: parent; onClicked: closeToggle.checked = !closeToggle.checked }
          }
          Text { anchors.verticalCenter: closeToggle.verticalCenter; text: "Close current application windows before launching"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
        }

        Row {
          width: parent.width
          Text { width: parent.width - addAppButton.width; text: "Applications"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
          Rectangle {
            id: addAppButton
            width: Style.space(90); height: Style.space(30); radius: Style.space(5)
            color: addAppMouse.containsMouse ? Util.alpha(root.foreground, 0.16) : Util.alpha(root.foreground, 0.07)
            Text { anchors.centerIn: parent; text: "+ App"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
            MouseArea { id: addAppMouse; anchors.fill: parent; hoverEnabled: true; onClicked: appEditModel.append({ appName: "Application", workspace: "1", command: "", match: "" }) }
          }
        }

        ListView {
          id: appList
          width: parent.width
          height: Style.space(350)
          clip: true
          spacing: Style.space(7)
          model: appEditModel

          delegate: Rectangle {
            id: appRow
            required property int index
            required property string appName
            required property string workspace
            required property string command
            required property string match
            width: appList.width
            height: Style.space(105)
            radius: Style.space(7)
            color: Util.alpha(root.foreground, 0.04)

            Column {
              anchors.fill: parent
              anchors.margins: Style.space(7)
              spacing: Style.space(5)

              Row {
                width: parent.width; spacing: Style.space(7)
                Rectangle {
                  width: Style.space(46); height: Style.space(31); radius: Style.space(5); color: Util.alpha(root.foreground, 0.07)
                  TextInput {
                    anchors.fill: parent; anchors.margins: Style.space(5); text: appRow.workspace; color: root.foreground; font.family: root.fontFamily; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter; inputMethodHints: Qt.ImhDigitsOnly; selectByMouse: true
                    onTextEdited: appEditModel.setProperty(appRow.index, "workspace", text)
                  }
                }
                Rectangle {
                  width: Style.space(150); height: Style.space(31); radius: Style.space(5); color: Util.alpha(root.foreground, 0.07)
                  TextInput {
                    anchors.fill: parent; anchors.margins: Style.space(5); text: appRow.appName; color: root.foreground; font.family: root.fontFamily; verticalAlignment: TextInput.AlignVCenter; selectByMouse: true; clip: true
                    onTextEdited: appEditModel.setProperty(appRow.index, "appName", text)
                  }
                }
                Rectangle {
                  width: parent.width - Style.space(46) - Style.space(150) - removeAppButton.width - Style.space(28); height: Style.space(31); radius: Style.space(5); color: Util.alpha(root.foreground, 0.07)
                  TextInput {
                    anchors.fill: parent; anchors.margins: Style.space(5); text: appRow.command; color: root.foreground; font.family: root.fontFamily; verticalAlignment: TextInput.AlignVCenter; selectByMouse: true; clip: true
                    onTextEdited: appEditModel.setProperty(appRow.index, "command", text)
                  }
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
                Text { width: Style.space(196); text: "WS   Name"; color: root.mutedText; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                Text { text: "Launch command"; color: root.mutedText; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
              }

              Row {
                width: parent.width; spacing: Style.space(7)
                Text { width: Style.space(88); anchors.verticalCenter: parent.verticalCenter; text: "Window match"; color: root.mutedText; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                Rectangle {
                  width: parent.width - Style.space(95); height: Style.space(27); radius: Style.space(5); color: Util.alpha(root.foreground, 0.06)
                  TextInput {
                    anchors.fill: parent; anchors.margins: Style.space(5); text: appRow.match; color: root.foreground; font.family: root.fontFamily; verticalAlignment: TextInput.AlignVCenter; selectByMouse: true; clip: true
                    onTextEdited: appEditModel.setProperty(appRow.index, "match", text)
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
            Text {
              anchors.centerIn: parent
              text: String(root.configData.startupWorkflow || "") === root.selectedWorkflowId ? "Clear login" : "Run at login"
              color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
            }
            MouseArea {
              id: startupMouse; anchors.fill: parent; hoverEnabled: true
              onClicked: root.setStartup(String(root.configData.startupWorkflow || "") === root.selectedWorkflowId ? "" : root.selectedWorkflowId)
            }
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
          text: root.statusMessage || "Window match is a case-insensitive regex for the app's Hyprland class/title, e.g. md\\.obsidian\\.Obsidian or spotify."
          color: root.statusError ? root.bar.urgent : root.mutedText
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
      }

      Rectangle {
        anchors.fill: parent
        z: 100
        visible: root.confirmOpen
        color: Util.alpha(root.background, 0.96)

        MouseArea { anchors.fill: parent }

        Column {
          width: Math.min(parent.width - Style.space(60), Style.space(460))
          anchors.centerIn: parent
          spacing: Style.space(12)

          Text {
            width: parent.width
            text: "Switch to " + root.confirmWorkflowName + "?"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            horizontalAlignment: Text.AlignHCenter
          }
          Text {
            width: parent.width
            text: "This will send a normal close request to " + root.confirmWindowCount + " current window" + (root.confirmWindowCount === 1 ? "" : "s") + ". Apps with unsaved work may ask you to save before closing. It will not force-kill them."
            color: root.mutedText
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }
          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(10)
            Rectangle {
              width: Style.space(90); height: Style.space(36); radius: Style.space(6); color: cancelMouse.containsMouse ? Util.alpha(root.foreground, 0.16) : Util.alpha(root.foreground, 0.07)
              Text { anchors.centerIn: parent; text: "Cancel"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
              MouseArea { id: cancelMouse; anchors.fill: parent; hoverEnabled: true; onClicked: root.confirmOpen = false }
            }
            Rectangle {
              width: Style.space(122); height: Style.space(36); radius: Style.space(6); color: switchMouse.containsMouse ? Util.alpha(root.foreground, 0.24) : Util.alpha(root.foreground, 0.12)
              Text { anchors.centerIn: parent; text: "Close & Launch"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true }
              MouseArea { id: switchMouse; anchors.fill: parent; hoverEnabled: true; onClicked: root.launchWorkflow(root.confirmWorkflowId, root.confirmWorkflowName) }
            }
          }
        }
      }
    }
  }
}
