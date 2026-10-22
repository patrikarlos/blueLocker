# Makefile - check, configure and install btlock as a per-user background service
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
#
#   make                      check that the dependencies are present
#   make configure            install missing dependencies, pick your phone, write config.mk
#   make install              install + start the service (uses config.mk)
#   make uninstall            stop + remove the service (config.mk is kept)
#   make status | logs | start | stop | restart | test
#
# Everything can still be given on the command line, e.g.
#   make install MAC=AA:BB:CC:DD:EE:FF INTERVAL=60 RETRY=20 PYTHON=/path/to/python3
#
# It is installed as a *user* service (not system-wide) on purpose: locking the
# screen needs access to your login session. Run make as your normal user,
# configure.sh asks for sudo itself when it has to install packages.
# Works with GNU make 3.81+ (the version shipped with macOS).

ifeq ($(shell id -u),0)
$(error Do not run this with sudo/as root: btlock is a per-user service. Run it as your normal user)
endif

# Written by 'make configure'; values given on the command line still win.
-include config.mk

MAC      ?=
INTERVAL ?= 30
RETRY    ?= 15
TIMEOUT  ?= 8
PYTHON   ?= $(shell command -v python3)

UNAME   := $(shell uname -s)
BIN_DIR := $(HOME)/.local/bin
BIN     := $(BIN_DIR)/btlock

# The git commit this install is built from; baked into the installed script
# so that 'btlock --version' works after it has been copied out of the checkout.
VERSION := $(shell git describe --always --dirty --abbrev=12 2>/dev/null || echo unknown)

ARGS = $(MAC) --interval $(INTERVAL) --retry-delay $(RETRY) --timeout $(TIMEOUT)

# Options passed on to configure.sh: only the ones given on the make command line
CONF_ARGS = $(foreach v,MAC INTERVAL RETRY TIMEOUT PYTHON,$(if $(filter command line,$(origin $(v))),--$(shell echo $(v) | tr A-Z a-z) '$($(v))'))

.PHONY: all check configure install uninstall start stop restart status logs test \
        check-mac install-bin install-service

all: check
	@echo ""
	@echo "Next: 'make configure' (first time), then 'make install'"

check:
	@bash ./configure.sh check --python '$(PYTHON)'

configure:
	@bash ./configure.sh configure $(CONF_ARGS)

check-mac:
	@test -n "$(MAC)" || { echo "No phone configured. Run 'make configure' first (or: make install MAC=AA:BB:CC:DD:EE:FF)"; exit 1; }
	@echo "$(MAC)" | grep -Eiq '^([0-9a-f]{2}[:-]){5}[0-9a-f]{2}$$' || { echo "'$(MAC)' is not a valid Bluetooth address"; exit 1; }
	@test -n "$(PYTHON)" || { echo "python3 not found"; exit 1; }

install-bin:
	install -d $(BIN_DIR)
	sed 's|@VERSION@|$(VERSION)|' btlock.py > $(BIN).tmp
	chmod 755 $(BIN).tmp
	mv $(BIN).tmp $(BIN)
	@echo "Installed btlock $(VERSION)"

install: check check-mac install-bin install-service
	@echo "btlock installed and started. Check it with: make status / make logs"

test: check-mac
	$(PYTHON) btlock.py $(MAC) --once

# ---------------------------------------------------------------- Linux ----
ifeq ($(UNAME),Linux)

UNIT_DIR := $(HOME)/.config/systemd/user
UNIT     := $(UNIT_DIR)/btlock.service

install-service:
	install -d $(UNIT_DIR)
	printf '%s\n' \
	  '[Unit]' \
	  'Description=Lock screen when phone is out of Bluetooth range (btlock)' \
	  '' \
	  '[Service]' \
	  'ExecStart=$(PYTHON) $(BIN) $(ARGS)' \
	  'Restart=on-failure' \
	  'RestartSec=10' \
	  '' \
	  '[Install]' \
	  'WantedBy=default.target' > $(UNIT)
	systemctl --user daemon-reload
	systemctl --user enable --now btlock.service
	systemctl --user restart btlock.service

uninstall:
	-systemctl --user disable --now btlock.service
	rm -f $(UNIT) $(BIN)
	systemctl --user daemon-reload

start:
	systemctl --user start btlock.service
stop:
	systemctl --user stop btlock.service
restart:
	systemctl --user restart btlock.service
status:
	systemctl --user status btlock.service --no-pager
logs:
	journalctl --user -u btlock.service -f

# ---------------------------------------------------------------- macOS ----
else ifeq ($(UNAME),Darwin)

LABEL  := com.btlock
PLIST  := $(HOME)/Library/LaunchAgents/$(LABEL).plist
LOG    := $(HOME)/Library/Logs/btlock.log
USERID := $(shell id -u)

install-service:
	install -d $(HOME)/Library/LaunchAgents
	printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '  <key>Label</key><string>$(LABEL)</string>' \
	  '  <key>ProgramArguments</key><array>' \
	  '    <string>$(PYTHON)</string>' \
	  '    <string>$(BIN)</string>' \
	  '    <string>$(MAC)</string>' \
	  '    <string>--interval</string><string>$(INTERVAL)</string>' \
	  '    <string>--retry-delay</string><string>$(RETRY)</string>' \
	  '    <string>--timeout</string><string>$(TIMEOUT)</string>' \
	  '  </array>' \
	  '  <key>EnvironmentVariables</key><dict>' \
	  '    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>' \
	  '  </dict>' \
	  '  <key>RunAtLoad</key><true/>' \
	  '  <key>KeepAlive</key><true/>' \
	  '  <key>ProcessType</key><string>Background</string>' \
	  '  <key>StandardOutPath</key><string>$(LOG)</string>' \
	  '  <key>StandardErrorPath</key><string>$(LOG)</string>' \
	  '</dict></plist>' > $(PLIST)
	-launchctl bootout gui/$(USERID)/$(LABEL) 2>/dev/null
	launchctl bootstrap gui/$(USERID) $(PLIST)

uninstall:
	-launchctl bootout gui/$(USERID)/$(LABEL)
	rm -f $(PLIST) $(BIN)

start:
	launchctl bootstrap gui/$(USERID) $(PLIST)
stop:
	launchctl bootout gui/$(USERID)/$(LABEL)
restart:
	launchctl kickstart -k gui/$(USERID)/$(LABEL)
status:
	launchctl print gui/$(USERID)/$(LABEL) | head -25
logs:
	tail -f $(LOG)

else
$(error Unsupported OS: $(UNAME))
endif
