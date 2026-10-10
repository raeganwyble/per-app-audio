#!/bin/bash
# Regression test for the producer-side resource bounds in query-audio.sh.
#
# An adversarial local audio client can register arbitrarily many PipeWire/
# Pulse objects, or use very large names. The helper must NOT forward that
# data to the panel: it must return a small, fail-closed error response.
#
# This test runs query-audio.sh against fake pactl/pw-dump binaries that emit
# oversized graphs and asserts the helper returns a bounded error (no data
# forwarded) in each case, plus a normal response for a well-formed graph.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUERY="$ROOT/query-audio.sh"
JQ="$(command -v jq)" || { echo "FAIL: jq is required to run this test"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
pass() { echo "PASS: $1"; }
failmsg() { echo "FAIL: $1"; fail=1; }

# Make a fake env dir containing pactl/pw-dump driven by JSON files, so the
# helper is exercised through the real PATH/command lookups.
make_fake() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/pactl" <<'SCRIPT'
#!/bin/bash
set -uo pipefail
case "${1:-}" in
  -fjson)
    case "${3:-}" in
      sink-inputs)    cat "$FAKE/sink-inputs.json" ;;
      sinks)          cat "$FAKE/sinks.json" ;;
      source-outputs) cat "$FAKE/source-outputs.json" ;;
      sources)        cat "$FAKE/sources.json" ;;
      *)              exit 1 ;;
    esac ;;
  get-default-sink)   printf '%s\n' "$FAKE_DEFAULT_SINK" ;;
  get-default-source) printf '%s\n' "$FAKE_DEFAULT_SOURCE" ;;
  *) exit 1 ;;
esac
SCRIPT
  cat > "$dir/pw-dump" <<'SCRIPT'
#!/bin/bash
set -uo pipefail
cat "$FAKE/pw-dump.json"
SCRIPT
  chmod +x "$dir/pactl" "$dir/pw-dump"
}

run_query() {
  # usage: run_query <fakedir> ; prints the helper's stdout
  FAKE="$1" FAKE_DEFAULT_SINK="$2" FAKE_DEFAULT_SOURCE="$3" \
    PATH="$1:$PATH" "$QUERY" 2>/dev/null
}

write_graph() {
  # $1 dir, remaining args key=file content are written as JSON files.
  local dir="$1"; shift
  while [[ $# -gt 0 ]]; do
    local key="${1%%=*}" val="${1#*=}"
    printf '%s' "$val" > "$dir/$key.json"
    shift
  done
}

assert_bounded() {
  # usage: assert_bounded <case> <output>; output must be a small JSON doc
  # whose status.ok==false, message is non-empty, and streams/sinks are empty.
  local case="$1" out="$2"
  local ok msg streams len
  ok="$(printf '%s' "$out" | "$JQ" -r '.status.ok' 2>/dev/null || echo 'NOTJSON')"
  msg="$(printf '%s' "$out" | "$JQ" -r '.status.message' 2>/dev/null || echo '')"
  streams="$(printf '%s' "$out" | "$JQ" -r '.streams | length' 2>/dev/null || echo -1)"
  len="${#out}"
  if [[ "$ok" == "false" && -n "$msg" && "$streams" == "0" && "$len" -lt 4096 ]]; then
    pass "$case returned a bounded error response (${len} bytes)"
  else
    failmsg "$case: expected bounded error; got ok=$ok streams=$streams len=$len msg=$msg"
  fi
}

assert_happy() {
  local case="$1" out="$2"
  local ok streams sinks default_sink rules_type
  ok="$(printf '%s' "$out" | "$JQ" -r '.status.ok' 2>/dev/null || echo 'NOTJSON')"
  streams="$(printf '%s' "$out" | "$JQ" -r '.streams | length' 2>/dev/null || echo -1)"
  sinks="$(printf '%s' "$out" | "$JQ" -r '.sinks | length' 2>/dev/null || echo -1)"
  default_sink="$(printf '%s' "$out" | "$JQ" -r '.defaultSink' 2>/dev/null || echo '')"
  rules_type="$(printf '%s' "$out" | "$JQ" -r '.rules | type' 2>/dev/null || echo '')"
  if [[ "$ok" == "true" && "$streams" == "1" && "$sinks" == "2" && "$default_sink" == "alsa_output.pci" && "$rules_type" == "object" ]]; then
    pass "$case parsed a well-formed graph"
  else
    failmsg "$case: unexpected response ok=$ok streams=$streams sinks=$sinks default=$default_sink rules=$rules_type"
  fi
}

# ---------------------------------------------------------------------------
# Shared well-formed graph (sinks/sources/defaults) used by every case.
SINKS='[{"index":2,"name":"alsa_output.pci","description":"Built-in Audio"},
        {"index":3,"name":"alsa_output.usb","description":"USB Headset"}]'
SOURCES='[{"index":4,"name":"alsa_input.pci","description":"Built-in Mic"},
          {"index":5,"name":"alsa_input.usb","description":"USB Mic"}]'
