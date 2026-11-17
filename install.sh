#!/bin/bash
# =============================================================================
# Pi Zero UVC Camera - Otomatik / Tek Komutla Kurulum Betiği (Open Source)
# =============================================================================
# Kullanım Yolları:
#   1. Git ile Klonlayıp Çalıştırma (Önerilen):
#      git clone https://github.com/Kagawashi/Pi-Zero-UVC-Webcam.git
#      cd Pi-Zero-UVC-Webcam && sudo bash install.sh
#
#   2. Tek Satırda Online Kurulum:
#      curl -fsSL https://raw.githubusercontent.com/Kagawashi/Pi-Zero-UVC-Webcam/main/install.sh | sudo bash
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${BLUE}[i]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }

echo ""
echo -e "${CYAN}========================================================${NC}"
echo -e "${CYAN}  📷 Pi Zero UVC Camera - Açık Kaynak Kurulumu          ${NC}"
echo -e "${CYAN}  Pupil Labs UVC & Standart Web Kamera Dönüştürücü     ${NC}"
echo -e "${CYAN}========================================================${NC}"
echo ""

# Root yetkisi kontrolü
[ "$(id -u)" -ne 0 ] && error "Bu script root olarak çalıştırılmalı: sudo bash install.sh"

# Script çalışma dizini tespiti
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_URL="${REPO_URL:-https://github.com/Kagawashi/Pi-Zero-UVC-Webcam.git}"

# Eğer curl borusuyla tek başına çalıştırılmışsa veya yerel alt klasörler eksikse repo klonla
if [ ! -f "$SCRIPT_DIR/scripts/setup-gadget.sh" ]; then
    info "Proje kaynak dosyaları yerel dizinde bulunamadı. GitHub üzerinden indiriliyor..."
    TARGET_DIR="/home/pi/Pi-Zero-UVC-Webcam"
    if [ ! -d "$TARGET_DIR" ]; then
        which git >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq git; }
        git clone "$REPO_URL" "$TARGET_DIR" || error "Depo indirilemedi: $REPO_URL"
    fi
    SCRIPT_DIR="$TARGET_DIR"
    cd "$SCRIPT_DIR"
    success "Proje dosyaları hazırlandı: $SCRIPT_DIR"
fi

# Satır sonu uyumluluğu (Windows CRLF aktarımına karşı)
find "$SCRIPT_DIR/scripts" "$SCRIPT_DIR/services" "$SCRIPT_DIR/web" -type f -exec sed -i 's/\r$//' {} + 2>/dev/null || true

# Pi Zero / Raspberry Pi donanım kontrolü
if ! grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null && ! grep -q "Raspberry Pi" /proc/device-tree/model 2>/dev/null; then
    warn "Raspberry Pi donanımı tespit edilemedi, genel Linux olarak devam ediliyor..."
fi

# =============================================================================
# 1. Sistem Paketleri ve Bağımlılıklar
# =============================================================================
info "1/7 - Gerekli paketler ve derleme araçları kuruluyor..."

apt-get update
apt-get install -y \
    git \
    meson \
    ninja-build \
    pkg-config \
    libcamera-dev \
    libjpeg-dev \
    libevent-dev \
    python3-venv \
    python3-pip \
    v4l-utils \
    jq \
    xz-utils \
    build-essential

# Kernel modülü derleme için başlık dosyaları (Kernel Headers)
KVER="$(uname -r)"
if [ ! -d "/lib/modules/$KVER/build" ]; then
    info "Kernel başlıkları (linux-headers-$KVER) kontrol ediliyor..."
    apt-get install -y "linux-headers-$KVER" 2>/dev/null || apt-get install -y raspberrypi-kernel-headers 2>/dev/null || true
fi

success "Bağımlılıklar başarıyla kuruldu."

# =============================================================================
# 2. Boot ve Kernel Modülleri Konfigürasyonu
# =============================================================================
info "2/7 - Boot ve USB Gadget çekirdek yapılandırması ayarlanıyor..."

# Raspberry Pi OS Bookworm (/boot/firmware/) vs Bullseye (/boot/) tespiti
if [ -f "/boot/firmware/config.txt" ] || [ -d "/boot/firmware" ]; then
    CONFIG_TXT="/boot/firmware/config.txt"
    CMDLINE="/boot/firmware/cmdline.txt"
