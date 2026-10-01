#!/bin/zsh
# QuotaDesk installer.
#
#   Install or update:  curl -fsSL https://raw.githubusercontent.com/filmpaisan/QuotaDesk/main/install.sh | zsh
#   From a clone:       ./install.sh
#   Uninstall:          ./install.sh --uninstall   (or: curl … | zsh -s -- --uninstall)
#
# Builds from source on this Mac, so Gatekeeper never blocks the app and no
# prebuilt binary has to be trusted. Nothing runs with sudo.
set -eu

REPO="filmpaisan/QuotaDesk"
APP="$HOME/Applications/QuotaDesk.app"

say()  { print -P "%F{cyan}==>%f $*"; }
fail() { print -P "%F{red}Error:%f $*" >&2; exit 1; }

if [[ "${1:-}" == "--uninstall" ]]; then
  say "Removing QuotaDesk…"
  pkill -x QuotaDesk 2>/dev/null || true
  rm -rf "$APP"
  print "Removed $APP"
  print "Settings remain in UserDefaults; to clear them too: defaults delete local.quotadesk"
  exit 0
fi

[[ "$(uname -s)" == "Darwin" ]] || fail "QuotaDesk runs on macOS only."
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 14 )) || fail "macOS 14 or later is required (this Mac has $(sw_vers -productVersion))."

if ! xcrun --find swiftc >/dev/null 2>&1; then
  say "The Xcode Command Line Tools are needed to build QuotaDesk. Opening the installer…"
  xcode-select --install 2>/dev/null || true
  fail "Run this command again after the Command Line Tools finish installing."
fi

# Use this checkout when run as ./install.sh; otherwise download the latest source.
if [[ -n "${ZSH_SCRIPT:-}" && -f "${ZSH_SCRIPT:A:h}/QuotaDesk.swift" ]]; then
  src="${ZSH_SCRIPT:A:h}"
else
  src="$(mktemp -d)"
  trap 'rm -rf "$src"' EXIT
  say "Downloading the latest QuotaDesk source…"
  curl -fsSL "https://github.com/$REPO/archive/refs/heads/main.tar.gz" | tar -xz -C "$src" --strip-components 1
fi

say "Building (the first build can take a minute or two)…"
pkill -x QuotaDesk 2>/dev/null || true
# Keep the compiler's output out of the way unless the build actually fails.
log="$(mktemp)"
if ! zsh "$src/build.sh" >"$log" 2>&1; then
  cat "$log" >&2
  rm -f "$log"
  fail "The build failed (details above). Please open an issue: https://github.com/$REPO/issues"
fi
rm -f "$log"

say "Starting QuotaDesk…"
open "$APP"
print
print -P "%F{green}✓ Installed%f $APP"
print "  Open ⋯ → Settings & accounts… on the widget to sign in to Codex or Claude."
print "  Run this command again any time to update."
