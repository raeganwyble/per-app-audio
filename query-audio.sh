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

# ---------------------------------------------------------------------------
# Producer-side bounds. PipeWire/Pulse object graphs are attacker-influenced
# (any local audio client can register arbitrarily many objects or use very
# long names), and this script used to forward the *complete* graph to the
# panel every poll. These caps bound object count, individual string length,
# per-capture bytes, and final payload bytes, and **fail closed**: any capture
# that exceeds a cap or isn't a valid JSON array of objects aborts the whole
# query with a small error response instead of forwarding the oversized data.
readonly MAX_OBJECTS=1024        # max objects in any single list
readonly MAX_FIELD_LEN=512       # max bytes/length of any single string value
readonly MAX_RAW_BYTES=1048576   # max bytes of any single raw capture (1 MiB)
readonly MAX_TOTAL_BYTES=8388608 # max bytes of the final serialized payload

cap_flag=0 # set to 1 by capture_bounded when a byte cap was hit

# usage: capture_bounded <var> <byte_cap> <cmd...>
# Sets <var> (global) to stdout of <cmd...>, truncated at <byte_cap>. When the
# output reaches the cap, <var> is left empty and cap_flag is set to 1.
capture_bounded() {
  local out
  out="$("${@:3}" 2>/dev/null | head -c "$2" || true)"
  if (( ${#out} >= $2 )); then
    cap_flag=1
    eval "$1=''"
  else
    cap_flag=0
    eval "$1=\$out"
  fi
}

# usage: list_valid <json>; exit 0 when <json> is a JSON array of objects whose
# length is within MAX_OBJECTS and whose string values are within MAX_FIELD_LEN.
list_valid() {
  [[ -n "$1" ]] || return 1
  jq -e --argjson m "$MAX_FIELD_LEN" --argjson n "$MAX_OBJECTS" '
    type == "array" and
    (length <= $n) and
    all(.[]; type == "object") and
    ([.. | strings | length] | max // 0) <= $m
  ' >/dev/null 2>&1 <<< "$1"
}

# usage: bounded_error <reason>; emits a small fail-closed response and exits 0
# (so the panel surfaces the message instead of parsing garbage).
bounded_error() {
  jq -n --arg msg "query-audio.sh refused to forward oversized audio data: $1" \
    '{status: {ok: false, missing: [], message: $msg}, streams: [], sinks: [], defaultSink: "", inputStreams: [], sources: [], defaultSource: ""}'
}

# usage: validate_capture <label> <json>; fails closed unless the preceding
# capture stayed under its byte cap and parsed as a valid in-bounds list.
validate_capture() {
  if (( cap_flag )); then
    bounded_error "binary capture of \"$1\" hit its byte cap"
    exit 0
  fi
  if ! list_valid "$2"; then
    bounded_error "\"$1\" exceeded MAX_OBJECTS/MAX_FIELD_LEN or was not a JSON array of objects"
    exit 0
  fi
}

# Bounded snapshot of the PipeWire registry, captured once and reused for the
# friendly-name map and (when pactl is absent) the device-only fallback. A
# missing pw-dump is fine when pactl is present (friendly names stay empty).
if [[ -n "$pwdump_path" ]]; then
  capture_bounded pw_raw "$MAX_RAW_BYTES" pw-dump
  validate_capture "pw-dump registry" "$pw_raw"
else
  pw_raw="[]"
fi

# Friendly names from PipeWire (node.name -> node.description) for both Sinks
# and Sources. These are the human-readable names shown by the regular volume
# control; pactl's own "description" for RODE/ALSA devices is often the raw
# profile name instead. Derived from the bounded pw_raw snapshot, so it is
# bounded too.
pw_desc="$(printf '%s' "$pw_raw" | jq '[.[] | select(.info.props["media.class"]=="Audio/Sink" or .info.props["media.class"]=="Audio/Source") | {key: .info.props["node.name"], value: (.info.props["node.description"] // "")}] | from_entries')"

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
  capture_bounded sink_inputs_json "$MAX_RAW_BYTES" pactl -fjson list sink-inputs
  validate_capture "sink-inputs" "$sink_inputs_json"
  capture_bounded sinks_json "$MAX_RAW_BYTES" pactl -fjson list sinks
  validate_capture "sinks" "$sinks_json"
  capture_bounded default_sink "$MAX_FIELD_LEN" pactl get-default-sink
  if (( cap_flag )); then
    bounded_error "default sink name exceeded MAX_FIELD_LEN"
    exit 0
  fi

  # Input graph snapshot (recording streams + input devices) taken together.
  capture_bounded source_outputs_json "$MAX_RAW_BYTES" pactl -fjson list source-outputs
  validate_capture "source-outputs" "$source_outputs_json"
  capture_bounded sources_json "$MAX_RAW_BYTES" pactl -fjson list sources
  validate_capture "sources" "$sources_json"
  capture_bounded default_source "$MAX_FIELD_LEN" pactl get-default-source
  if (( cap_flag )); then
    bounded_error "default source name exceeded MAX_FIELD_LEN"
    exit 0
  fi
else
  # Device-only fallback (no pactl): build sink/source arrays from the bounded
  # pw_raw snapshot in the same shape pactl would have produced, and read the
  # current default endpoint from PipeWire's "default" metadata object.
  # Per-app streams are left empty because listing/moving them requires the
  # PulseAudio compatibility layer.
  defaults="$(printf '%s' "$pw_raw" | jq -c '[.[] | select(.type=="PipeWire:Interface:Metadata") | select(.props["metadata.name"]=="default") | .metadata[] | select(.key | startswith("default.audio.")) | {key, value}]')"
  default_sink="$(printf '%s' "$defaults" | jq -r '.[] | select(.key=="default.audio.sink") | .value.name // ""' 2>/dev/null || true)"
  default_source="$(printf '%s' "$defaults" | jq -r '.[] | select(.key=="default.audio.source") | .value.name // ""' 2>/dev/null || true)"

  sinks_json="$(printf '%s' "$pw_raw" | jq -c '[.[] |
    select(.type=="PipeWire:Interface:Node") |
    select((.info.props["media.class"] // "")=="Audio/Sink") |
    {index: (.info.props["object.id"] // -1),
     name: (.info.props["node.name"] // ""),
     description: (.info.props["node.description"] // .info.props["node.name"] // ""),
     default: false}]')"
  sources_json="$(printf '%s' "$pw_raw" | jq -c '[.[] |
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

final_payload="$(jq -n \
  --argjson streams "$streams" \
  --argjson sinks "$sinks_out" \
  --arg defaultSink "$default_sink" \
  --argjson inputStreams "$input_streams" \
  --argjson sources "$sources_out" \
  --arg defaultSource "$default_source" \
  --argjson status "$status_json" \
  '{streams: $streams, sinks: $sinks, defaultSink: $defaultSink, inputStreams: $inputStreams, sources: $sources, defaultSource: $defaultSource, status: $status}')"

# Fail closed if serialization still exceeds the payload cap.
if (( ${#final_payload} > MAX_TOTAL_BYTES )); then
  bounded_error "final payload exceeded MAX_TOTAL_BYTES"
  exit 0
fi

printf '%s\n' "$final_payload"