else
    CONFIG_TXT="/boot/config.txt"
    CMDLINE="/boot/cmdline.txt"
fi

# dwc2 USB OTG Peripheral Overlay
if ! grep -q "dtoverlay=dwc2" "$CONFIG_TXT"; then
    echo "" >> "$CONFIG_TXT"
    echo "# Pi Zero UVC Camera - USB Gadget Mode" >> "$CONFIG_TXT"
    echo "dtoverlay=dwc2,dr_mode=peripheral" >> "$CONFIG_TXT"
    success "dwc2 USB Gadget overlay eklendi → $CONFIG_TXT"
else
    info "dwc2 overlay zaten mevcut."
fi

# VideoCore IV Hardware MJPEG Encode GPU Memory (minimum 128MB)
if grep -q "^gpu_mem=" "$CONFIG_TXT"; then
    sed -i 's/^gpu_mem=.*/gpu_mem=128/' "$CONFIG_TXT"
    success "gpu_mem=128 güncellendi → $CONFIG_TXT"
elif ! grep -q "gpu_mem=128" "$CONFIG_TXT"; then
    echo "gpu_mem=128" >> "$CONFIG_TXT"
    success "gpu_mem=128 eklendi → $CONFIG_TXT"
else
    info "gpu_mem=128 zaten mevcut."
fi

# Kamera Desteği: camera_auto_detect ve OV5647 desteği
if ! grep -q "camera_auto_detect=" "$CONFIG_TXT"; then
    echo "camera_auto_detect=1" >> "$CONFIG_TXT"
    success "camera_auto_detect=1 eklendi → $CONFIG_TXT"
fi

if ! grep -q "dtoverlay=ov5647" "$CONFIG_TXT"; then
    echo "dtoverlay=ov5647" >> "$CONFIG_TXT"
    success "OV5647 kamera sensör overlay'i eklendi → $CONFIG_TXT"
else
    info "OV5647 kamera overlay zaten mevcut."
fi

# cmdline.txt - modules-load kontrolü
if [ ! -f "$CMDLINE" ] && [ -f "/boot/cmdline.txt" ]; then
    CMDLINE="/boot/cmdline.txt"
fi

if ! grep -q "modules-load=dwc2,libcomposite" "$CMDLINE"; then
    # Tek satır kuralını koruyarak satır sonuna ekle
    sed -i 's/$/ modules-load=dwc2,libcomposite/' "$CMDLINE"
    success "dwc2 ve libcomposite modülleri eklendi → $CMDLINE"
else
    info "cmdline.txt modül parametresi zaten mevcut."
fi

# /etc/modules kalıcı modül yükleme
grep -qFx "dwc2" /etc/modules 2>/dev/null || echo "dwc2" >> /etc/modules
grep -qFx "libcomposite" /etc/modules 2>/dev/null || echo "libcomposite" >> /etc/modules
grep -qFx "usb_f_rndis" /etc/modules 2>/dev/null || echo "usb_f_rndis" >> /etc/modules

# Modülleri anında yüklemeyi dene
modprobe libcomposite 2>/dev/null || true
modprobe dwc2 2>/dev/null || true
modprobe usb_f_rndis 2>/dev/null || true

# =============================================================================
# 3. uvc-gadget Derleme ve Kurulumu (VideoCore IV GPU Donanım JPEG + DMABUF)
# =============================================================================
info "3/7 - uvc-gadget (VideoCore IV GPU V4L2 M2M + Zero-Copy DMABUF) derleniyor..."

UVC_BUILD_DIR="/tmp/uvc-gadget-build"
rm -rf "$UVC_BUILD_DIR"

if [ -d "$SCRIPT_DIR/uvc-gadget" ]; then
    info "Paket içindeki GPU donanım hızlandırmalı uvc-gadget kaynak kodları kullanılıyor..."
    cp -r "$SCRIPT_DIR/uvc-gadget" "$UVC_BUILD_DIR"
else
    info "uvc-gadget deposu indiriliyor..."
    git clone --depth=1 https://gitlab.freedesktop.org/camera/uvc-gadget.git "$UVC_BUILD_DIR" || {
        error "uvc-gadget git clone başarısız oldu! İnternet bağlantınızı kontrol edin."
    }
fi

