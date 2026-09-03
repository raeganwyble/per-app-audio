# Per-App Audio — EarTrumpet-style routing for Omarchy

Route each individual application to a different audio output device, adjust
per-app volume and mute, and pick your system default output — all from a
single bar widget. Inspired by
[EarTrumpet](https://github.com/File-New-Project/EarTrumpet).


## Features

- **Active apps list** — every app currently outputting audio, shown live with
  its current routing, per-app volume and mute state.
- **Per-app routing** — send any app to a different output device (e.g.
  Discord → headset, music → speakers), independent of the system default.
- **Output devices** — see every available sink and set the system default
  with one click.
- **Per-app volume (0–150%)** and **per-app mute**.
- **Friendly device names** — reads the human-readable names from PipeWire
  (`node.description`), so the devices are labelled the same way as in the
  regular volume control (e.g. "RØDECaster Main" instead of
  `alsa_output.usb-R__DE_RODECaster_Duo_IR0018155-00.pro-output-1`).
- **Keyboard navigation** — arrow keys / `j`/`k` to move, `Enter` to select,
  `h`/`l` to change volume, `m` to mute, all while the panel is open.

## Requirements

- Omarchy (Quickshell-based shell)
- PipeWire / WirePlumber with the PulseAudio compatibility layer
- `pactl`, `wpctl`, `pw-dump`, and `jq` on `PATH`

## Install

```bash
omarchy plugin add https://github.com/raeganwyble/per-app-audio.git --enable
```

Then move the widget to your bar's right section if it isn't there already:

```bash
omarchy bar move io.github.raeganwyble.per-app-audio --section right
```

Or add it manually to the `bar.layout.right` array in
`~/.config/omarchy/shell.json`:

```json
{ "id": "io.github.raeganwyble.per-app-audio" }
```

## Usage

Click the mixer icon (``) in the bar to open the panel:

1. **OUTPUT DEVICES** — click a device to set it as the system default.
2. **ACTIVE APPS** — for each app you can:
   - change the **volume** with the slider (0–150%),
   - toggle **mute**,
   - change its **output device** from the dropdown.

Changes apply immediately. The panel refreshes while it is open.

## How it works

- `query-audio.sh` snapshots the audio graph with `pactl -fjson`, resolves
  friendly device names from `pw-dump` (`node.description`), and emits JSON.
- `Panel.qml` renders the bar icon and the popup panel.
- `Model.js` contains the pure parsing/formatting helpers.

Actions are the standard PipeWire/WirePlumber commands:

- Route an app: `pactl move-sink-input <id> <sink>`
- Set default: `wpctl set-default <id>` / `pactl set-default-sink <name>`
- Set volume: `pactl set-sink-input-volume <id> <pct>`
- Toggle mute: `pactl set-sink-input-mute <id> toggle`

## Uninstall

```bash
omarchy plugin remove io.github.raeganwyble.per-app-audio
```

## License

[MIT](LICENSE)
