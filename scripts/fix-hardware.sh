#!/bin/bash
# =============================================================================
# Pi Zero W UVC - Hardware Configuration Fixer (dwc2 OTG + OV5647 Camera)
# Fixes /boot/firmware/config.txt [all] section, /etc/modules, and cmdline.txt
# =============================================================================
set -e

echo "=========================================================="
echo "  Raspberry Pi Zero W - Hardware Config Fixer"
echo "=========================================================="

CONFIG="/boot/firmware/config.txt"
[ -f "$CONFIG" ] || CONFIG="/boot/config.txt"

CMDLINE="/boot/firmware/cmdline.txt"
[ -f "$CMDLINE" ] || CMDLINE="/boot/cmdline.txt"

echo "[1/4] Configuring boot overlays in $CONFIG..."
# Remove any conflicting or duplicate lines
sed -i '/dtoverlay=dwc2/d' "$CONFIG"
sed -i '/dtoverlay=ov5647/d' "$CONFIG"
sed -i '/camera_auto_detect/d' "$CONFIG"

# Append clean [all] block
cat << 'EOF' >> "$CONFIG"

[all]
dtoverlay=dwc2,dr_mode=peripheral
dtoverlay=ov5647
camera_auto_detect=0
gpu_mem=128
EOF
echo "  -> Added dwc2 (peripheral), ov5647, and gpu_mem=128 under [all]"

echo "[2/4] Configuring persistent kernel modules in /etc/modules..."
grep -qFx "dwc2" /etc/modules 2>/dev/null || echo "dwc2" >> /etc/modules
grep -qFx "libcomposite" /etc/modules 2>/dev/null || echo "libcomposite" >> /etc/modules
echo "  -> /etc/modules configured"

echo "[3/4] Configuring kernel command line in $CMDLINE..."
if ! grep -q "modules-load=dwc2,libcomposite" "$CMDLINE"; then
    sed -i 's/$/ modules-load=dwc2,libcomposite/' "$CMDLINE"
    echo "  -> Appended modules-load=dwc2,libcomposite to $CMDLINE"
else
    echo "  -> modules-load already present in $CMDLINE"
fi

echo "[4/4] Verifying configuration..."
echo "--- Last 12 lines of $CONFIG ---"
tail -n 12 "$CONFIG"
echo "--------------------------------"

echo ""
echo "[✓] Hardware configuration updated successfully!"
echo "[!] A system reboot is REQUIRED for dwc2 and ov5647 overlays to take effect."

