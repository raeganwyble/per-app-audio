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

# Requirements: the per-app router needs the PulseAudio compatibility layer
# (pactl) for per-stream routing/volume/mute; the friendly-name and device
# fallback path only needs pw-dump + jq (both ship with PipeWire/Omarchy).
pactl_path="$(command -v pactl || true)"
pwdump_path="$(command -v pw-dump || true)"
jq_path="$(command -v jq || true)"
missing=()
if [[ -z "$pactl_path" ]]; then missing+=("pactl"); fi
if [[ -z "$pwdump_path" ]]; then missing+=("pw-dump"); fi
if [[ -z "$jq_path" ]]; then missing+=("jq"); fi

# Stop early if jq (needed to emit JSON) is missing, or if nothing can produce
# data (no pw-dump and no pactl).
if [[ -z "$jq_path" || ( "${#missing[@]}" -gt 0 && -z "$pactl_path" && -z "$pwdump_path" ) ]]; then
  jq -n --argjson missing "$(printf '%s\n' "${missing[@]}" | jq -R . | jq -s '.')" \
    '{status: {ok: false, missing: $missing, message: "query-audio.sh requires jq plus pw-dump or pactl"}}'
  exit 0
fi

# Snapshot the PulseAudio graph once so streams and sinks agree. When pactl is
# absent (minimal installs) we skip the pactl pulls and instead synthesize the
# same arrays from pw-dump/wpctl below, producing a device-only view.
sink_inputs_json=""
sinks_json=""
default_sink=""
source_outputs_json=""
sources_json=""
default_source=""
if [[ -n "$pactl_path" ]]; then
  sink_inputs_json="$(pactl -fjson list sink-inputs 2>/dev/null || true)"
  sinks_json="$(pactl -fjson list sinks 2>/dev/null || true)"
  default_sink="$(pactl get-default-sink 2>/dev/null || true)"

  # Input graph snapshot (recording streams + input devices) taken together.
  source_outputs_json="$(pactl -fjson list source-outputs 2>/dev/null || true)"
  sources_json="$(pactl -fjson list sources 2>/dev/null || true)"
  default_source="$(pactl get-default-source 2>/dev/null || true)"
else
  # Device-only fallback (no pactl): build sink/source arrays from pw-dump in
  # the same shape pactl would have produced, and read the current default
  # endpoint from PipeWire's "default" metadata object. Per-app streams are left
  # empty because listing/moving them requires the PulseAudio compatibility
  # layer.
  defaults="$(pw-dump 2>/dev/null | jq -c '[.[] | select(.type=="PipeWire:Interface:Metadata") | select(.props["metadata.name"]=="default") | .metadata[] | select(.key | startswith("default.audio.")) | {key, value}]')"
  default_sink="$(printf '%s' "$defaults" | jq -r '.[] | select(.key=="default.audio.sink") | .value.name // ""' 2>/dev/null || true)"
  default_source="$(printf '%s' "$defaults" | jq -r '.[] | select(.key=="default.audio.source") | .value.name // ""' 2>/dev/null || true)"

  sinks_json="$(pw-dump 2>/dev/null | jq -c '[.[] |
    select(.type=="PipeWire:Interface:Node") |
    select((.info.props["media.class"] // "")=="Audio/Sink") |
    {index: (.info.props["object.id"] // -1),
     name: (.info.props["node.name"] // ""),
     description: (.info.props["node.description"] // .info.props["node.name"] // ""),
     default: false}]')"
  sources_json="$(pw-dump 2>/dev/null | jq -c '[.[] |
    select(.type=="PipeWire:Interface:Node") |
    select((.info.props["media.class"] // "")=="Audio/Source") |
    {index: (.info.props["object.id"] // -1),
     name: (.info.props["node.name"] // ""),
     description: (.info.props["node.description"] // .info.props["node.name"] // ""),
     default: false}]')"
  # Mark the default sink/source.
  if [[ -n "$default_sink" ]]; then
    sinks_json="$(printf '%s' "$sinks_json" | jq -c --arg d "$default_sink" 'map(.default = (.name == $d))')"
  fi
  if [[ -n "$default_source" ]]; then
    sources_json="$(printf '%s' "$sources_json" | jq -c --arg d "$default_source" 'map(.default = (.name == $d))')"
  fi
fi

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

# Normalize possibly-empty results (device-only fallback yields empty stream
# arrays and possibly empty descriptor indexes) to valid JSON before assembly.
[[ -z "$streams" ]] && streams="[]"
[[ -z "$input_streams" ]] && input_streams="[]"
[[ -z "$sinks_out" ]] && sinks_out="[]"
[[ -z "$sources_out" ]] && sources_out="[]"
[[ -z "$sink_desc_index" ]] && sink_desc_index="{}"
[[ -z "$src_desc_index" ]] && src_desc_index="{}"

# Reporting status for the panel. ok=true when every required tool is present;
# otherwise the panel surfaces a "missing requirements" notice.
if [[ "${#missing[@]}" -eq 0 ]]; then
  status_json='{"ok": true, "missing": [], "message": ""}'
else
  missing_json="$(printf '%s\n' "${missing[@]}" | jq -R . | jq -s '.')"
  status_json="$(jq -n --argjson missing "$missing_json" --arg msg "Missing tools: ${missing[*]}. Install libpulse (pactl) and/or pipewire-pulse for full per-app routing." \
    '{ok: false, missing: $missing, message: $msg}')"
fi

jq -n \
  --argjson streams "$streams" \
  --argjson sinks "$sinks_out" \
  --arg defaultSink "$default_sink" \
  --argjson inputStreams "$input_streams" \
  --argjson sources "$sources_out" \
  --arg defaultSource "$default_source" \
  --argjson status "$status_json" \
  '{streams: $streams, sinks: $sinks, defaultSink: $defaultSink, inputStreams: $inputStreams, sources: $sources, defaultSource: $defaultSource, status: $status}'
