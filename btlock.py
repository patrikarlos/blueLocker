#!/usr/bin/env python3
# btlock - lock the screen when your phone leaves Bluetooth range
# Copyright (C) 2026 <your name>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

"""
btlock - lock the screen when your (paired) phone is no longer reachable over Bluetooth.

Logic:
  every INTERVAL seconds: probe phone
    -> found: all good
    -> missed: wait RETRY_DELAY seconds, probe again
         -> found: all good
         -> missed again: lock the screen (once, until the phone has been seen again)

Linux : uses `hcitool name`, falling back to `l2ping` and `bluetoothctl info`
macOS : uses IOBluetooth via pyobjc (pip install pyobjc-framework-IOBluetooth),
        falling back to `blueutil` (brew install blueutil)

The phone must be PAIRED with this computer and have Bluetooth switched on.
"""

import argparse
import logging
import os
import platform
import re
import shutil
import subprocess
import sys
import time

SYSTEM = platform.system()
log = logging.getLogger("btlock")

# 'make install' replaces this placeholder in the installed copy with the git commit
# the install was made from. When running straight from a checkout it stays as-is
# and the commit is looked up with git instead.
VERSION = "@VERSION@"


def get_version():
    if not VERSION.startswith("@"):
        return VERSION
    try:
        here = os.path.dirname(os.path.abspath(__file__))
        r = subprocess.run(
            ["git", "-C", here, "describe", "--always", "--dirty", "--abbrev=12"],
            capture_output=True, text=True, timeout=5,
        )
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return "unknown"


def run(cmd, timeout):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, (r.stdout + r.stderr).strip()
    except (subprocess.TimeoutExpired, OSError) as e:
        return None, str(e)


# --------------------------------------------------------------------------
# Presence probes
# --------------------------------------------------------------------------
# Longest time to wait for a busy (scanning) adapter before treating it as a miss
HCITOOL_BUSY_WAIT = 12


def probe_linux(mac, timeout):
    tried = False

    if shutil.which("hcitool"):
        tried = True
        # While the adapter is scanning (e.g. a desktop Bluetooth panel is open),
        # some controllers reject the name request at once: empty output in a few
        # ms. That says nothing about the phone. Scans run in bursts of several
        # seconds, so keep retrying until the adapter is free again. A slow
        # failure means the phone really did not answer, so stop there.
        busy_until = time.monotonic() + HCITOOL_BUSY_WAIT
        while True:
            start = time.monotonic()
            rc, out = run(["hcitool", "name", mac], timeout)
            if rc == 0 and out:
                return True
            if time.monotonic() - start >= 1 or time.monotonic() >= busy_until:
                break
            log.debug("hcitool name was rejected instantly (adapter busy?), retrying")
            time.sleep(1)

    if shutil.which("l2ping"):  # needs root / CAP_NET_RAW
        tried = True
        rc, _ = run(["l2ping", "-c", "1", "-t", str(timeout), mac], timeout + 2)
        if rc == 0:
            return True

    if shutil.which("bluetoothctl"):
        tried = True
        rc, out = run(["bluetoothctl", "info", mac], 5)
        if rc == 0 and re.search(r"Connected:\s+yes", out):
            return True

    if not tried:
        raise RuntimeError("Need one of: hcitool, l2ping, bluetoothctl (package 'bluez')")
    return False


def probe_macos(mac, timeout):
    try:
        import IOBluetooth  # pyobjc-framework-IOBluetooth

        dev = IOBluetooth.IOBluetoothDevice.deviceWithAddressString_(mac.replace(":", "-"))
        if dev is None:
            raise RuntimeError(f"Device {mac} is not known to macOS - pair it first")
        if dev.isConnected():
            return True
        # Opening a baseband connection pages the phone = a real "ping"
        if dev.openConnection() == 0:
            dev.closeConnection()
            return True
        return False
    except ImportError:
        pass

    if shutil.which("blueutil"):
        rc, out = run(["blueutil", "--is-connected", mac], 5)
        if rc == 0 and out.strip() == "1":
            return True
        rc, _ = run(["blueutil", "--connect", mac], timeout)
        if rc == 0:
            run(["blueutil", "--disconnect", mac], 5)
            return True
        return False

    raise RuntimeError(
        "Install pyobjc-framework-IOBluetooth (pip) or blueutil (brew) for macOS support"
    )


def probe(mac, timeout):
    return probe_macos(mac, timeout) if SYSTEM == "Darwin" else probe_linux(mac, timeout)


# --------------------------------------------------------------------------
# Screen locking
# --------------------------------------------------------------------------
def lock_screen():
    if SYSTEM == "Darwin":
        try:
            import ctypes

            lib = ctypes.CDLL(
                "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
            )
            lib.SACLockScreenImmediate()
            return
        except Exception as e:  # noqa: BLE001
            log.debug("SACLockScreenImmediate failed: %s", e)
        # Needs System Settings > Lock Screen > "Require password: immediately"
        run(["pmset", "displaysleepnow"], 10)
        return

    for cmd in (
        ["omarchy-system-lock"],  # Omarchy: lock-session does nothing there
        ["loginctl", "lock-session"],
        ["xdg-screensaver", "lock"],
        ["gnome-screensaver-command", "-l"],
    ):
        if shutil.which(cmd[0]):
            rc, _ = run(cmd, 10)
            if rc == 0:
                return
    log.error("No working screen-lock command found")


# --------------------------------------------------------------------------
# Main loop
# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="Lock screen when a paired phone goes away")
    ap.add_argument("mac", help="Bluetooth MAC address of the phone, e.g. AA:BB:CC:DD:EE:FF")
    ap.add_argument("--interval", type=int, default=30, help="seconds between checks (30)")
    ap.add_argument("--retry-delay", type=int, default=15, help="seconds before re-check after a miss (15)")
    ap.add_argument("--timeout", type=int, default=8, help="per-probe timeout in seconds (8)")
    ap.add_argument("--dry-run", action="store_true", help="log instead of locking")
    ap.add_argument("--once", action="store_true", help="probe once, print result and exit")
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--version", action="version", version="btlock %s" % get_version(),
                    help="show the git commit this was built from and exit")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )
    mac = args.mac.upper()

    if args.once:
        present = probe(mac, args.timeout)
        print("present" if present else "absent")
        sys.exit(0 if present else 1)

    locked = False
    log.info("btlock %s", get_version())
    log.info("Watching %s (every %ss, retry after %ss)", mac, args.interval, args.retry_delay)

    try:
        while True:
            present = probe(mac, args.timeout)
            if not present:
                log.info("Phone not detected, re-checking in %ss", args.retry_delay)
                time.sleep(args.retry_delay)
                present = probe(mac, args.timeout)
                if present:
                    log.info("Phone found again on retry")

            if present:
                if locked:
                    log.info("Phone is back")
                locked = False
                log.debug("Phone present")
            elif not locked:
                log.info("Phone still missing - locking screen")
                if not args.dry_run:
                    lock_screen()
                locked = True  # don't re-lock until phone has been seen again

            time.sleep(args.interval)
    except KeyboardInterrupt:
        log.info("Bye")


if __name__ == "__main__":
    main()
