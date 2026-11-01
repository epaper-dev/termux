#!/usr/bin/env bash
# Termux:Boot autostart (optional): keeps the root bridge daemon and the
# Claude Code session running after a device reboot, without attaching.
termux-wake-lock 2>/dev/null
rootbridge daemon-start
rootbridge start --no-attach