HAPPY_INPUTS='[{"index":1,"sink":2,
  "volume":{"front-left":{"value_percent":"50%"}},"mute":false,
  "properties":{"application.name":"discord","application.process.binary":"discord",
                "application.process.id":"1234","media.name":"Voice"}}]'

# --- Case 1: happy path (well-formed, no bounds violated) ------------------
F1="$TMP/f1"; make_fake "$F1"
write_graph "$F1" \
  "sink-inputs=$HAPPY_INPUTS" "sinks=$SINKS" "source-outputs=[]" "sources=$SOURCES" \
  "pw-dump=[]"
assert_happy "happy path" "$(run_query "$F1" "alsa_output.pci" "alsa_input.pci")"

# --- Case 2: oversized NAME (single string far beyond MAX_FIELD_LEN) -------
F2="$TMP/f2"; make_fake "$F2"
LONG_NAME="$(head -c 4096 /dev/zero | tr '\0' 'a')"
# shellcheck disable=SC2016 # jq expression uses $media on purpose (not a shell var)
OVERSIZED_NAME="$(printf '%s' "$HAPPY_INPUTS" | "$JQ" -c --arg media "$LONG_NAME" \
  'map(.properties["media.name"] = $media)')"
write_graph "$F2" \
  "sink-inputs=$OVERSIZED_NAME" "sinks=$SINKS" "source-outputs=[]" "sources=$SOURCES" \
  "pw-dump=[]"
assert_bounded "oversized name" "$(run_query "$F2" "alsa_output.pci" "alsa_input.pci")"

# --- Case 3: oversized COUNT (more objects than MAX_OBJECTS) ---------------
F3="$TMP/f3"; make_fake "$F3"
MANY_INPUTS="$(printf '%s' "$HAPPY_INPUTS" | "$JQ" -c '[range(0;2000) |
  {index: ., sink: 2, mute: false,
   volume: {"front-left": {"value_percent": "50%"}},
   properties: {"application.name": "demo", "media.name": "x"}}]')"
write_graph "$F3" \
  "sink-inputs=$MANY_INPUTS" "sinks=$SINKS" "source-outputs=[]" "sources=$SOURCES" \
  "pw-dump=[]"
assert_bounded "oversized object count" "$(run_query "$F3" "alsa_output.pci" "alsa_input.pci")"

# --- Case 4: oversized pw-dump (raw capture exceeds MAX_RAW_BYTES) ----------
F4="$TMP/f4"; make_fake "$F4"
BIG_DUMP="$(printf '%s' "[]" | "$JQ" -c '[range(0;30000) |
  {type: "PipeWire:Interface:Node", info: {props: {"media.class": "Audio/Sink", "node.name": "bulk"}}}]')"
write_graph "$F4" \
  "sink-inputs=$HAPPY_INPUTS" "sinks=$SINKS" "source-outputs=[]" "sources=$SOURCES" \
  "pw-dump=$BIG_DUMP"
assert_bounded "oversized pw-dump registry" "$(run_query "$F4" "alsa_output.pci" "alsa_input.pci")"