cd "$UVC_BUILD_DIR"
rm -rf build
meson setup build --buildtype=release || { error "meson setup build başarısız oldu!"; }
ninja -C build || { error "ninja -C build derleme başarısız oldu!"; }
ninja -C build install || { error "ninja -C build install kurulumu başarısız oldu!"; }
ldconfig
sync

cd "$SCRIPT_DIR"
rm -rf "$UVC_BUILD_DIR"

if command -v uvc-gadget &>/dev/null; then
    success "uvc-gadget başarıyla kuruldu: $(which uvc-gadget)"
else
    error "uvc-gadget kurulumu doğrulanamadı!"
fi

# =============================================================================
# 3b. OV5647 Yüksek FPS (120-190 FPS) Çekirdek Sürücüsü Kurulumu
# =============================================================================
if [ -d "$SCRIPT_DIR/kernel/ov5647" ] && [ -f "$SCRIPT_DIR/scripts/build-ov5647-driver.sh" ]; then
    info "OV5647 120-190 FPS donanımsal merkez kırpma modülü derlenip kuruluyor..."
    bash "$SCRIPT_DIR/scripts/build-ov5647-driver.sh" || warn "OV5647 yüksek FPS modülü derlenemedi, standart çekirdek sürücüsüyle devam ediliyor."
fi

# =============================================================================
# 4. Sistem Betikleri Kurulumu
# =============================================================================
info "4/7 - Sistem başlatma ve ConfigFS betikleri kopyalanıyor..."

install -m 755 "$SCRIPT_DIR/scripts/setup-gadget.sh" /usr/local/bin/setup-gadget.sh
install -m 755 "$SCRIPT_DIR/scripts/start-uvc.sh" /usr/local/bin/start-uvc.sh
if [ -f "$SCRIPT_DIR/scripts/build-ov5647-driver.sh" ]; then
    install -m 755 "$SCRIPT_DIR/scripts/build-ov5647-driver.sh" /usr/local/bin/build-ov5647-driver.sh
fi
success "Sistem betikleri → /usr/local/bin/ dizinine kuruldu."

# =============================================================================
# 5. Web Kontrol Paneli Kurulumu (:8080)
# =============================================================================
info "5/7 - Web kontrol paneli kuruluyor..."

WEB_DIR="/opt/picam-web"
mkdir -p "$WEB_DIR/templates"

cp "$SCRIPT_DIR/web/app.py"               "$WEB_DIR/app.py"
cp "$SCRIPT_DIR/web/templates/index.html"  "$WEB_DIR/templates/index.html"
cp "$SCRIPT_DIR/web/requirements.txt"      "$WEB_DIR/requirements.txt"

if [ ! -d "$WEB_DIR/venv" ]; then
    python3 -m venv "$WEB_DIR/venv"
fi
"$WEB_DIR/venv/bin/pip" install -q -r "$WEB_DIR/requirements.txt"

success "Web kontrol paneli kuruldu → $WEB_DIR"

# =============================================================================
# 6. Varsayılan Konfigürasyon
# =============================================================================
info "6/7 - Kamera ve sistem konfigürasyonları oluşturuluyor..."

DEFAULT_ENV="/etc/default/picam-uvc"
if [ ! -f "$DEFAULT_ENV" ]; then
    cat > "$DEFAULT_ENV" << 'ENVEOF'
# Pi Zero UVC Camera Default Configuration
ROLE="eye0"
SENSOR="ov5647"
FPS="90"
WIDTH="640"
HEIGHT="480"
ALLOW_TEST_PATTERN="true"
ENVEOF
    chmod 644 "$DEFAULT_ENV"
    success "Varsayılan profil dosyası oluşturuldu → $DEFAULT_ENV"
fi

mkdir -p /etc/picam
if [ ! -f /etc/picam/config.json ]; then
    cat > /etc/picam/config.json << 'JSONEOF'
{
  "role": "eye0",
  "sensor": "ov5647",
  "fps": 90,
  "width": 640,
  "height": 480,
  "fast_crop": {
    "192x192": false,
    "320x240": false,
    "400x400": false,
    "640x480": false,
    "800x600": false,
    "1280x720": false
  },
  "hflip": false,
  "vflip": false,
  "brightness": 50,
  "contrast": 50,
  "saturation": 50,
  "sharpness": 50,
  "auto_exposure": true,
  "exposure_value": 5000,
  "analogue_gain": 8.0,
  "spatial_denoise": true,
  "awb_mode": "auto"
}
JSONEOF
    chmod 644 /etc/picam/config.json
    success "JSON ayar dosyası oluşturuldu → /etc/picam/config.json"
