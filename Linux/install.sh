#!/usr/bin/env bash
# PockAI for Linux on Touch Bar Macs — one-step installer.
# Works on Fedora, Ubuntu, Linux Mint, Debian, Pop!_OS, Arch/EndeavourOS/Manjaro.
#
#   sudo ./install.sh            install tiny-dfr (if needed) + PockAI layouts, apply the PockAI layout
#   sudo ./install.sh minimal    …and use the "minimal" layout instead
#   sudo ./install.sh --uninstall
#
# Run it from the folder you extracted (it uses the files next to it).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARE=/usr/share/pockai-touchbar
BIN=/usr/bin/pockai-touchbar
LAYOUT="${1:-pockai}"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || exec sudo -E bash "$0" "$@"

if [ "${1:-}" = "--uninstall" ]; then
	[ -x "$BIN" ] && "$BIN" restore || true
	rm -rf "$SHARE" "$BIN"
	say "PockAI layouts removed. (tiny-dfr itself was left installed.)"
	exit 0
fi

[ -f "$HERE/pockai-touchbar" ] && [ -d "$HERE/layouts" ] || die "run this from the extracted PockAI Linux folder"

. /etc/os-release 2>/dev/null || true
say "PockAI for Linux — ${PRETTY_NAME:-unknown distro}"

product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
case "$product" in
	MacBookPro13,2|MacBookPro13,3|MacBookPro14,2|MacBookPro14,3) say "Mac: $product (T1 Touch Bar)"
		warn "T1 Macs (2016–2017) need the apple-ib-tb / applespi drivers; tiny-dfr support there is experimental." ;;
	MacBookPro*) say "Mac: $product" ;;
	*) warn "This doesn't look like a Touch Bar MacBook Pro ($product). Installing anyway." ;;
esac

install_tiny_dfr() {
	if command -v tiny-dfr >/dev/null 2>&1 || [ -x /usr/bin/tiny-dfr ]; then
		say "✓ tiny-dfr already installed"; return 0
	fi
	if command -v dnf >/dev/null 2>&1; then
		say "Installing tiny-dfr (dnf)…"
		dnf install -y tiny-dfr || dnf install -y rust-tiny-dfr
	elif command -v apt-get >/dev/null 2>&1; then
		say "Installing tiny-dfr (apt)…"
		apt-get update -qq || true
		if apt-cache show tiny-dfr >/dev/null 2>&1; then
			DEBIAN_FRONTEND=noninteractive apt-get install -y tiny-dfr
		else
			warn "tiny-dfr isn't in your distro's repositories (Ubuntu 24.04 / Linux Mint 22 and older)."
			warn "Add the t2linux Ubuntu repository first — instructions: https://github.com/AdityaGarg8/t2-ubuntu-repo"
			warn "then run:  sudo apt install tiny-dfr   and this installer again."
			return 1
		fi
	elif command -v pacman >/dev/null 2>&1; then
		say "Installing tiny-dfr (pacman)…"
		pacman -Sy --noconfirm tiny-dfr
	elif command -v zypper >/dev/null 2>&1; then
		zypper --non-interactive install tiny-dfr || return 1
	else
		warn "Unknown package manager. Build tiny-dfr from https://github.com/AsahiLinux/tiny-dfr"
		return 1
	fi
}

tiny_ok=1
install_tiny_dfr || tiny_ok=0

say "Installing PockAI layouts…"
install -d "$SHARE/layouts"
install -m 0644 "$HERE"/layouts/*.toml "$SHARE/layouts/"
install -m 0755 "$HERE/pockai-touchbar" "$BIN"

if command -v systemctl >/dev/null 2>&1 && [ "$tiny_ok" = 1 ]; then
	systemctl enable tiny-dfr.service >/dev/null 2>&1 || true
fi

"$BIN" apply "$LAYOUT"
echo
"$BIN" status || true
echo
say "Done. Change layout any time:  pockai-touchbar layouts  /  pockai-touchbar apply minimal"
if ! compgen -G '/sys/bus/usb/drivers/appletbdrm/*:*' >/dev/null && [ ! -e /dev/tiny_dfr_display ]; then
	warn "The Touch Bar display driver isn't loaded yet. On T2 Macs install the T2 kernel from https://wiki.t2linux.org, then reboot."
fi
