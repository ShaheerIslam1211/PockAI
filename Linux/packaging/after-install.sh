#!/bin/sh
# Use the TouchPlay layout unless you already have your own tiny-dfr config.
CONFIG=/etc/tiny-dfr/config.toml
if [ ! -f "$CONFIG" ] || grep -q "managed-by: touchplay-touchbar" "$CONFIG"; then
	/usr/bin/touchplay-touchbar apply touchplay || true
else
	echo "TouchPlay: you have your own $CONFIG — run 'touchplay-touchbar apply' to use the TouchPlay layout."
fi
command -v systemctl >/dev/null 2>&1 && systemctl enable tiny-dfr.service >/dev/null 2>&1 || true
exit 0
