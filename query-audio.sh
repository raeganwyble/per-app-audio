#!/bin/bash

# omarchy:summary=Query active audio streams and devices (output + input) as JSON (EarTrumpet-style per-app router)

set -uo pipefail

# Emit a single JSON object describing:
#   {
#     "streams":      [ {index, sink, sinkName, volume, muted, appName, appBinary, appPid, mediaName} ],
#     "sinks":        [ {index, name, description, default} ],
#     "defaultSink":  "<name>",
#     "inputStreams": [ {index, source, sourceName, volume, muted, appName, appBinary, appPid, mediaName} ],
#     "sources":      [ {index, name, description, default} ],
#     "defaultSource":"<name>"
#   }

# Snapshot the PulseAudio graph once so streams and sinks agree.
sink_inputs_json="$(pactl -fjson list sink-inputs 2>/dev/null)"
sinks_json="$(pactl -fjson list sinks 2>/dev/null)"
default_sink="$(pactl get-default-sink 2>/dev/null)"

# Input graph snapshot (recording streams + input devices) taken together.
source_outputs_json="$(pactl -fjson list source-outputs 2>/dev/null)"
sources_json="$(pactl -fjson list sources 2>/dev/null)"
default_source="$(pactl get-default-source 2>/dev/null)"

# Friendly names from PipeWire (node.name -> node.description) for both Sinks
# and Sources. These are the human-readable names shown by the regular volume
# control; pactl's own "description" for RODE/ALSA devices is often the raw
# profile name instead.
pw_desc="$(pw-dump 2>/dev/null | jq '[.[] | select(.info.props["media.class"]=="Audio/Sink" or .info.props["media.class"]=="Audio/Source") | {key: .info.props["node.name"], value: (.info.props["node.description"] // "")}] | from_entries')"

# Full name->description map (every sink, even non-selectable ones) so a
# stream's current routing can always be labelled.
sink_desc_index="$(printf '%s' "$sinks_json" | jq --argjson pw "$pw_desc" 'map({key: (.index | tostring), value: ($pw[.name] // (if (.description == null or .description == "(null)" or .description == "") then .name else .description end))}) | from_entries')"

# List of sinks the user may route to. Keep real physical devices plus any
# remaining non-loopback sink. Prefer routing candidates that stream.module
# resolves; exclude Planar-zero and capture monitors.
selectable_sinks="$(printf '%s' "$sinks_json" | jq --argjson pw "$pw_desc" '
  [ .[] |
    select( (.name | test("monitor|virtual_sink|speaker_tuning|easyeffects_sink|filter-chain")) | not ) |
    {
      index: .index,
      name: .name,
      description: ($pw[.name] // (if (.description == null or .description == "(null)" or .description == "") then .name else .description end))
    }
  ]')"

# If every sink got excluded (should never happen), fall back to all sinks.
if [[ "$(printf '%s' "$selectable_sinks" | jq 'length' 2>/dev/null || echo 0)" == "0" ]]; then
  selectable_sinks="$(printf '%s' "$sinks_json" | jq --argjson pw "$pw_desc" '[.[] | {index, name, description: ($pw[.name] // (if (.description == null or .description == "(null)" or .description == "") then .name else .description end))}]')"
fi

# Active application streams. DSP filter-chain outputs (EasyEffects, speaker
# tuning) are themselves sink-inputs that feed their own sink; excluding them
# by app/binary keeps the list to what the user actually hears per-app.
streams="$(printf '%s' "$sink_inputs_json" | jq --argjson sinks "$sink_desc_index" '
  [ .[] |
    select( .properties["application.name"] != "" and .properties["application.name"] != "EasyEffects" and .properties["application.name"] != "speech-dispatcher" ) |
    {
      index: .index,
      sink: .sink,
      sinkName: (($sinks[((.sink // 0) | tostring)] // "") // ""),
      volume: (((.volume | to_entries[0].value.value_percent // "0%") | gsub("%";"")) | tonumber? // 0 | . / 100),
      muted: (.mute // false),
      appName: (.properties["application.name"] // .properties["media.name"] // "Unknown app"),
      appBinary: (.properties["application.process.binary"] // ""),
      appPid: (.properties["application.process.id"] // ""),
      mediaName: (.properties["media.name"] // "")
    }
  ]')"

sinks_out="$(printf '%s' "$selectable_sinks" | jq --arg def "$default_sink" '[ .[] | .default = (.name == $def) ]')"

# ---- Input side ----------------------------------------------------------

# Full source name->description map so a recording stream's current routing can
# always be labelled (including monitors, which are not selectable).
src_desc_index="$(printf '%s' "$sources_json" | jq --argjson pw "$pw_desc" 'map({key: (.index | tostring), value: ($pw[.name] // (if (.description == null or .description == "(null)" or .description == "") then .name else .description end))}) | from_entries')"

# List of input devices the user may route to. Exclude sink monitor/loopback
# pseudo-sources, keeping real capture devices (mics, lines, virtual inputs).
selectable_sources="$(printf '%s' "$sources_json" | jq --argjson pw "$pw_desc" '
  [ .[] |
    select( (.name | test("[.]monitor$|virtual_source|easyeffects|filter-chain")) | not ) |
    {
      index: .index,
      name: .name,
      description: ($pw[.name] // (if (.description == null or .description == "(null)" or .description == "") then .name else .description end))
    }
  ]')"

# If every source got excluded (should never happen), fall back to all sources.
if [[ "$(printf '%s' "$selectable_sources" | jq 'length' 2>/dev/null || echo 0)" == "0" ]]; then
  selectable_sources="$(printf '%s' "$sources_json" | jq --argjson pw "$pw_desc" '[.[] | {index, name, description: ($pw[.name] // (if (.description == null or .description == "(null)" or .description == "") then .name else .description end))}]')"
fi

# Active recording streams (source-outputs). Same exclusion policy as outputs
# for DSP filter-chain / speech clients.
input_streams="$(printf '%s' "$source_outputs_json" | jq --argjson sources "$src_desc_index" '
  [ .[] |
    select( .properties["application.name"] != "" and .properties["application.name"] != "EasyEffects" and .properties["application.name"] != "speech-dispatcher" ) |
    {
      index: .index,
      source: .source,
      sourceName: (($sources[((.source // 0) | tostring)] // "") // ""),
      volume: (((.volume | to_entries[0].value.value_percent // "0%") | gsub("%";"")) | tonumber? // 0 | . / 100),
      muted: (.mute // false),
      appName: (.properties["application.name"] // .properties["media.name"] // "Unknown app"),
      appBinary: (.properties["application.process.binary"] // ""),
      appPid: (.properties["application.process.id"] // ""),
      mediaName: (.properties["media.name"] // "")
    }
  ]')"

sources_out="$(printf '%s' "$selectable_sources" | jq --arg def "$default_source" '[ .[] | .default = (.name == $def) ]')"

jq -n \
  --argjson streams "$streams" \
  --argjson sinks "$sinks_out" \
  --arg defaultSink "$default_sink" \
  --argjson inputStreams "$input_streams" \
  --argjson sources "$sources_out" \
  --arg defaultSource "$default_source" \
  '{streams: $streams, sinks: $sinks, defaultSink: $defaultSink, inputStreams: $inputStreams, sources: $sources, defaultSource: $defaultSource}'
