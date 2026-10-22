# btlock

Lock your computer's screen automatically when your phone goes out of Bluetooth range.

Works on **Linux** (systemd) and **macOS**. Runs as a small per-user background service.

## How it works

Every 30 seconds `btlock` checks whether your paired phone answers over Bluetooth.

1. Phone answers: nothing happens.
2. Phone does not answer: wait 15 seconds and check again (a single missed check never locks).
3. Still no answer: lock the screen.

After locking, it will **not lock again until the phone has been seen again**. If you unlock the
computer while the phone is still away (for example you lent it to someone), you are left alone.

All timings are configurable.

## Requirements

- Your phone must be **paired** with the computer and have Bluetooth switched on.
- Python 3.
- Linux: `bluez` (`hcitool`, `l2ping` or `bluetoothctl`), systemd, and something that handles
  `loginctl lock-session` (all common desktop environments do).
- Arch / Omarchy: `hcitool` and `l2ping` are in `bluez-deprecated-tools`. On Omarchy `loginctl
  lock-session` does nothing, so `btlock` calls `omarchy-system-lock` instead.
- macOS: either `pyobjc-framework-IOBluetooth` or [`blueutil`](https://github.com/toy/blueutil).

`make configure` checks for these and offers to install what is missing.

## Quick start

```sh
make              # check dependencies
make configure    # install missing dependencies, pick your phone, write config.mk
make install      # install and start the service
```

Run make as your **normal user**, not with `sudo`. The Makefile refuses to run as root, because this
is a per-user service that needs access to your login session. `make configure` asks for `sudo`
itself when it needs to install packages.

`make configure` lists your paired devices so you can pick your phone by number. You can also give
the address directly:

```sh
make configure MAC=AA:BB:CC:DD:EE:FF
```

It finishes with a one-off presence test, so you know the phone answers before installing.

### Finding the MAC address manually

- Linux: `bluetoothctl devices Paired`
- macOS: `blueutil --paired` or `system_profiler SPBluetoothDataType`
- iPhone: Settings > General > About > Bluetooth
- Android: Settings > About phone > Status information > Bluetooth address

The address is not case sensitive, and `:` or `-` separators both work.

## Make targets

| Target | What it does |
|---|---|
| `make` | Check dependencies |
| `make configure` | Install missing dependencies, choose the phone, write `config.mk` |
| `make install` | Install and (re)start the service. Safe to run repeatedly |
| `make uninstall` | Stop and remove the service (keeps `config.mk`) |
| `make start` / `stop` / `restart` | Control the service |
| `make status` | Show service state |
| `make logs` | Follow the log |
| `make test` | One-off presence check of the configured phone |

Any setting can be overridden on the command line:

```sh
make install MAC=AA:BB:CC:DD:EE:FF INTERVAL=60 RETRY=20 TIMEOUT=8 PYTHON=/path/to/python3
```

`config.mk` is generated per machine and should not be committed.

## Running it by hand

```sh
python3 btlock.py AA:BB:CC:DD:EE:FF            # run in the foreground
python3 btlock.py AA:BB:CC:DD:EE:FF --once     # check once, print present/absent, exit 0/1
python3 btlock.py AA:BB:CC:DD:EE:FF --dry-run -v   # log what it would do, never lock
```

| Option | Default | Meaning |
|---|---|---|
| `--interval` | 30 | Seconds between checks |
| `--retry-delay` | 15 | Seconds before re-checking after a miss |
| `--timeout` | 8 | Per-probe timeout in seconds |
| `--dry-run` | off | Log instead of locking |
| `--once` | off | Probe once and exit |
| `-v` | off | Debug logging (logs every probe) |
| `--version` | | Print the git commit this was built from and exit |

Because a probe can take several seconds, the real cycle is the interval plus the probe time.

## Version

```sh
btlock --version        # e.g. "btlock 3f2a9c1d4e5b" or "btlock 3f2a9c1d4e5b-dirty"
```

The version is the git commit the script is based on (12 characters, plus `-dirty` if the working
tree had uncommitted changes). `make install` bakes it into the installed copy, so it still works
after the script has been copied out of the checkout; the installed copy is the only one that is
modified, your working tree stays clean. Running `python3 btlock.py --version` straight from a
checkout asks git directly. Without git history (for example a downloaded tarball) it reports
`unknown`. The version is also logged when the service starts.

## Where things are installed

| | Linux | macOS |
|---|---|---|
| Script | `~/.local/bin/btlock` | `~/.local/bin/btlock` |
| Service definition | `~/.config/systemd/user/btlock.service` | `~/Library/LaunchAgents/com.btlock.plist` |
| Logs | systemd journal (`make logs`) | `~/Library/Logs/btlock.log` |

On Linux the journal is rotated by journald. On macOS the log file is a plain append-only file and
is **not rotated**. At the default log level it only records events (misses, locks, returns), so it
grows very slowly. Avoid running the service with `-v`.

Typical log lines:

```
Phone not detected, re-checking in 15s
Phone found again on retry          # short dropout, nothing locked
Phone still missing - locking screen
Phone is back
```

## How presence is detected

Phones, iPhones in particular, change their Bluetooth LE address regularly, so BLE scanning is not
reliable for this. Instead `btlock` pages the paired phone over classic Bluetooth:

- Linux: `hcitool name`, then `l2ping`, then `bluetoothctl info` (which only sees the phone while it
  is connected).
- macOS: opens and closes a baseband connection through IOBluetooth, or `blueutil` as a fallback.

Locking uses `loginctl lock-session` (falling back to `xdg-screensaver`) on Linux, and the login
framework's lock call (falling back to `pmset displaysleepnow`) on macOS.

## Troubleshooting

- **Phone never detected:** check it is paired, Bluetooth is on, and `make test` says `present`
  with the phone next to the computer.
- **macOS, works in a terminal but not as a service:** Bluetooth permission is granted per program.
  Check `make logs` for permission errors and allow Bluetooth access in System Settings > Privacy &
  Security.
- **macOS, screen sleeps but is not locked:** the `pmset` fallback only locks if System Settings >
  Lock Screen requires a password immediately.
- **Linux, nothing happens on lock:** run `loginctl lock-session` by hand. Minimal window managers
  need a locker such as `xss-lock` or `swayidle` listening for the signal.
- **`make install` fails with "Domain does not support specified action" (macOS):** you ran make with
  `sudo`. Remove the files it created as root and run it as your normal user.
- **No locking while testing:** you may have left `--dry-run` on.

## Limitations

- This is a convenience, not a security boundary. If you leave your phone at the computer and walk
  away, the screen stays unlocked. Keep your normal screen-lock timeout as well.
- Classic Bluetooth paging can use a little phone battery. Increase `--interval` if that matters.
- A phone with Bluetooth switched off, or one that stops answering pages while idle, counts as absent.

## License

Copyright (C) 2026 <your name>

btlock is free software, released under the
[GNU General Public License, version 3](https://www.gnu.org/licenses/gpl-3.0.html) or (at your
option) any later version. See the [`LICENSE`](LICENSE) file for the full text. There is no warranty.
