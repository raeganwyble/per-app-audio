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

  property var displayInputStreams: []
  property var displaySources: []
  property string defaultSourceName: ""

  property string activeTab: "output"   // "output" | "input" | "apps"
  readonly property var tabs: ["output", "input", "apps"]

  property bool cursorActive: false
  property string focusSection: "devices"   // "devices" | "streams" | "header" | "inputdevices" | "instreams" | "apps"
  property int selectedIndex: -1
  property var activePopoutDevice: null
  property bool hasStreams: displayStreams.length > 0
  property bool hasInputStreams: displayInputStreams.length > 0

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
        root.displaySources = parsed.sources
        root.displayInputStreams = parsed.inputStreams
        root.defaultSourceName = parsed.defaultSource
      }
    }
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) {
        root.displayStreams = []
        root.displaySinks = []
        root.defaultSinkName = ""
        root.displayInputStreams = []
        root.displaySources = []
        root.defaultSourceName = ""
      }
    }
  }

  // ---- User actions ------------------------------------------------------

  function setDefaultSink(sink) {
    if (!sink) return
    Util.execArgv(["wpctl", "set-default", String(sink.index)])
    Util.execArgv(["pactl", "set-default-sink", String(sink.name)])
    resyncTimer.restart()
  }

  function moveStream(stream, sinkName) {
    if (!stream || !sinkName) return
    Util.execArgv(["pactl", "move-sink-input", String(stream.index), String(sinkName)])
    resyncTimer.restart()
  }

  function setStreamVolume(stream, volume) {
    if (!stream) return
    var pct = Math.round(Math.max(0, Math.min(1.5, volume)) * 100)
    Util.execArgv(["pactl", "set-sink-input-volume", String(stream.index), pct + "%"])
  }

  function toggleStreamMute(stream) {
    if (!stream) return
    Util.execArgv(["pactl", "set-sink-input-mute", String(stream.index), "toggle"])
    resyncTimer.restart()
  }

  // ---- Input actions -----------------------------------------------------

  function setDefaultSource(source) {
    if (!source) return
    Util.execArgv(["wpctl", "set-default", String(source.index)])
    Util.execArgv(["pactl", "set-default-source", String(source.name)])
    resyncTimer.restart()
  }

  function moveInputStream(stream, sourceName) {
    if (!stream || !sourceName) return
    Util.execArgv(["pactl", "move-source-output", String(stream.index), String(sourceName)])
    resyncTimer.restart()
  }

  function setInputStreamVolume(stream, volume) {
    if (!stream) return
    var pct = Math.round(Math.max(0, Math.min(1.5, volume)) * 100)
    Util.execArgv(["pactl", "set-source-output-volume", String(stream.index), pct + "%"])
  }

  function toggleInputStreamMute(stream) {
    if (!stream) return
    Util.execArgv(["pactl", "set-source-output-mute", String(stream.index), "toggle"])
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
    if (activeTab === "output") {
      if (displaySinks.length > 0) s.push("devices")
    } else if (activeTab === "input") {
      if (displaySources.length > 0) s.push("inputdevices")
      if (displayInputStreams.length > 0) s.push("instreams")
    } else {
      if (displayStreams.length + displayInputStreams.length > 0) s.push("apps")
    }
    return s
  }

  function deviceCount() { return displaySinks.length }
  function streamCount() { return displayStreams.length }
  function sourceDeviceCount() { return displaySources.length }
  function inputStreamCount() { return displayInputStreams.length }
  function appsCount() { return displayStreams.length + displayInputStreams.length }

  function sectionMax(section) {
    if (section === "devices") return deviceCount() - 1
    if (section === "streams") return streamCount() - 1
    if (section === "inputdevices") return sourceDeviceCount() - 1
    if (section === "instreams") return inputStreamCount() - 1
    if (section === "apps") return appsCount() - 1
    return -1
  }

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
    var max = sectionMax(focusSection)
    if (delta > 0) {
      if (idx < max) { selectedIndex = idx + 1; return }
      if (sIdx < sections.length - 1) {
        focusSection = sections[sIdx + 1]
        selectedIndex = 0
      }
    } else {
      if (idx > 0) { selectedIndex = idx - 1; return }
      if (sIdx > 0) {
        var prevSection = sections[sIdx - 1]
        focusSection = prevSection
        selectedIndex = sectionMax(prevSection)
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
    } else if (focusSection === "inputdevices" && selectedIndex >= 0 && selectedIndex < displaySources.length) {
      setDefaultSource(displaySources[selectedIndex])
    } else if (focusSection === "instreams" && selectedIndex >= 0 && selectedIndex < displayInputStreams.length) {
      toggleInputStreamMute(displayInputStreams[selectedIndex])
    } else if (focusSection === "apps") {
      var total = appsCount()
      if (selectedIndex >= 0 && selectedIndex < total) {
        if (selectedIndex < displayStreams.length) toggleStreamMute(displayStreams[selectedIndex])
        else {
          var is = displayInputStreams[selectedIndex - displayStreams.length]
          toggleInputStreamMute(is)
        }
      }
    }
  }

  function adjustVolume(delta) {
    if (focusSection === "streams" && selectedIndex >= 0 && selectedIndex < displayStreams.length) {
      var s = displayStreams[selectedIndex]
      var v = (Number(s.volume) || 0) + delta
      s.volume = Math.max(0, Math.min(1.5, v))
      setStreamVolume(s, v)
    } else if (focusSection === "instreams" && selectedIndex >= 0 && selectedIndex < displayInputStreams.length) {
      var is = displayInputStreams[selectedIndex]
      var iv = (Number(is.volume) || 0) + delta
      is.volume = Math.max(0, Math.min(1.5, iv))
      setInputStreamVolume(is, iv)
    } else if (focusSection === "apps") {
      var total = appsCount()
      if (selectedIndex >= 0 && selectedIndex < total) {
        if (selectedIndex < displayStreams.length) {
          var outStream = displayStreams[selectedIndex]
          var av = (Number(outStream.volume) || 0) + delta
          outStream.volume = Math.max(0, Math.min(1.5, av))
          setStreamVolume(outStream, av)
        } else {
          var ais = displayInputStreams[selectedIndex - displayStreams.length]
          var aiv = (Number(ais.volume) || 0) + delta
          ais.volume = Math.max(0, Math.min(1.5, aiv))
          setInputStreamVolume(ais, aiv)
        }
      }
    }
  }

  function setDeviceCursor() {
    cursorActive = true
    activeTab = "output"
    focusSection = "devices"
    selectedIndex = -1
  }

  function setStreamCursor(idx) {
    cursorActive = true
    activeTab = "output"
    focusSection = "streams"
    selectedIndex = idx
  }

  function setSourceDeviceCursor() {
    cursorActive = true
    activeTab = "input"
    focusSection = "inputdevices"
    selectedIndex = -1
  }

  function setInputCursor(idx) {
    cursorActive = true
    activeTab = "input"
    focusSection = "instreams"
    selectedIndex = idx
  }

  function setAppCursor(idx) {
    cursorActive = true
    activeTab = "apps"
    focusSection = "apps"
    selectedIndex = idx
  }

  function switchTab(tab) {
    if (tab === activeTab) return
    activeTab = tab
    focusSection = "header"
    selectedIndex = -1
    cursorActive = false
  }

  function moveTab(delta) {
    var i = root.tabs.indexOf(root.activeTab)
    var n = root.tabs.length
    if (i < 0) i = 0
    var ni = (i + delta + n) % n
    root.switchTab(root.tabs[ni])
  }

  function clampCursor() {
    var max = sectionMax(focusSection)
    if (focusSection !== "header") {
      if (max < 0) { focusSection = "header"; selectedIndex = -1 }
      else if (selectedIndex > max) selectedIndex = max
    }
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
      activeTab = "output"
      focusSection = "devices"
      selectedIndex = -1
      cursorActive = false
      Qt.callLater(resetScroll)
    } else {
      displayStreams = []
      displaySinks = []
      displayInputStreams = []
      displaySources = []
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
        if (root.focusSection === "header") {
          if (dx < 0) root.moveTab(-1)
          else if (dx > 0) root.moveTab(1)
          return
        }
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
          else if (root.focusSection === "instreams" && root.selectedIndex >= 0
              && root.selectedIndex < root.displayInputStreams.length)
            root.toggleInputStreamMute(root.displayInputStreams[root.selectedIndex])
          else if (root.focusSection === "apps") {
            var total = root.appsCount()
            if (root.selectedIndex >= 0 && root.selectedIndex < total) {
              if (root.selectedIndex < root.displayStreams.length)
                root.toggleStreamMute(root.displayStreams[root.selectedIndex])
              else {
                var is = root.displayInputStreams[root.selectedIndex - root.displayStreams.length]
                root.toggleInputStreamMute(is)
              }
            }
          }
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

          // ---------- Tab bar ----------
          Row {
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.tabs

              Rectangle {
                required property string modelData
                required property int index
                id: tabChip
                width: (panelColumn.width - Style.space(12)) / root.tabs.length
                implicitHeight: tabLabel.implicitHeight + Style.space(12)
                radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(6)
                color: root.activeTab === tabChip.modelData
                  ? root.selectedFill
                  : Qt.rgba(1, 1, 1, 0.04)
                border.color: Qt.rgba(1, 1, 1, 0.06)
                border.width: 1

                Text {
                  id: tabLabel
                  textFormat: Text.PlainText
                  text: modelData === "output" ? "Output"
                      : modelData === "input" ? "Input"
                      : "Apps"
                  color: root.activeTab === tabChip.modelData
                    ? root.bar.foreground
                    : Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: root.activeTab === tabChip.modelData
                  horizontalAlignment: Text.AlignHCenter
                  anchors.centerIn: parent
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onContainsMouseChanged: if (containsMouse) {
                    root.cursorActive = true
                    root.focusSection = "header"
                    root.selectedIndex = -1
                  }
                  onClicked: root.switchTab(tabChip.modelData)
                }
              }
            }
          }

          // ---------- Output tab ----------
          Item {
            id: outputContent
            visible: root.activeTab === "output"
            width: parent.width
            implicitHeight: outputCol.implicitHeight

            Column {
              id: outputCol
              width: parent.width
              spacing: Style.space(14)

          // ---------- Output devices ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: devHint.implicitHeight

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
            }
          }

          // ---------- Input tab ----------
          Item {
            id: inputContent
            visible: root.activeTab === "input"
            width: parent.width
            implicitHeight: inputCol.implicitHeight

            Column {
              id: inputCol
              width: parent.width
              spacing: Style.space(14)

          // ---------- Input devices ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(srcHeader.implicitHeight, srcHint.implicitHeight)

              PanelSectionHeader {
                id: srcHeader
                text: "INPUT DEVICES"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: srcHint
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
              model: root.displaySources

              SourceRow {
                required property var modelData
                required property int index
                width: panelColumn.width
                source: modelData
                rowIndex: index
              }
            }
          }

          // ---------- Recording input streams ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(instreamHeader.implicitHeight, instreamHint.implicitHeight)

              PanelSectionHeader {
                id: instreamHeader
                text: "RECORDING APPS"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: instreamHint
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
              model: root.displayInputStreams

              InputStreamRow {
                required property var modelData
                required property int index
                width: panelColumn.width
                stream: modelData
                rowIndex: index
                cursorSection: "instreams"
              }
            }

            Item {
              visible: !root.hasInputStreams
              width: parent.width
              implicitHeight: Style.space(40)
              anchors.topMargin: Style.space(4)

              Text {
                textFormat: Text.PlainText
                text: "󰂯  Nothing recording"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                anchors.centerIn: parent
              }
            }
          }
            }
          }

          // ---------- Apps tab ----------
          Item {
            id: appsContent
            visible: root.activeTab === "apps"
            width: parent.width
            implicitHeight: appsCol.implicitHeight

            Column {
              id: appsCol
              width: parent.width
              spacing: Style.space(14)

          // ---------- All apps (output + recording) ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(appsHeader.implicitHeight, appsHint.implicitHeight)

              PanelSectionHeader {
                id: appsHeader
                text: "ALL APPS"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: appsHint
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
                cursorSection: "apps"
              }
            }

            Repeater {
              model: root.displayInputStreams

              InputStreamRow {
                required property var modelData
                required property int index
                width: panelColumn.width
                stream: modelData
                rowIndex: root.displayStreams.length + index
                cursorSection: "apps"
              }
            }

            Item {
              visible: !root.hasStreams && !root.hasInputStreams
              width: parent.width
              implicitHeight: Style.space(40)
              anchors.topMargin: Style.space(4)

              Text {
                textFormat: Text.PlainText
                text: "󰂯  No active apps"
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
    required property string cursorSection

    readonly property real streamVolume: stream ? (Number(stream.volume) || 0) : 0
    readonly property bool streamMuted: stream ? !!stream.muted : false
    readonly property string currentSink: stream ? (stream.sinkName || "") : ""

    hasCursor: root.cursorActive && root.focusSection === streamRow.cursorSection && root.selectedIndex === rowIndex
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

  // ---- Input device row: select a default source -------------------------
  component SourceRow: CursorSurface {
    id: sourceRow
    required property var source
    required property int rowIndex

    readonly property bool isActive: source && source.name === root.defaultSourceName
    hasCursor: root.cursorActive && root.focusSection === "inputdevices" && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(sourceRow)
    current: isActive
    foreground: root.bar.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: sourceInner.implicitHeight + Style.spacing.xl

    Row {
      id: sourceInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: Model.defaultSourceGlyph(source, root.defaultSourceName)
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.title
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: Model.sourceLabel(source)
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        font.bold: sourceRow.isActive
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
        root.focusSection = "inputdevices"
        root.selectedIndex = sourceRow.rowIndex
      }
      onClicked: root.setDefaultSource(source)
    }
  }

  // ---- Input stream row: a recording app + volume + source router ---------
  component InputStreamRow: CursorSurface {
    id: instreamRow
    required property var stream
    required property int rowIndex
    required property string cursorSection

    readonly property real streamVolume: stream ? (Number(stream.volume) || 0) : 0
    readonly property bool streamMuted: stream ? !!stream.muted : false
    readonly property string currentSource: stream ? (stream.sourceName || "") : ""

    hasCursor: root.cursorActive && root.focusSection === instreamRow.cursorSection && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(instreamRow)
    foreground: root.bar.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: instreamColumn.implicitHeight + Style.spacing.xl

    Column {
      id: instreamColumn
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
          id: instreamMuteIcon
          textFormat: Text.PlainText
          text: Model.muteGlyph(stream)
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.title
          width: Style.space(22)
          horizontalAlignment: Text.AlignHCenter
          anchors.verticalCenter: parent.verticalCenter
          opacity: instreamRow.streamMuted ? 0.5 : 1.0

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.toggleInputStreamMute(instreamRow.stream)
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
          width: parent.width - instreamMuteIcon.width - instreamPct.width - Style.space(16)
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          id: instreamPct
          textFormat: Text.PlainText
          text: Model.volumePercent(stream) + "%"
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          width: Style.space(36)
          horizontalAlignment: Text.AlignRight
          anchors.verticalCenter: parent.verticalCenter
          opacity: instreamRow.streamMuted ? 0.5 : 1.0
        }
      }

      // Volume slider
      PanelSlider {
        bar: root.bar
        width: parent.width
        minimum: 0
        maximum: 1.5
        step: 0.05
        value: instreamRow.streamVolume
        opacity: instreamRow.streamMuted ? 0.5 : 1.0

        onMoved: function(v) { root.setInputStreamVolume(instreamRow.stream, v) }
        onRightClicked: root.toggleInputStreamMute(instreamRow.stream)
      }

      // Device router (choose the mic to record from)
      Row {
        width: parent.width
        spacing: Style.space(8)

        Text {
          text: "record from"
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          width: Style.space(78)
          anchors.verticalCenter: parent.verticalCenter
        }

        Dropdown {
          width: parent.width - Style.space(78) - Style.space(8)
          value: instreamRow.currentSource
          options: Model.sourceDropdownOptions(root.displaySources, instreamRow.currentSource)
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily

          onChanged: function(value) {
            root.moveInputStream(instreamRow.stream, value)
          }
        }
      }
    }
  }
}
