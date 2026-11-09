#!/bin/bash
# =============================================================================
# OV5647 High-FPS (120-190 FPS) Kernel Driver Build & Install Script
# Adds hardware mode: 320x240 @ 190.95 FPS with runtime fast_crop sysfs parameter
# =============================================================================
set -e

[ "$(id -u)" -ne 0 ] && { echo "Hata: Bu script root (sudo) yetkisiyle çalıştırılmalıdır."; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SRC_DIR="$REPO_DIR/kernel/ov5647"

if [ ! -d "$SRC_DIR" ]; then
    echo "Hata: Kaynak kod dizini bulunamadı: $SRC_DIR"
    exit 1
fi

KVER="$(uname -r)"
echo "[*] Çekirdek başlıkları (linux-headers-$KVER) kontrol ediliyor..."
if [ ! -d "/lib/modules/$KVER/build" ]; then
    echo "[*] Kernel headers kuruluyor..."
    apt-get update -qq
    apt-get install -y -qq "linux-headers-$KVER" || apt-get install -y -qq raspberrypi-kernel-headers
fi

echo "[*] OV5647 yüksek FPS modülü derleniyor..."
cd "$SRC_DIR"
make clean >/dev/null 2>&1 || true
make -C "/lib/modules/$KVER/build" M="$SRC_DIR" modules

if [ ! -f "$SRC_DIR/ov5647.ko" ]; then
    echo "Hata: ov5647.ko derlenemedi!"
    exit 1
fi

MOD_DEST="/lib/modules/$KVER/kernel/drivers/media/i2c"
mkdir -p "$MOD_DEST"

# Mevcut sürücünün yedeğini al
if [ -f "$MOD_DEST/ov5647.ko.xz" ] && [ ! -f "/etc/picam/ov5647.ko.xz.bak" ]; then
    mkdir -p /etc/picam
    cp "$MOD_DEST/ov5647.ko.xz" /etc/picam/ov5647.ko.xz.bak
    echo "[✓] Orijinal sürücü yedeklendi: /etc/picam/ov5647.ko.xz.bak"
fi

echo "[*] Yeni modül sıkıştırılıp kuruluyor..."
rm -f "$MOD_DEST/ov5647.ko"*
xz -z -k -f "$SRC_DIR/ov5647.ko"
cp -f "$SRC_DIR/ov5647.ko.xz" "$MOD_DEST/"
depmod -a

# Sürücüyü yeniden yükle (eğer kullanımda değilse)
if ! lsmod | grep -q ov5647; then
    modprobe ov5647 || true
else
    echo "[i] OV5647 modülü şu an yüklü. Değişikliğin tam devreye girmesi için yeniden başlatma önerilir."
fi

echo "[✓] OV5647 120-190 FPS sürücüsü başarıyla kuruldu!"

