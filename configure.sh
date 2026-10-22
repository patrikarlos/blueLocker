#!/usr/bin/env bash
# configure.sh - dependency check/installer and interactive setup for btlock.
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
#
# Normally called through make:   make | make configure | make install
#
# Usage: configure.sh check|configure [--mac MAC] [--interval N] [--retry N]
#                                     [--timeout N] [--python PATH]
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
CONF="$HERE/config.mk"
OS="$(uname -s)"

have() { command -v "$1" >/dev/null 2>&1; }
say()  { printf '%s\n' "$*"; }
ok()   { printf '  [ok]      %s\n' "$*"; }
miss() { printf '  [missing] %s\n' "$*"; }
warn() { printf '  [warn]    %s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "Do not run this as root; it uses sudo itself when needed."

cmd="${1:-}"
[ $# -gt 0 ] && shift
MAC_ARG="" INTERVAL_ARG="" RETRY_ARG="" TIMEOUT_ARG="" PYTHON_ARG=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || die "$1 needs a value"
  case "$1" in
    --mac)      MAC_ARG="$2" ;;
    --interval) INTERVAL_ARG="$2" ;;
    --retry)    RETRY_ARG="$2" ;;
    --timeout)  TIMEOUT_ARG="$2" ;;
    --python)   PYTHON_ARG="$2" ;;
    *) die "unknown option: $1" ;;
  esac
  shift 2
done

resolve_python() { PYTHON="${PYTHON_ARG:-$(command -v python3 || true)}"; }
resolve_python

conf_get() {
  sed -nE "s/^$1[[:space:]]*=[[:space:]]*(.*)$/\1/p" "$CONF" 2>/dev/null | tail -1
}

confirm() {
  local a
  [ -t 0 ] || return 1
  read -r -p "$1 [Y/n] " a
  case "$a" in ""|[Yy]*) return 0 ;; *) return 1 ;; esac
}

# ------------------------------------------------------------ dependencies --
check_deps() {
  local bad=0 tools="" t
  say "Checking dependencies ($OS):"

  if [ -n "$PYTHON" ] && [ -x "$PYTHON" ]; then ok "python3: $PYTHON"; else miss "python3"; bad=1; fi

  case "$OS" in
    Linux)
      for t in hcitool l2ping bluetoothctl; do have "$t" && tools="$tools $t"; done
      if [ -n "$tools" ]; then ok "bluetooth tools:$tools"; else miss "bluetooth tools (bluez)"; bad=1; fi
      if [ -n "$tools" ] && ! have hcitool && ! have l2ping; then
        warn "no hcitool/l2ping: the phone is then only seen while it is connected (bluetoothctl info)"
      fi
      if have loginctl || have xdg-screensaver || have gnome-screensaver-command; then
        ok "screen lock command"
      else
        miss "loginctl (systemd) or xdg-screensaver"; bad=1
      fi
      if have systemctl; then ok "systemd (user services)"; else miss "systemctl (systemd)"; bad=1; fi
      ;;
    Darwin)
      if [ -n "$PYTHON" ] && "$PYTHON" -c 'import IOBluetooth' >/dev/null 2>&1; then
        ok "pyobjc IOBluetooth"
      elif have blueutil; then
        ok "blueutil"
      else
        miss "pyobjc-framework-IOBluetooth or blueutil"; bad=1
      fi
      ;;
    *) die "Unsupported OS: $OS" ;;
  esac
  return $bad
}

install_deps() {
  case "$OS" in
    Linux)
      if have apt-get; then
        say "Will run: sudo apt-get update && sudo apt-get install -y python3 bluez"
        confirm "Proceed?" || return 1
        sudo apt-get update && sudo apt-get install -y python3 bluez
      elif have dnf; then
        say "Will run: sudo dnf install -y python3 bluez"
        confirm "Proceed?" || return 1
        sudo dnf install -y python3 bluez
      elif have pacman; then
        say "Will run: sudo pacman -S --needed python bluez bluez-utils bluez-deprecated-tools"
        confirm "Proceed?" || return 1
        sudo pacman -S --needed --noconfirm python bluez bluez-utils bluez-deprecated-tools
      elif have zypper; then
        say "Will run: sudo zypper install -y python3 bluez"
        confirm "Proceed?" || return 1
        sudo zypper install -y python3 bluez
      else
        say "Unknown package manager. Install manually: python3 and bluez (bluetoothctl, hcitool, l2ping)."
        return 1
      fi
      ;;
    Darwin)
      if ! have brew; then
        say "Homebrew was not found. Install it from https://brew.sh and re-run 'make configure',"
        say "or install pyobjc yourself: pip3 install pyobjc-framework-IOBluetooth"
        return 1
      fi
      local pkgs="blueutil"
      [ -n "$PYTHON" ] || pkgs="python $pkgs"
      say "Will run: brew install $pkgs"
      confirm "Proceed?" || return 1
      # shellcheck disable=SC2086
      brew install $pkgs
      ;;
  esac
}

ensure_bt_service() {
  [ "$OS" = Linux ] && have systemctl || return 0
  if ! systemctl is-active --quiet bluetooth 2>/dev/null; then
    warn "the bluetooth service is not running"
    if confirm "Enable and start it (sudo systemctl enable --now bluetooth)?"; then
      sudo systemctl enable --now bluetooth
    fi
  fi
}