fi

# USB Ethernet (RNDIS) Otomatik Ağ Profili (Wi-Fi olmadan USB'den direkt SSH için)
if command -v nmcli &>/dev/null; then
    if ! nmcli connection show "USB-Ethernet" &>/dev/null; then
        nmcli connection add type ethernet con-name "USB-Ethernet" ifname usb0 ipv4.method link-local connection.autoconnect yes 2>/dev/null || true
        success "USB Ethernet (usb0 link-local) ağ profili eklendi"
    fi
fi

# =============================================================================
# 7. Systemd Servisleri
# =============================================================================
info "7/7 - Systemd servisleri yapılandırılıyor..."

install -m 644 "$SCRIPT_DIR/services/uvc-gadget.service" /etc/systemd/system/uvc-gadget.service
install -m 644 "$SCRIPT_DIR/services/picam-web.service"  /etc/systemd/system/picam-web.service

systemctl daemon-reload
systemctl enable uvc-gadget.service
systemctl enable picam-web.service

success "uvc-gadget ve picam-web servisleri otomatik başlatmaya ayarlandı."

# Web servisini başlat
systemctl start picam-web.service || warn "Web servisi başlatılamadı (yeniden başlatma sonrası aktifleşecek)"

# =============================================================================
# Kurulum Özeti ve Yeniden Başlatma Sorgusu
# =============================================================================
echo ""
echo -e "${GREEN}========================================================${NC}"
echo -e "${GREEN}  ✓ KURULUM BAŞARIYLA TAMAMLANDI!                      ${NC}"
echo -e "${GREEN}========================================================${NC}"
echo ""
echo "  Kurulan Bileşenler:"
echo "  ├── UVC Gadget Çekirdeği : $(which uvc-gadget) (VideoCore IV GPU DMABUF + Spatial Denoise Release)"
echo "  ├── OV5647 Yüksek FPS    : 120-190 FPS Modülü (Varsayılan Full FOV + İsteğe Bağlı Fast-Crop)"
echo "  ├── ConfigFS Betiği      : /usr/local/bin/setup-gadget.sh (maxpacket=1024, 192p–720p UVC Tanımlayıcıları)"
echo "  ├── Akış Orkestratörü    : /usr/local/bin/start-uvc.sh (Hızlı IPA Tuning & Çözünürlük Yönetimi)"
echo "  ├── Web Arayüzü          : /opt/picam-web/ (Port :8080, GPU Yükü / Spatial Denoise / Gain / Fast-Crop)"
echo "  ├── Kamera Ayarları      : /etc/picam/config.json, rpi_pipeline.yaml, <sensor>_fast.json"
echo "  └── Otomatik Servisler   : uvc-gadget.service, picam-web.service"
echo ""
echo "  Kullanım Adımları:"
echo "  1. Pi Zero'yu USB kablosuyla bilgisayara bağlayın (Ortadaki DATA portu)."
echo "  2. Web Kontrol Paneli : http://$(hostname).local:8080"
echo "  3. Windows tarafında Pupil Capture veya standart kamera uygulamasını açın."
echo ""
echo -e "  ${YELLOW}⚠️  USB Gadget modunun aktifleşmesi için sistemin yeniden başlatılması gerekir.${NC}"
echo ""

# İnteraktif terminalde kullanıcıya doğrudan reboot sor
if [ -t 0 ]; then
    echo -ne "  ${CYAN}Sistemi şimdi yeniden başlatmak istiyor musunuz? [E/h]: ${NC}"
    read -r -n 1 -s REPLY
    echo ""
    case "$REPLY" in
        [hHnN])
            echo -e "  İşlem tamamlandı. Değişiklikleri uygulamak için daha sonra ${YELLOW}sudo reboot${NC} yazın."
            ;;
        *)
            echo -e "  ${GREEN}Sistem yeniden başlatılıyor...${NC}"
            sleep 1
            reboot
            ;;
    esac
else
    echo -e "  Lütfen kurulumu tamamlamak için sistemi yeniden başlatın: ${YELLOW}sudo reboot${NC}"
fi
echo ""
