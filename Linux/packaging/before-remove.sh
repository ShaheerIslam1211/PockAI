#!/bin/sh
# deb: "remove"/"purge" = uninstall, "upgrade" = keep. rpm: $1 = 0 means uninstall.
case "$1" in
	remove|purge|0) /usr/bin/pockai-touchbar restore || true ;;
esac
exit 0
