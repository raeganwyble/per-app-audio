// Model.js - pure helpers for parsing audio state from query-audio.sh output.
// Imported by Panel.qml.

function parseAudioData(raw) {
  var data = {}
  try { data = JSON.parse(raw) } catch (e) { data = {} }
  var streams = Array.isArray(data.streams) ? data.streams : []
  var sinks = Array.isArray(data.sinks) ? data.sinks : []
  var inputStreams = Array.isArray(data.inputStreams) ? data.inputStreams : []
  var sources = Array.isArray(data.sources) ? data.sources : []
  return {
    streams: streams,
    sinks: sinks,
    defaultSink: data.defaultSink || "",
    inputStreams: inputStreams,
    sources: sources,
    defaultSource: data.defaultSource || ""
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

// ---- Input aliases (sources mirror sinks) ---------------------------------

function sourceLabel(source) { return sinkLabel(source) }

function currentSourceLabel(stream, sources) {
  if (!stream) return ""
  var name = stream.sourceName || ""
  if (!name) return "Default"
  for (var i = 0; i < sources.length; i++) {
    if (sources[i].name === name) return sourceLabel(sources[i])
  }
  return shortSinkName(name)
}

function sourceDropdownOptions(sources, currentName) {
  return dropdownOptions(sources, currentName)
}

function isDefaultSource(source, defaultSource) {
  return isDefault(source, defaultSource)
}

function defaultSourceGlyph(source, defaultSource) {
  return defaultGlyph(source, defaultSource)
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
    emptyState: emptyState,
    sourceLabel: sourceLabel,
    currentSourceLabel: currentSourceLabel,
    sourceDropdownOptions: sourceDropdownOptions,
    isDefaultSource: isDefaultSource,
    defaultSourceGlyph: defaultSourceGlyph
  }
}
