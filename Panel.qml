import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bambu Lab printer status. The bar shows progress + remaining time of the
// active print; the popup details temps, layer and connection health. Status
// arrives over LAN MQTT via scripts/bambu-bridge.py, one long-running process
// per widget instance, speaking the same dialect as Bambu Studio. The access
// code is read from Bambu Studio's own config so there is nothing to type.
Panel {
  id: root
  moduleName: "io.github.zhruoshui.bambu-printer"
  // Multiple instances of this widget can live in the bar at once (one per
  // printer), so a fixed IPC target would collide. The widget is opened by
  // clicking it; shell summon routing goes through BarWidget.qml instead.
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- instance settings (from this widget's bar.layout entry) -------------

  readonly property string printerSn: String(setting("printerSn", "")).trim()
  readonly property string printerIp: String(setting("printerIp", "")).trim()
  readonly property string printerName: String(setting("printerName", "")).trim()
  readonly property string manualCode: String(setting("accessCode", "")).trim()
  readonly property bool showWhenIdle: setting("showWhenIdle", false) === true

  readonly property bool configured: printerSn !== "" && printerIp !== ""

  // ---- access code, preferred from Bambu Studio's config ---------------------

  property var studioConf: ({})

  // ~/.config/BambuStudio/BambuStudio.conf is a JSON file whose access_code /
  // user_access_code maps hold the per-printer LAN codes Bambu Studio uses.
  // Watching it means pairing a new printer in Bambu Studio configures this
  // widget too, on the next save.
  property var studioConfFile: FileView {
    path: Quickshell.env("HOME") + "/.config/BambuStudio/BambuStudio.conf"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.studioConf = JSON.parse(text()) }
      catch (e) { root.studioConf = ({}) }
    }
    onLoadFailed: root.studioConf = ({})
  }

  readonly property string studioCode: {
    var conf = root.studioConf
    if (!conf) return ""
    if (conf.user_access_code && conf.user_access_code[root.printerSn])
      return String(conf.user_access_code[root.printerSn])
    if (conf.access_code && conf.access_code[root.printerSn])
      return String(conf.access_code[root.printerSn])
    return ""
  }

  readonly property string accessCode: manualCode !== "" ? manualCode : studioCode
  readonly property string codeSource: manualCode !== "" ? "manual"
    : studioCode !== "" ? "Bambu Studio" : ""

  // ---- bridge process -----------------------------------------------------------

  // "unconfigured" | "no-code" | "connecting" | "connected" | "auth-error" | "offline"
  property string linkState: "unconfigured"
  property string linkError: ""

  readonly property string bridgePath: String(Qt.resolvedUrl("scripts/bambu-bridge.py")).replace(/^file:\/\//, "")

  // The bridge owns reconnecting internally, so the widget only restarts it
  // when its identity (host/sn/code) changes or it dies outright. The
  // generation counter tells the exited handler an exit was requested here
  // (a settings swap) rather than a crash.
  property bool bridgeWanted: false
  property int bridgeGen: 0
  property int bridgeRunningGen: -1

  function restartBridge() {
    bridgeGen++
    bridgeProc.running = false
    bridgeWanted = configured && accessCode !== ""
    linkError = ""
    if (!configured) linkState = "unconfigured"
    else if (accessCode === "") linkState = "no-code"
    else {
      linkState = "connecting"
      bridgeProc.command = ["/usr/bin/python3", bridgePath,
        "--host", printerIp, "--sn", printerSn, "--code", accessCode]
      var gen = bridgeGen
      Qt.callLater(function() {
        if (gen !== root.bridgeGen) return  // superseded by a newer restart
        if (!root.bridgeWanted) return
        // Re-check the live values, not the snapshot the closure captured:
        // a settings swap between the command being built and this running
        // must not launch a bridge against a host that just went away.
        if (root.printerSn === "" || root.printerIp === "" || root.accessCode === "")
          return
        root.bridgeRunningGen = gen
        bridgeProc.running = true
      })
    }
  }

  onPrinterSnChanged: restartBridge()
  onPrinterIpChanged: restartBridge()
  onAccessCodeChanged: if (studioConfFile.loaded) restartBridge()

  // Fresh instances are born with their settings already in place, so no
  // changed-handler fires — the first bridge start has to happen here. When
  // Bambu Studio's config (and with it the access code) loads a moment later,
  // onAccessCodeChanged picks the bridge up.
  Component.onCompleted: restartBridge()

  Process {
    id: bridgeProc
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(data) { root.handleBridgeLine(data) }
    }
    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function(data) { console.warn("bambu-printer:", String(data)) }
    }
    onExited: function(exitCode) {
      if (!root.bridgeWanted) return
      if (root.bridgeGen !== root.bridgeRunningGen) return  // stopped on purpose
      root.linkState = "offline"
      root.linkError = "bridge exited (" + exitCode + ")"
      crashTimer.restart()
    }
  }

  Timer {
    id: crashTimer
    interval: 5000
    // The bridge owns reconnects internally; this timer is the outer safety
    // net for it dying outright. Rebuild the command from live config rather
    // than reusing the possibly-stale one the process last ran.
    onTriggered: if (root.bridgeWanted && root.printerIp !== "" && root.accessCode !== "") {
      root.bridgeRunningGen = root.bridgeGen
      bridgeProc.command = ["/usr/bin/python3", root.bridgePath,
        "--host", root.printerIp, "--sn", root.printerSn, "--code", root.accessCode]
      bridgeProc.running = true
    }
  }

  // ---- printer state --------------------------------------------------------------

  // Named printStatus: "print" is a QML global function and cannot be a
  // property name.
  property var printStatus: null
  property var info: null
  readonly property string printerModel: (info && info.printer && info.printer.model) ? String(info.printer.model) : ""

  function handleBridgeLine(line) {
    var raw = String(line).trim()
    if (!raw) return
    var ev
    try { ev = JSON.parse(raw) } catch (e) { return }
    if (ev.event === "connected") {
      linkState = "connected"
      linkError = ""
    } else if (ev.event === "disconnected") {
      // The bridge keeps retrying; keep the last print block visible meanwhile
      // — a printer that rebooted mid-job still has a last known state worth
      // showing.
      linkState = "offline"
      linkError = ev.reason || ""
    } else if (ev.event === "auth_error") {
      linkState = "auth-error"
      linkError = ev.reason || ""
    } else if (ev.event === "message") {
      if (ev.payload && ev.payload.print) printStatus = ev.payload.print
      if (ev.payload && ev.payload.info) info = ev.payload.info
    }
  }

  readonly property string gcodeState: (printStatus && printStatus.gcode_state) ? String(printStatus.gcode_state) : ""

  readonly property bool printing: gcodeState === "RUNNING" || gcodeState === "PREPARE"
  readonly property bool paused: gcodeState === "PAUSE"
  readonly property bool finished: gcodeState === "FINISH"
  readonly property bool failed: gcodeState === "FAILED"

  readonly property int percent: printStatus ? Math.round(Number(printStatus.mc_percent) || 0) : 0
  readonly property int remainingMin: printStatus ? Math.round(Number(printStatus.mc_remaining_time) || 0) : 0
  readonly property int layerNum: printStatus ? (Number(printStatus.layer_num) || 0) : 0
  readonly property int layerTotal: printStatus ? (Number(printStatus.total_layer_num) || 0) : 0
  readonly property real nozzleTemp: printStatus ? (Number(printStatus.nozzle_temper) || 0) : 0
  readonly property real nozzleTarget: printStatus ? (Number(printStatus.nozzle_target_temper) || 0) : 0
  readonly property real bedTemp: printStatus ? (Number(printStatus.bed_temper) || 0) : 0
  readonly property real bedTarget: printStatus ? (Number(printStatus.bed_target_temper) || 0) : 0
  readonly property int fanPercent: printStatus ? Math.round(Number(printStatus.cooling_fan_speed) || 0) : 0
  readonly property string wifiSignal: (info && info.wifi_signal) ? String(info.wifi_signal) : ""

  readonly property string taskName: {
    if (!printStatus) return ""
    if (printStatus.subtask_name) return String(printStatus.subtask_name)
    if (printStatus.gcode_file) return String(printStatus.gcode_file).split("/").pop().replace(/\.gcode(\.\d+)?$/, "")
    return ""
  }

  readonly property string speedName: {
    var lvl = printStatus ? (Number(printStatus.spd_lvl) || 2) : 2
    return ["", "Silent", "Standard", "Sport", "Ludicrous"][Math.min(lvl, 4)] || "Standard"
  }

  function formatRemaining(min) {
    if (min <= 0) return "—"
    if (min < 60) return min + "m"
    return Math.floor(min / 60) + "h" + String(min % 60).padStart(2, "0") + "m"
  }

  function formatTemp(current, target) {
    var s = Math.round(current) + "°C"
    if (target > 0) s += " → " + Math.round(target)
    return s
  }

  readonly property color fg: root.bar ? root.bar.barForeground : Color.foreground
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  readonly property color statusColor:
    failed ? "#b25b5b" :
    finished || printing ? "#79a86b" :
    paused ? "#c9a15f" :
    Color.muted

  // ---- bar presence -----------------------------------------------------------------

  // Weather's contract: the entry widget hides itself when the panel's label
  // is empty. Everything the user needs to notice (printing, paused, done,
  // failed, misconfigured, rejected code) produces a label; idle and offline
  // stay quiet unless showWhenIdle is set.
  //
  // nf-md-printer glyph, matching the icon language of the built-in bar.
  readonly property string glyph: "󰐪"

  property string label: {
    if (!configured || linkState === "no-code" || linkState === "auth-error") return glyph
    if (linkState === "offline" || linkState === "connecting") return showWhenIdle ? glyph : ""
    if (printing || paused) return percent + "% · " + formatRemaining(remainingMin)
    if (finished) return "✓ done"
    if (failed) return "✕ failed"
    if (gcodeState !== "" && gcodeState !== "IDLE") return gcodeState.toLowerCase()
    return showWhenIdle ? glyph : ""
  }

  property string tooltip: {
    if (!configured) return "Bambu printer — set printerSn / printerIp (see panel)"
    if (linkState === "no-code") return "Bambu printer — no access code for " + printerSn
    if (linkState === "auth-error") return "Bambu printer — access code rejected"
    if (linkState === "offline") return "Bambu printer — unreachable at " + printerIp
    var name = printerName !== "" ? printerName : printerModel
    if (taskName !== "" && (printing || paused)) return (name || "Bambu") + " — " + taskName + " · " + percent + "%"
    return name !== "" ? name : "Bambu printer"
  }

  function toggle() {
    if (root.opened) root.controller.hide()
    else root.controller.show()
  }

  // ---- details popup ------------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(detailsColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.controller.hide()
      onTabRequested: function(direction) {
        if (root.bar && typeof root.bar.switchPanelFrom === "function")
          root.bar.switchPanelFrom(root.barIdentity, direction)
      }

      Flickable {
        id: detailsScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: detailsColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: detailsColumn
          width: detailsScroll.width
          spacing: Style.space(14)

          // ---- header: identity left, link state right

          Item {
            width: parent.width
            height: Math.max(identityColumn.implicitHeight, linkColumn.implicitHeight)

            Row {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Rectangle {
                width: Style.space(6)
                height: Style.space(6)
                radius: width / 2
                anchors.verticalCenter: parent.verticalCenter
                color: root.statusColor
              }

              Column {
                id: identityColumn
                spacing: Style.space(2)

                Text {
                  text: {
                    var name = root.printerName !== "" ? root.printerName
                      : (root.printerSn !== "" ? "…" + root.printerSn.slice(-4) : "—")
                    return (root.printerModel !== "" ? root.printerModel + " · " : "") + name
                  }
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }

                Text {
                  visible: root.linkState !== "connected"
                  text: root.linkState === "unconfigured" ? "not configured"
                    : root.linkState === "no-code" ? "no access code found"
                    : root.linkState === "auth-error" ? "access code rejected"
                    : root.linkState === "offline" ? "unreachable"
                    : "connecting…"
                  color: root.linkState === "auth-error" ? "#b25b5b" : Qt.darker(root.fg, 1.5)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }

            Column {
              id: linkColumn
              anchors.right: parent.right
              anchors.rightMargin: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                anchors.right: parent.right
                text: root.linkState === "connected" ? "CONNECTED" : "STATUS"
                color: Qt.darker(root.fg, 1.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }

              Text {
                anchors.right: parent.right
                text: root.linkState === "connected" ? root.printerIp
                  : (root.gcodeState !== "" ? root.gcodeState.toLowerCase() : "—")
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }

          // ---- hero: big percent + remaining, state on the right

          Item {
            width: parent.width
            height: Math.max(heroPercent.implicitHeight, heroState.implicitHeight)
            visible: root.printStatus !== null

            Row {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(4)
              spacing: Style.space(16)

              Text {
                id: heroPercent
                text: root.percent + "%"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                font.bold: true
              }

              Column {
                anchors.verticalCenter: heroPercent.verticalCenter
                spacing: Style.space(2)

                Text {
                  text: "REMAINING"
                  color: Qt.darker(root.fg, 1.5)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }
                Text {
                  text: root.formatRemaining(root.remainingMin)
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                }
              }
            }

            Column {
              id: heroState
              anchors.right: parent.right
              anchors.rightMargin: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                anchors.right: parent.right
                text: "STATE"
                color: Qt.darker(root.fg, 1.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }
              Text {
                anchors.right: parent.right
                text: root.gcodeState === "" ? "—" : root.gcodeState.toLowerCase()
                color: root.statusColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
              }
            }
          }

          // ---- progress bar + task name

          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.printStatus !== null

            Rectangle {
              x: Style.space(4)
              width: parent.width - Style.space(8)
              height: Style.space(6)
              radius: height / 2
              color: root.fg
              opacity: 0.15

              Rectangle {
                width: Math.min(parent.width, parent.width * root.percent / 100)
                height: parent.height
                radius: parent.radius
                color: root.statusColor
              }
            }

            Text {
              x: Style.space(4)
              width: parent.width - Style.space(8)
              visible: root.taskName !== ""
              text: root.taskName
              elide: Text.ElideMiddle
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          // ---- stats grid

          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.printStatus !== null

            Row {
              x: Style.space(4)
              width: parent.width - Style.space(8)
              spacing: Style.space(12)

              BambuStat { title: "LAYER"; value: root.layerTotal > 0 ? root.layerNum + " / " + root.layerTotal : "—"; width: (parent.width - Style.space(24)) / 3 }
              BambuStat { title: "NOZZLE"; value: root.formatTemp(root.nozzleTemp, root.nozzleTarget); width: (parent.width - Style.space(24)) / 3 }
              BambuStat { title: "BED"; value: root.formatTemp(root.bedTemp, root.bedTarget); width: (parent.width - Style.space(24)) / 3 }
            }

            Row {
              x: Style.space(4)
              width: parent.width - Style.space(8)
              spacing: Style.space(12)

              BambuStat { title: "SPEED"; value: root.speedName; width: (parent.width - Style.space(24)) / 3 }
              BambuStat { title: "PART FAN"; value: root.fanPercent > 0 ? root.fanPercent + "%" : "—"; width: (parent.width - Style.space(24)) / 3 }
              BambuStat { title: "WIFI"; value: root.wifiSignal !== "" ? root.wifiSignal : "—"; width: (parent.width - Style.space(24)) / 3 }
            }
          }

          PanelSeparator {
            visible: root.printStatus !== null
          }

          // ---- configuration footer

          Column {
            width: parent.width
            spacing: Style.space(6)

            Text {
              x: Style.space(4)
              text: "CONFIGURATION"
              color: Qt.darker(root.fg, 1.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }

            Text {
              x: Style.space(4)
              width: parent.width - Style.space(8)
              text: "SN  " + (root.printerSn !== "" ? root.printerSn : "—")
                    + "\nIP  " + (root.printerIp !== "" ? root.printerIp : "—")
                    + "\nCode  " + (root.codeSource !== "" ? root.codeSource : "not found")
              color: root.fg
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              x: Style.space(4)
              width: parent.width - Style.space(8)
              wrapMode: Text.WordWrap
              visible: !root.configured || root.linkState === "no-code" || root.linkState === "auth-error"
              text: !root.configured
                ? "Set printerSn and printerIp on this widget's entry in\n~/.config/omarchy/shell.json (bar.layout):\n{ \"id\": \"io.github.zhruoshui.bambu-printer\",\n  \"printerSn\": \"…\", \"printerIp\": \"192.168.x.x\" }\nThe access code is read from Bambu Studio automatically."
                : root.linkState === "no-code"
                  ? "No access code for this SN in Bambu Studio's config. Pair the printer in Bambu Studio once, or set accessCode on the widget entry."
                  : "The printer rejected the access code. Re-pair the printer in Bambu Studio (it rotates the code), or set accessCode manually."
              color: Qt.darker(root.fg, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }
      }
    }
  }

  // One stat cell: small caps caption over a value, a third of a grid row.
  component BambuStat: Column {
    id: stat
    property string title: ""
    property string value: "—"
    spacing: Style.space(3)

    Text {
      text: stat.title
      color: Qt.darker(root.fg, 1.5)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
    }
    Text {
      width: stat.width
      elide: Text.ElideRight
      text: stat.value
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
  }
}
