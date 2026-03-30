#!/usr/bin/env bash

# Workaround for nix-shell command unable to get uutils path
# This script can be removed when this is no longer an issue

uu_true() { /usr/bin/uu_true; }
uu_echo() { /usr/bin/uu_echo "$@"; }
