# Device files

A device file describes the keys of one device: where push to talk reads the side key and the key of a wired headset, and
how a long press on Home arrives. `install.sh` finds the file of the device it runs on, asks once whether to use it
(stored as `DEVICE` in `~/.config/termux-rootbridge/config`, `--device ID|none` changes it) and installs its valid lines
as `device.conf` next to that config, where `sidekey-ptt` and `headset-ptt` read them. The questions about the keys stay:
the file says where a key is, you say whether you want it. A key the file does not describe is not asked for.

Without a device file the readers use the values of the Hisense A9 (as before there were device files).

## The name of the file

`<manufacturer>-<model>.conf`, in lower case, every other character than `a-z 0-9 . _ -` turned into `-`. The installer
reads both from the vendor partition first (`ro.product.vendor.manufacturer`, `ro.product.vendor.model`), then
`ro.product.odm.*`, then `ro.product.*`: a custom system image (GSI) reports names of its own in `ro.product.*`. A device
without a file gets a note with the name to use:

    Gerät: Onyx MaxLumi (keine Gerätedatei; eigene anlegen: devices/onyx-maxlumi.conf, siehe devices/README.md)

## The lines

Only `KEY=VALUE` lines and `#` comments on lines of their own. The file is read as data, never run. A line with an unknown
key or a value that does not fit is left out, with a note during the installation.

| Key | Value | Meaning |
|---|---|---|
| `LABEL` | up to 64 letters, digits, space, `. _ ( ) + -` | the name the installer shows ("Hisense A9") |
| `NAME` | like a Remote Control name (`A-Z a-z 0-9 . _ -`, up to 64) | suggested name of the device in Claude Remote Control |
| `SIDEKEY_DEVICE` | `/dev/input/eventN` | the input device of the side key |
| `SIDEKEY_DEVICE_NAME` | up to 64 letters, digits, space, `. _ -` | instead: the input device whose name has this (looked up as root) |
| `SIDEKEY_CODE` | a number | the key code of the side key (`getevent -l` shows it) |
| `HEADSET_DEVICE`, `HEADSET_DEVICE_NAME`, `HEADSET_CODE` | as above | the key of a wired headset |
| `HOMEKEY_METHOD` | `assistant` or `none` | `assistant`: a long press on Home starts Android's assistant, which Termux push to talk becomes |
| `LONG_PRESS` | seconds, e.g. `0.4` | how long a key is held for a long press |

Find the values as root in Termux: `getevent -pl` lists the input devices with their names, and `getevent -l` shows the
code of a key while you press it.
