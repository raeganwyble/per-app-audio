// Model.js - pure helpers for parsing audio state from query-audio.sh output.
// Imported by Panel.qml.

function parseAudioData(raw) {
  var data = {}
  try { data = JSON.parse(raw) } catch (e) { data = {} }
  var streams = Array.isArray(data.streams) ? data.streams : []
  var sinks = Array.isArray(data.sinks) ? data.sinks : []
  return {
    streams: streams,
    sinks: sinks,
    defaultSink: data.defaultSink || ""
  }
}

function volumePercent(stream) {
  if (!stream) return 0
  var v = Number(stream.volume)
  if (isNaN(v)) return 0
  return Math.round(Math.min(1.5, Math.max(0, v)) * 100)
}

function muted(stream) {
  return !!(stream && stream.muted)
}

function muteGlyph(stream) {
  return muted(stream) ? "\ue908" : "\uf028"
}

function streamLabel(stream) {
  if (!stream) return "Unknown app"
  var app = stream.appName || ""
  if (app !== "" && app !== "Unknown app") return app
  if (stream.mediaName) return stream.mediaName
  return "Application"
}

function shortSinkName(name) {
  if (!name) return "Default"
  var s = String(name)
  s = s.replace(/^alsa_output\./, "")
  s = s.replace(/\.analog-stereo$/, "")
  s = s.replace(/\.HiFi__\S+$/, "")
  return s
}

function sinkLabel(sink) {
  if (!sink) return "Unknown device"
  return sink.description || sink.name || "Unknown device"
}

function currentSinkLabel(stream, sinks) {
  if (!stream) return ""
  var name = stream.sinkName || ""
  if (!name) return "Default"
  for (var i = 0; i < sinks.length; i++) {
    if (sinks[i].name === name) return sinkLabel(sinks[i])
  }
  return shortSinkName(name)
}

function dropdownOptions(sinks, currentName) {
  var opts = []
  for (var i = 0; i < sinks.length; i++) {
    var s = sinks[i]
    opts.push({
      value: s.name,
      label: sinkLabel(s),
      current: s.name === currentName
    })
  }
  return opts
}

function isDefault(sink, defaultSink) {
  return !!(sink && sink.name && sink.name === defaultSink)
}

function defaultGlyph(sink, defaultSink) {
  return isDefault(sink, defaultSink) ? "\uf058" : "\uf10c"
}

function emptyState(streams) {
  return streams.length === 0
}

if (typeof module !== "undefined") {
  module.exports = {
    parseAudioData: parseAudioData,
    volumePercent: volumePercent,
    muted: muted,
    muteGlyph: muteGlyph,
    streamLabel: streamLabel,
    shortSinkName: shortSinkName,
    sinkLabel: sinkLabel,
    currentSinkLabel: currentSinkLabel,
    dropdownOptions: dropdownOptions,
    isDefault: isDefault,
    defaultGlyph: defaultGlyph,
    emptyState: emptyState
  }
}
