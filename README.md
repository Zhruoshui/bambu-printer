# Bambu Printer — Omarchy bar widget

Live print status from a Bambu Lab printer in the Omarchy bar: progress and
remaining time at a glance, temperatures, layer and connection detail in a
popup. One widget per printer.

Status is read over **LAN MQTT** — the same dialect Bambu Studio uses — so the
printer must be reachable on your local network with LAN access enabled. The
access code is read from Bambu Studio's own configuration; there is nothing to
type if the printer is already paired there.

## Requirements

- [Omarchy](https://omarchy.com) with the quickshell-based shell
- A Bambu Lab printer on the same LAN, with **LAN access enabled**
- Python 3 from the system (`/usr/bin/python3`) — no packages are installed;
  the bridge script uses only the standard library

Cloud-only printers are not supported.

## Install

```sh
omarchy plugin clone https://github.com/Zhruoshui/bambu-printer
```

Then add the widget to your bar:

```sh
omarchy bar put io.github.zhruoshui.bambu-printer
```

For multiple printers, repeat `bar put` and set each instance's serial number.

## Configure

Widget settings live inline in the widget's entry under `bar.layout` in
`~/.config/omarchy/shell.json`. Either edit that entry directly or use
`omarchy bar set`:

| Setting       | Description                                                        |
| ------------- | ------------------------------------------------------------------ |
| `printerSn`   | 15-character serial number (required). Shown in Bambu Studio's printer settings. |
| `printerIp`   | LAN IP of the printer (required). Find it in Bambu Studio's device page or your router. |
| `printerName` | Optional friendly name shown in the panel. Defaults to the last digits of the SN. |
| `accessCode`  | Optional manual access code. Leave empty to read it from `~/.config/BambuStudio/BambuStudio.conf` automatically. |
| `showWhenIdle`| Keep the widget visible while the printer is idle/offline (default: off). |

```sh
omarchy bar set io.github.zhruoshui.bambu-printer printerSn 00M09C3A0801234
omarchy bar set io.github.zhruoshui.bambu-printer printerIp 192.168.1.42
```

The widget hides itself until both `printerSn` and `printerIp` are set.

### How it connects

`scripts/bambu-bridge.py` opens one MQTT connection per widget instance with
the Bambu LAN credentials (user `bblp`, password = the access code),
subscribes to the printer's report topic, requests a full status push, and
answers the keepalive. The transport is negotiated automatically: older
firmware serves plaintext MQTT on port 1883, current firmware only TLS on
8883 (its device certificate is accepted as-is, like every other LAN tool).
It reconnects on its own with backoff when the printer goes away and comes
back; the widget never needs restarting.

## Remove

```sh
omarchy plugin remove io.github.zhruoshui.bambu-printer
```

## License

MIT — see [LICENSE](LICENSE).