# ------------------------------------------------------------ choose phone --
# prints "MAC<TAB>name" lines for paired devices
list_paired() {
  case "$OS" in
    Darwin)
      if have blueutil; then
        blueutil --paired 2>/dev/null | awk '/^address:/ {
          a=$2; sub(/,$/, "", a); n=$0; sub(/.*name: "/, "", n); sub(/".*/, "", n); print a "\t" n }'
      elif [ -n "$PYTHON" ]; then
        "$PYTHON" - <<'EOF' 2>/dev/null
import IOBluetooth
for d in IOBluetooth.IOBluetoothDevice.pairedDevices() or []:
    print("%s\t%s" % (d.addressString(), d.name() or ""))
EOF
      fi
      ;;
    Linux)
      local out
      have bluetoothctl || return 0
      out="$(bluetoothctl devices Paired 2>/dev/null)"
      printf '%s\n' "$out" | grep -q '^Device ' || out="$(bluetoothctl paired-devices 2>/dev/null)"
      printf '%s\n' "$out" | awk '$1=="Device" { m=$2; $1=""; $2=""; sub(/^ +/, ""); print m "\t" $0 }'
      ;;
  esac | awk -F'\t' '$1!="" { gsub("-", ":", $1); print toupper($1) "\t" $2 }'
}

valid_mac() { printf '%s' "$1" | grep -Eiq '^([0-9a-f]{2}[:-]){5}[0-9a-f]{2}$'; }
norm_mac()  { printf '%s' "$1" | tr '[:lower:]-' '[:upper:]:'; }

CHOSEN=""
choose_mac() {
  local cur="$1" devs sel n="" tries=0
  devs="$(list_paired)"
  if [ -n "$devs" ]; then
    say "Paired Bluetooth devices:"
    printf '%s\n' "$devs" | awk -F'\t' '{ printf "  %d) %s  %s\n", NR, $1, $2 }'
    n="$(printf '%s\n' "$devs" | wc -l | tr -d ' ')"
  else
    say "No paired devices found. Pair your phone with this computer first, or type its MAC address."
  fi
  while [ "$tries" -lt 3 ]; do
    tries=$((tries + 1))
    read -r -p "Phone: ${n:+number 1-$n or }MAC address${cur:+ [Enter = $cur]}: " sel
    [ -n "$sel" ] || sel="$cur"
    if [ -n "$n" ] && printf '%s' "$sel" | grep -Eq '^[0-9]+$' && [ "$sel" -ge 1 ] && [ "$sel" -le "$n" ]; then
      sel="$(printf '%s\n' "$devs" | sed -n "${sel}p" | cut -f1)"
    fi
    if valid_mac "$sel"; then
      CHOSEN="$(norm_mac "$sel")"
      return 0
    fi
    say "That is not a valid choice or MAC address."
  done
  return 1
}

# ------------------------------------------------------------------ steps ---
do_check() {
  check_deps && return 0
  say ""
  say "Run 'make configure' to install what is missing."
  return 1
}

do_configure() {
  local MAC INTERVAL RETRY TIMEOUT cur

  say "btlock setup"
  say ""
  if ! check_deps; then
    say ""
    say "Some dependencies are missing."
    install_deps || die "Could not install the dependencies. Install them manually and re-run 'make configure'."
    resolve_python
    say ""
    check_deps || die "Dependencies are still missing after installation."
  fi
  ensure_bt_service

  say ""
  cur="$(conf_get MAC)"
  if [ -n "$MAC_ARG" ]; then
    valid_mac "$MAC_ARG" || die "'$MAC_ARG' is not a valid Bluetooth address"
    MAC="$(norm_mac "$MAC_ARG")"
  else
    [ -t 0 ] || die "No terminal to ask on. Pass the phone explicitly: make configure MAC=AA:BB:CC:DD:EE:FF"
    choose_mac "$cur" || die "No valid phone selected."
    MAC="$CHOSEN"
  fi

  INTERVAL="${INTERVAL_ARG:-$(conf_get INTERVAL)}"; INTERVAL="${INTERVAL:-30}"
  RETRY="${RETRY_ARG:-$(conf_get RETRY)}";          RETRY="${RETRY:-15}"
  TIMEOUT="${TIMEOUT_ARG:-$(conf_get TIMEOUT)}";    TIMEOUT="${TIMEOUT:-8}"

  {
    echo "# Generated by 'make configure' - rerun it (or edit this file) to change."
    echo "MAC      = $MAC"
    echo "INTERVAL = $INTERVAL"
    echo "RETRY    = $RETRY"
    echo "TIMEOUT  = $TIMEOUT"
    echo "PYTHON   = $PYTHON"
  } > "$CONF"
  say ""
  say "Wrote $CONF"

  say ""
  say "Testing whether the phone answers (Bluetooth on, phone nearby)..."
  if "$PYTHON" "$HERE/btlock.py" "$MAC" --once; then
    ok "phone detected"
  else
    warn "phone not detected. Check that it is paired, Bluetooth is on and it is in range."
    [ "$OS" = Darwin ] && warn "On macOS, allow Bluetooth access for your terminal if a prompt appeared."
  fi

  say ""
  say "Done. Next: make install"
}

case "$cmd" in
  check)     do_check ;;
  configure) do_configure ;;
  *)         die "usage: $0 check|configure [--mac MAC] [--interval N] [--retry N] [--timeout N] [--python PATH]" ;;
esac
