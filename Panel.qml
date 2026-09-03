import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// EarTrumpet-style per-application audio router for Omarchy.
// Lists every app that is currently outputting audio and lets you route
// each one to a different output device, plus manage the default output.
Panel {
  id: root
  moduleName: "io.github.raeganwyble.per-app-audio"
  ipcTarget: "io.github.raeganwyble.per-app-audio"

  property var displayStreams: []
  property var displaySinks: []
  property string defaultSinkName: ""

  property bool cursorActive: false
  property string focusSection: "devices"   // "devices" | "streams" | "header"
  property int selectedIndex: -1
  property var activePopoutDevice: null
  property bool hasStreams: displayStreams.length > 0

  readonly property color hoverFill: bar
    ? Style.hoverFillFor(bar.foreground, Color.accent)
    : Style.hoverFillFor(Color.foreground, Color.accent)
  readonly property color selectedFill: bar
    ? Style.selectedFillFor(bar.foreground, Color.accent)
    : Style.selectedFillFor(Color.foreground, Color.accent)

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---- Data refresh ------------------------------------------------------
  Timer {
    id: refreshTimer
    interval: 2000
    repeat: true
    running: root.opened
    onTriggered: root.queryAudio()
  }

  function queryAudio() {
    if (!audioQueryProc.running) audioQueryProc.running = true
  }

  readonly property string home: Quickshell.env("HOME")
  readonly property string audioQueryPath: home
    + "/.config/omarchy/plugins/io.github.raeganwyble.per-app-audio/query-audio.sh"

  Process {
    id: audioQueryProc
    command: [audioQueryPath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseAudioData(text)
        root.displaySinks = parsed.sinks
        root.displayStreams = parsed.streams
        root.defaultSinkName = parsed.defaultSink
      }
    }
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) {
        root.displayStreams = []
        root.displaySinks = []
        root.defaultSinkName = ""
      }
    }
  }

  // ---- User actions ------------------------------------------------------

  function setDefaultSink(sink) {
    if (!sink) return
    bar.run("wpctl set-default '" + sink.index + "' 2>/dev/null; "
      + "pactl set-default-sink '" + sink.name + "' 2>/dev/null")
    resyncTimer.restart()
  }

  function moveStream(stream, sinkName) {
    if (!stream || !sinkName) return
    bar.run("pactl move-sink-input " + stream.index + " \"" + sinkName + "\"")
    resyncTimer.restart()
  }

  function setStreamVolume(stream, volume) {
    if (!stream) return
    var pct = Math.round(Math.max(0, Math.min(1.5, volume)) * 100)
    bar.run("pactl set-sink-input-volume " + stream.index + " " + pct + "%")
  }

  function toggleStreamMute(stream) {
    if (!stream) return
    bar.run("pactl set-sink-input-mute " + stream.index + " toggle")
    resyncTimer.restart()
  }

  // Re-query shortly after a change so the UI reflects the new routing.
  Timer {
    id: resyncTimer
    interval: 300
    onTriggered: root.queryAudio()
  }

  // ---- Keyboard cursor model --------------------------------------------

  function visibleSections() {
    var s = []
    if (displaySinks.length > 0) s.push("devices")
    if (displayStreams.length > 0) s.push("streams")
    return s
  }

  function deviceCount() { return displaySinks.length }
  function streamCount() { return displayStreams.length }

  function moveCursor(delta) {
    var sections = visibleSections()
    if (sections.length === 0) return
    if (focusSection === "header") {
      if (delta > 0) { focusSection = sections[0]; selectedIndex = 0 }
      return
    }
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) { focusSection = sections[0]; selectedIndex = 0; return }

    var idx = selectedIndex
    var max = focusSection === "devices" ? deviceCount() - 1 : streamCount() - 1
    if (delta > 0) {
      if (idx < max) { selectedIndex = idx + 1; return }
      if (sIdx < sections.length - 1) {
        focusSection = sections[sIdx + 1]
        selectedIndex = 0
      }
    } else {
      if (idx > 0) { selectedIndex = idx - 1; return }
      if (sIdx > 0) {
        focusSection = sections[sIdx - 1]
        selectedIndex = (sections[sIdx - 1] === "devices" ? deviceCount() : streamCount()) - 1
      } else {
        focusSection = "header"
        selectedIndex = -1
      }
    }
  }

  function activateCursor() {
    if (focusSection === "devices" && selectedIndex >= 0 && selectedIndex < displaySinks.length) {
      setDefaultSink(displaySinks[selectedIndex])
    } else if (focusSection === "streams" && selectedIndex >= 0 && selectedIndex < displayStreams.length) {
      toggleStreamMute(displayStreams[selectedIndex])
    }
  }

  function adjustVolume(delta) {
    if (focusSection === "streams" && selectedIndex >= 0 && selectedIndex < displayStreams.length) {
      var s = displayStreams[selectedIndex]
      var v = (Number(s.volume) || 0) + delta
      s.volume = Math.max(0, Math.min(1.5, v))
      setStreamVolume(s, v)
    }
  }

  function setDeviceCursor() {
    cursorActive = true
    focusSection = "devices"
    selectedIndex = -1
  }

  function setStreamCursor(idx) {
    cursorActive = true
    focusSection = "streams"
    selectedIndex = idx
  }

  function clampCursor() {
    var n = focusSection === "devices" ? deviceCount() : streamCount()
    if (n > 0 && selectedIndex >= n) selectedIndex = n - 1
    if (n === 0 && focusSection !== "header") { focusSection = "header"; selectedIndex = -1 }
  }

  function resetScroll() {
    if (scrollArea) {
      var flick = scrollArea.contentItem
      if (flick && flick.contentY !== undefined) flick.contentY = 0
    }
  }

  function ensureCursorVisible(item) {
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var top = item.mapToItem(flick.contentItem, 0, 0).y
    if (top < flick.contentY) flick.contentY = top
    else if (top + item.height > flick.contentY + scrollArea.height)
      flick.contentY = top + item.height - scrollArea.height
  }

  onOpenedChanged: {
    if (opened) {
      queryAudio()
      focusSection = "devices"
      selectedIndex = -1
      cursorActive = false
      Qt.callLater(resetScroll)
    } else {
      displayStreams = []
      displaySinks = []
    }
  }

  // ---- The bar trigger icon ---------------------------------------------
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf085"
    tooltipText: "Per-App Audio"

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.LeftButton) root.toggle()
    }
  }

  // ---- The popup panel ---------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.adjustVolume(dx * 0.05)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "m" || t === "M") {
          if (!root.cursorActive) return
          if (root.focusSection === "streams" && root.selectedIndex >= 0
              && root.selectedIndex < root.displayStreams.length)
            root.toggleStreamMute(root.displayStreams[root.selectedIndex])
        }
      }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: "\uf085"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Per-App Audio"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                textFormat: Text.PlainText
                text: root.hasStreams
                  ? root.displayStreams.length + " app" + (root.displayStreams.length === 1 ? "" : "s") + " playing"
                  : "No apps outputting audio"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          // ---------- Output devices ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(devHeader.implicitHeight, devHint.implicitHeight)

              PanelSectionHeader {
                id: devHeader
                text: "OUTPUT DEVICES"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: devHint
                textFormat: Text.PlainText
                text: "click to set default"
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
                anchors.rightMargin: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Repeater {
              model: root.displaySinks

              DeviceRow {
                required property var modelData
                required property int index
                width: panelColumn.width
                device: modelData
                rowIndex: index
              }
            }
          }

          // ---------- Active streams ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(streamHeader.implicitHeight, streamHint.implicitHeight)

              PanelSectionHeader {
                id: streamHeader
                text: "ACTIVE APPS"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: streamHint
                textFormat: Text.PlainText
                text: "m: mute"
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
                anchors.rightMargin: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Repeater {
              model: root.displayStreams

              StreamRow {
                required property var modelData
                required property int index
                width: panelColumn.width
                stream: modelData
                rowIndex: index
              }
            }

            Item {
              visible: !root.hasStreams
              width: parent.width
              implicitHeight: Style.space(40)
              anchors.topMargin: Style.space(4)

              Text {
                textFormat: Text.PlainText
                text: "󰂯  Nothing playing"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                anchors.centerIn: parent
              }
            }
          }
        }
      }
    }
  }

  // ---- Device row: select a default output --------------------------------
  component DeviceRow: CursorSurface {
    id: deviceRow
    required property var device
    required property int rowIndex

    readonly property bool isActive: device && device.name === root.defaultSinkName
    hasCursor: root.cursorActive && root.focusSection === "devices" && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(deviceRow)
    current: isActive
    foreground: root.bar.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: deviceInner.implicitHeight + Style.spacing.xl

    Row {
      id: deviceInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: Model.defaultGlyph(device, root.defaultSinkName)
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.title
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: Model.sinkLabel(device)
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        font.bold: deviceRow.isActive
        elide: Text.ElideRight
        width: parent.width - Style.space(22) - Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.focusSection = "devices"
        root.selectedIndex = deviceRow.rowIndex
      }
      onClicked: root.setDefaultSink(device)
    }
  }

  // ---- Stream row: an app + its volume + device router --------------------
  component StreamRow: CursorSurface {
    id: streamRow
    required property var stream
    required property int rowIndex

    readonly property real streamVolume: stream ? (Number(stream.volume) || 0) : 0
    readonly property bool streamMuted: stream ? !!stream.muted : false
    readonly property string currentSink: stream ? (stream.sinkName || "") : ""

    hasCursor: root.cursorActive && root.focusSection === "streams" && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(streamRow)
    foreground: root.bar.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: streamColumn.implicitHeight + Style.spacing.xl

    Column {
      id: streamColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(6)

      // App label row
      Row {
        width: parent.width
        spacing: Style.space(8)

        Text {
          id: streamMuteIcon
          textFormat: Text.PlainText
          text: Model.muteGlyph(stream)
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.title
          width: Style.space(22)
          horizontalAlignment: Text.AlignHCenter
          anchors.verticalCenter: parent.verticalCenter
          opacity: streamRow.streamMuted ? 0.5 : 1.0

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.toggleStreamMute(streamRow.stream)
          }
        }

        Text {
          textFormat: Text.PlainText
          text: Model.streamLabel(stream)
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
          width: parent.width - streamMuteIcon.width - streamPct.width - Style.space(16)
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          id: streamPct
          textFormat: Text.PlainText
          text: Model.volumePercent(stream) + "%"
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          width: Style.space(36)
          horizontalAlignment: Text.AlignRight
          anchors.verticalCenter: parent.verticalCenter
          opacity: streamRow.streamMuted ? 0.5 : 1.0
        }
      }

      // Volume slider
      PanelSlider {
        bar: root.bar
        width: parent.width
        minimum: 0
        maximum: 1.5
        step: 0.05
        value: streamRow.streamVolume
        opacity: streamRow.streamMuted ? 0.5 : 1.0

        onMoved: function(v) { root.setStreamVolume(streamRow.stream, v) }
        onRightClicked: root.toggleStreamMute(streamRow.stream)
      }

      // Device router
      Dropdown {
        width: parent.width
        label: "route to"
        value: streamRow.currentSink
        options: Model.dropdownOptions(root.displaySinks, streamRow.currentSink)
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily

        onChanged: function(value) {
          root.moveStream(streamRow.stream, value)
        }
      }
    }
  }
}
