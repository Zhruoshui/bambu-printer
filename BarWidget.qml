import QtQuick
import qs.Commons
import qs.Ui

// Bar entry point: owns the visible button (status dot + progress text) and
// loads Panel.qml, which holds the MQTT state and the details popup. The
// entry stands in for that panel as the bar's popout identity, forwarding the
// open/close shape the shell routes summons through — the same contract as
// the built-in weather widget.
BarWidget {
  id: root
  moduleName: "io.github.zhruoshui.bambu-printer"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.controller) panelLoader.item.controller.show()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.controller) panelLoader.item.controller.hide()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item && panelLoader.item.closeForPopoutSwitch) panelLoader.item.closeForPopoutSwitch()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  // Panel.label hides the widget while the printer is idle/offline; anything
  // worth a glance (printing, paused, done, failed, misconfigured) shows.
  readonly property string label: panelLoader.item ? (panelLoader.item.label || "") : ""

  visible: label !== ""
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

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

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: root.label !== ""
    tooltipText: panelLoader.item ? (panelLoader.item.tooltip || "") : ""
    // Custom painted content is not accounted for by WidgetButton's own
    // label-based sizing, so the fixed width mirrors the painted row.
    fixedWidth: button.vertical ? -1 : barRow.implicitWidth + Style.space(12)
    onPressed: function(b) { if (b === Qt.LeftButton) root.togglePanel() }

    Row {
      id: barRow
      anchors.centerIn: parent
      spacing: Style.space(5)
      visible: root.label !== ""

      Rectangle {
        width: Style.space(5)
        height: Style.space(5)
        radius: width / 2
        anchors.verticalCenter: parent.verticalCenter
        color: panelLoader.item ? panelLoader.item.statusColor : Color.muted
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        // Vertical bars have no room for the readout; the dot alone carries
        // the state and the popup carries the detail.
        visible: !button.vertical
        text: root.label
        color: root.bar ? root.bar.barForeground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
      }
    }
  }
}
