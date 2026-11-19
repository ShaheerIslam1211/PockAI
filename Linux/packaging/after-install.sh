#!/bin/sh
# Use the PockAI layout unless you already have your own tiny-dfr config.
CONFIG=/etc/tiny-dfr/config.toml
if [ ! -f "$CONFIG" ] || grep -q "managed-by: pockai-touchbar" "$CONFIG"; then
	/usr/bin/pockai-touchbar apply pockai || true
else
	echo "PockAI: you have your own $CONFIG — run 'pockai-touchbar apply' to use the PockAI layout."
fi
command -v systemctl >/dev/null 2>&1 && systemctl enable tiny-dfr.service >/dev/null 2>&1 || true
exit 0