# ---------------------------------------------------------------------------
# Persistent routing-rule cases (feature: remember an app's output device).
run_query_with_config() {
  # usage: run_query_with_config <fakedir> <default-sink> <default-source> <cfgdir>
  FAKE="$1" FAKE_DEFAULT_SINK="$2" FAKE_DEFAULT_SOURCE="$3" \
    XDG_CONFIG_HOME="$4" PATH="$1:$PATH" "$QUERY" 2>/dev/null
}

run_rule_op() {
  # usage: run_rule_op <fakedir> <cfgdir> <args...>
  local fakedir="$1" cfg="$2"; shift 2
  FAKE="$fakedir" XDG_CONFIG_HOME="$cfg" PATH="$fakedir:$PATH" "$QUERY" "$@" 2>/dev/null
}

# --- Case 5: set-rule persists, shows in the payload, clear-rule removes it -
F5="$TMP/f5"; make_fake "$F5"
CFG5="$TMP/cfg5"; mkdir -p "$CFG5"
write_graph "$F5" \
  "sink-inputs=$HAPPY_INPUTS" "sinks=$SINKS" "source-outputs=[]" "sources=$SOURCES" "pw-dump=[]"
RULE_FILE5="$CFG5/io.github.raeganwyble.per-app-audio/rules.json"
run_rule_op "$F5" "$CFG5" --set-rule "bin:discord" "alsa_output.usb" >/dev/null
saved="$( "$JQ" -r '.rules["bin:discord"]' "$RULE_FILE5" 2>/dev/null || echo '')"
in_payload="$(run_query_with_config "$F5" "alsa_output.pci" "alsa_input.pci" "$CFG5" | "$JQ" -r '.rules["bin:discord"]' 2>/dev/null || echo '')"
if [[ "$saved" == "alsa_output.usb" && "$in_payload" == "alsa_output.usb" ]]; then
  pass "set-rule persisted and appeared in the query payload"
else
  failmsg "set-rule: file='$saved' payload='$in_payload'"
fi
run_rule_op "$F5" "$CFG5" --clear-rule "bin:discord" >/dev/null
after="$( "$JQ" -r '.rules["bin:discord"] // "absent"' "$RULE_FILE5" 2>/dev/null || echo 'ERR')"
if [[ "$after" == "absent" ]]; then pass "clear-rule removed the rule"; else failmsg "clear-rule left: $after"; fi

# --- Case 6: corrupt rules file degrades to {} without breaking the query ---
F6="$TMP/f6"; make_fake "$F6"
CFG6="$TMP/cfg6"
mkdir -p "$CFG6/io.github.raeganwyble.per-app-audio"
printf 'not json' > "$CFG6/io.github.raeganwyble.per-app-audio/rules.json"
write_graph "$F6" \
  "sink-inputs=$HAPPY_INPUTS" "sinks=$SINKS" "source-outputs=[]" "sources=$SOURCES" "pw-dump=[]"
out6="$(run_query_with_config "$F6" "alsa_output.pci" "alsa_input.pci" "$CFG6")"
ok6="$(printf '%s' "$out6" | "$JQ" -r '.status.ok' 2>/dev/null || echo 'NOTJSON')"
n6="$(printf '%s' "$out6" | "$JQ" -r '.rules | length' 2>/dev/null || echo -1)"
if [[ "$ok6" == "true" && "$n6" == "0" ]]; then
  pass "corrupt rules file degrades to empty and query still succeeds"
else
  failmsg "corrupt rules: ok=$ok6 rules=$n6"
fi

# --- Case 7: oversized rule value is rejected and not stored ----------------
F7="$TMP/f7"; make_fake "$F7"
CFG7="$TMP/cfg7"; mkdir -p "$CFG7"
BIG_VAL="$(head -c 4096 /dev/zero | tr '\0' 'b')"
run_rule_op "$F7" "$CFG7" --set-rule "bin:x" "$BIG_VAL" >/dev/null
RULE_FILE7="$CFG7/io.github.raeganwyble.per-app-audio/rules.json"
if [[ ! -f "$RULE_FILE7" || "$( "$JQ" -r '.rules | length' "$RULE_FILE7" 2>/dev/null || echo X )" == "0" ]]; then
  pass "oversized rule value rejected"
else
  failmsg "oversized rule value was stored"
fi

exit "$fail"