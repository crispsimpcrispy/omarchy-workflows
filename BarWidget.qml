import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.crispsimpcrispy.workflows"

  readonly property string backendPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.crispsimpcrispy.workflows/backend.sh"
  property string currentWorkflowName: ""

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open(payloadJson) {
    if (panelLoader.item) panelLoader.item.open(payloadJson || "{}")
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function toggle(payloadJson) {
    if (panelLoader.item) panelLoader.item.toggle(payloadJson || "{}")
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
  }

  function refreshCurrent() {
    if (currentProc.running) return
    currentProc.command = [root.backendPath, "current"]
    currentProc.running = true
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  Process {
    id: currentProc
    stdout: StdioCollector { id: currentOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.currentWorkflowName = String(currentOut.text || "").trim()
    }
  }

  Timer {
    interval: 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshCurrent()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf0ae"
    horizontalMargin: 7.5
    tooltipText: root.currentWorkflowName
      ? "Workflows · Current: " + root.currentWorkflowName
      : "Workflows"

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle("{}")
    }
  }
}
