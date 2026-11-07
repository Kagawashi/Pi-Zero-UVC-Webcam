#!/bin/bash
# =============================================================================
# Pi Zero W UVC Gadget - ConfigFS Setup Script
# Configures USB Video Class (UVC 1.10) peripheral descriptors for Raspberry Pi
# Zero W (BCM2835 / dwc2 / libcomposite).
# Supports Pupil Labs Pupil Cam1 hardware identities (eye0, eye1, world) and generic.
# =============================================================================
set -e

# ConfigFS Paths (can be overridden via environment variables for testing)
CONFIGFS_ROOT="${CONFIGFS_ROOT:-/sys/kernel/config}"
GADGET_NAME="${GADGET_NAME:-pi_uvc}"
GADGET="$CONFIGFS_ROOT/usb_gadget/$GADGET_NAME"
FUNC="$GADGET/functions/uvc.usb0"
CONFIG="$GADGET/configs/c.1"

# -----------------------------------------------------------------------------
# Command-Line Argument Parsing
# Supports:
#   setup-gadget.sh <eye0|eye1|world|generic> <start|stop|restart|status>
#   setup-gadget.sh <start|stop|restart|status> <eye0|eye1|world|generic>
#   setup-gadget.sh --role <eye0|eye1|world|generic> <start|stop|restart|status>
#   setup-gadget.sh --role=<eye0|eye1|world|generic> <start|stop|restart|status>
#   setup-gadget.sh <start|stop|restart|status> (falls back to $PICAM_ROLE or eye0)
ENV_ROLE="${ROLE:-${PICAM_ROLE:-}}"
ROLE=""
ACTION=""

while [ $# -gt 0 ]; do
    CLEAN_ARG=$(echo "$1" | tr -d "'\"")
    case "$CLEAN_ARG" in
        --role)
            shift
            if [ $# -gt 0 ]; then
                ROLE=$(echo "$1" | tr -d "'\"")
            else
                echo "Error: --role requires an argument (eye0|eye1|world|generic)" >&2
                exit 1
            fi
            ;;
        --role=*)
            ROLE="${CLEAN_ARG#--role=}"
            ;;
        eye0|eye1|world|generic)
            ROLE="$CLEAN_ARG"
            ;;
        start|stop|restart|status)
            ACTION="$CLEAN_ARG"
            ;;
        -h|--help)
            echo "Usage: $0 [eye0|eye1|world|generic] [start|stop|restart|status]"
            echo "       $0 --role <eye0|eye1|world|generic> [start|stop|restart|status]"
            echo "Environment variables: PICAM_ROLE (default: eye0)"
            exit 0
            ;;
        *)
            echo "Error: Unknown argument '$1'" >&2
            echo "Usage: $0 [eye0|eye1|world|generic] [start|stop|restart|status]" >&2
            exit 1
            ;;
    esac
    shift
done

# Fallback for ROLE: environment variable $ROLE, $PICAM_ROLE, /etc/default/picam-uvc, or default to eye0
if [ -z "$ROLE" ]; then
    ROLE="${ENV_ROLE:-${PICAM_ROLE:-}}"
fi
if [ -z "$ROLE" ] && [ -f "/etc/default/picam-uvc" ]; then
    ROLE=$(grep -E '^[[:space:]]*ROLE=' /etc/default/picam-uvc 2>/dev/null | tail -n1 | cut -d'=' -f2 | tr -d ' "\r\n')
fi
if [ -z "$ROLE" ]; then
    ROLE="eye0"
fi

# Validate ROLE
case "$ROLE" in
    eye0|eye1|world|generic) ;;
    *)
        echo "Error: Invalid role '$ROLE'. Must be one of: eye0, eye1, world, generic" >&2
        exit 1
        ;;
esac

# Fallback for ACTION: default to start
if [ -z "$ACTION" ]; then
    ACTION="start"
fi

# -----------------------------------------------------------------------------
# Identity Mapping Matrix
# -----------------------------------------------------------------------------
case "$ROLE" in
    eye0)
        VID="0x05a3"
        PID="0x9230"
        PRODUCT="Pupil Cam1 ID0"
        MANUFACTURER="Pupil Labs"
        SERIAL_PREFIX="PZ-EYE0"
        DEFAULT_INTERVAL_480P="111111"  # 90 fps default
        ;;
    eye1)
        VID="0x05a3"
        PID="0x9231"
        PRODUCT="Pupil Cam1 ID1"
        MANUFACTURER="Pupil Labs"
        SERIAL_PREFIX="PZ-EYE1"
        DEFAULT_INTERVAL_480P="111111"  # 90 fps default
        ;;
    world)
        VID="0x05a3"
        PID="0x9232"
        PRODUCT="Pupil Cam1 ID2"
        MANUFACTURER="Pupil Labs"
        SERIAL_PREFIX="PZ-WORLD"
        DEFAULT_INTERVAL_480P="333333"  # 30 fps default
        ;;
    generic)
        VID="0x1d6b"
        PID="0x0104"
        PRODUCT="Pi Zero UVC Camera"
        MANUFACTURER="Raspberry Pi"
        SERIAL_PREFIX="PZCAM"
        DEFAULT_INTERVAL_480P="333333"  # 30 fps default
        ;;
esac

# Read Pi CPU serial number from /proc/cpuinfo if available (on Linux)
CPU_SER="${CPU_SERIAL:-}"
if [ -z "$CPU_SER" ] && [ "$(uname -s 2>/dev/null)" = "Linux" ] && [ -f /proc/cpuinfo ]; then
    CPU_SER=$(grep -m1 -i "Serial" /proc/cpuinfo 2>/dev/null | awk '{print $NF}' | tail -c 9 | tr -d '\r\n')
fi
if [ -n "$CPU_SER" ] && [ "$CPU_SER" != "00000000" ]; then
    SERIAL="${SERIAL_PREFIX}-${CPU_SER}"
else
    SERIAL="${SERIAL_PREFIX}-00000001"
fi

# -----------------------------------------------------------------------------
# Action Functions
# -----------------------------------------------------------------------------
start_gadget() {
    echo "[*] Initializing UVC Gadget (Role: $ROLE, Product: '$PRODUCT', VID:PID: $VID:$PID)..."

    # Mount ConfigFS and load kernel module if running on a real system
    if [ "$CONFIGFS_ROOT" = "/sys/kernel/config" ]; then
        mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config 2>/dev/null || true
        modprobe libcomposite 2>/dev/null || true
    fi

    # Gerçek sistemde gadget zaten aynı rol ve tam FPS listesiyle UDC'ye bağlıysa
    # UDC'yi söküp tekrar kurma (canlı UVC akışı varken UDC unbind dwc2'yi kilitler).
    if [ "$CONFIGFS_ROOT" = "/sys/kernel/config" ] && [ -f "$GADGET/UDC" ]; then
        local cur_udc cur_prod ival_lines
        cur_udc=$(cat "$GADGET/UDC" 2>/dev/null | tr -d '[:space:]')
        cur_prod=$(cat "$GADGET/strings/0x409/product" 2>/dev/null | tr -d '\r\n')
        ival_lines=$(wc -l < "$FUNC/streaming/mjpeg/m/240p/dwFrameInterval" 2>/dev/null || echo 0)
        if [ -n "$cur_udc" ] && [ "$cur_prod" = "$PRODUCT" ] && [ "$ival_lines" -ge 3 ]; then
            echo "[✓] UVC Gadget zaten aktif ve güncel ($cur_prod on $cur_udc) — UDC yeniden bağlanmadı"
            return 0
        fi
    fi

    # Clean existing gadget if present
    if [ -d "$GADGET" ]; then
        echo "[*] Cleaning up existing gadget: $GADGET"
        stop_gadget 2>/dev/null || true
    fi

    # Clean legacy gadget path if different and present
    LEGACY_GADGET="$CONFIGFS_ROOT/usb_gadget/picam"
    if [ "$GADGET" != "$LEGACY_GADGET" ] && [ -d "$LEGACY_GADGET" ]; then
        echo "[*] Cleaning up legacy gadget: $LEGACY_GADGET"
        GADGET_BACKUP="$GADGET"
        FUNC_BACKUP="$FUNC"
        CONFIG_BACKUP="$CONFIG"
        GADGET="$LEGACY_GADGET"
        FUNC="$GADGET/functions/uvc.usb0"
        CONFIG="$GADGET/configs/c.1"
        stop_gadget 2>/dev/null || true
        GADGET="$GADGET_BACKUP"
        FUNC="$FUNC_BACKUP"
        CONFIG="$CONFIG_BACKUP"
    fi

    # =========================================================================
    # 1. USB Device & Interface Association Descriptor (IAD)
    # =========================================================================
    mkdir -p "$GADGET"
    echo "$VID"   > "$GADGET/idVendor"
    echo "$PID"   > "$GADGET/idProduct"
    echo 0x0100   > "$GADGET/bcdDevice"
    echo 0x0200   > "$GADGET/bcdUSB"

    # IAD: Miscellaneous Device Class (0xEF), Common Class (0x02), IAD (0x01)
    echo 0xEF     > "$GADGET/bDeviceClass"
    echo 0x02     > "$GADGET/bDeviceSubClass"
    echo 0x01     > "$GADGET/bDeviceProtocol"

    # English US Strings
    mkdir -p "$GADGET/strings/0x409"
    echo "$SERIAL"       > "$GADGET/strings/0x409/serialnumber"
    echo "$MANUFACTURER" > "$GADGET/strings/0x409/manufacturer"
    echo "$PRODUCT"      > "$GADGET/strings/0x409/product"

    # =========================================================================
    # 2. USB Configuration Descriptor
    # =========================================================================
    mkdir -p "$CONFIG/strings/0x409"
    echo "UVC Camera Configuration" > "$CONFIG/strings/0x409/configuration"
    echo 500  > "$CONFIG/MaxPower"     # 500 mA
    echo 0x80 > "$CONFIG/bmAttributes" # Bus powered

    # =========================================================================
    # 3. UVC Function & Isochronous Endpoints
    # =========================================================================
    mkdir -p "$FUNC"

    # High-Bandwidth Isochronous: 2048 bytes (2 transactions per microframe)
    # Optimal FIFO stability on BCM2835 dwc2 with high throughput headroom
    echo 2048 > "$FUNC/streaming_maxpacket"
    echo 1    > "$FUNC/streaming_maxburst"
    echo 1    > "$FUNC/streaming_interval"

    # =========================================================================
    # 4. Video Control (VC) Interface
    # =========================================================================
    mkdir -p "$FUNC/control/header/h"
    echo 0x0110   > "$FUNC/control/header/h/bcdUVC"           # UVC 1.10
    echo 48000000 > "$FUNC/control/header/h/dwClockFrequency" # 48 MHz clock

    # Symlink control header to Full-Speed (fs) and Super-Speed (ss)
    mkdir -p "$FUNC/control/class/fs" "$FUNC/control/class/ss"
    ln -sf "$FUNC/control/header/h" "$FUNC/control/class/fs/h"
    ln -sf "$FUNC/control/header/h" "$FUNC/control/class/ss/h"

    # =========================================================================
    # 5. Video Streaming (VS) Interface & MJPEG Formats
    # Only expose MJPEG (pyuvc rejects uncompressed formats with NotImplementedError)
    # =========================================================================
    mkdir -p "$FUNC/streaming/mjpeg/m"

    # Kernel-managed read-only attributes (bFormatIndex, bmFlags, bFrameIndex, color matching)
    # The real Linux kernel (f_uvc) creates and manages these as read-only (0444).
    # Writing to them on live ConfigFS causes EACCES (Permission denied).
    # We populate them ONLY in mock test environments.
    if [ "$CONFIGFS_ROOT" != "/sys/kernel/config" ]; then
        echo 1 > "$FUNC/streaming/mjpeg/m/bFormatIndex"
        echo 1 > "$FUNC/streaming/mjpeg/m/bmFlags"
    fi

    # Helper function to register an MJPEG frame descriptor
    register_frame_desc() {
        local name="$1"
        local width="$2"
        local height="$3"
        local default_interval="$4"
        local intervals="$5"
        local frame_index="${6:-}"
        local min_bitrate="${7:-$(( width * height * 16 * 15 ))}"
        local max_bitrate="${8:-$(( width * height * 16 * 120 ))}"

        local frame_dir="$FUNC/streaming/mjpeg/m/$name"
        mkdir -p "$frame_dir"
        if [ "$CONFIGFS_ROOT" != "/sys/kernel/config" ] && [ -n "$frame_index" ]; then
            echo "$frame_index" > "$frame_dir/bFrameIndex"
        fi
        echo "$width"       > "$frame_dir/wWidth"
        echo "$height"      > "$frame_dir/wHeight"
        local buf_size=$(( width * height * 2 ))
        echo "$buf_size"    > "$frame_dir/dwMaxVideoFrameBufferSize"
        echo "$default_interval" > "$frame_dir/dwDefaultFrameInterval"
        echo "$min_bitrate" > "$frame_dir/dwMinBitRate"
        echo "$max_bitrate" > "$frame_dir/dwMaxBitRate"
        # ConfigFS uvcg_frame_dw_frame_interval_store her write(2) çağrısında
        # önceki listeyi siler. Bash builtin printf her '\n' karakterinde ayrı
        # write(2) yaptığı için sadece son satır (666666 = 15fps) kalıyordu.
        # cat heredoc tüm satırları tek bir write(2) sistem çağrısıyla yazar.
        local parsed_intervals
        parsed_intervals=$(printf '%b\n' "$intervals")
        cat <<EOF > "$frame_dir/dwFrameInterval"
$parsed_intervals
EOF
    }

    # Frame Descriptor 1: 640x480 (480p - VGA Standart / Göz Takibi)
    register_frame_desc "480p" 640 480 "$DEFAULT_INTERVAL_480P" "83333\n111111\n166666\n333333\n666666" 1 73728000 589824000

    # Frame Descriptor 2: 1280x720 (720p - HD Sahne)
    register_frame_desc "720p" 1280 720 "333333" "166666\n333333\n666666" 2 110592000 442368000

    # Frame Descriptor 3: 320x240 (240p / 320p - Yüksek Hızlı Göz Takibi / Düşük CPU)
    register_frame_desc "240p" 320 240 "111111" "83333\n111111\n166666\n333333\n666666" 3

    # Frame Descriptor 4: 400x400 (400p - Kare Göz Takibi)
    register_frame_desc "400p" 400 400 "111111" "83333\n111111\n166666\n333333\n666666" 4

    # Frame Descriptor 5: 800x600 (600p - SVGA)
    register_frame_desc "600p" 800 600 "333333" "166666\n333333\n666666" 5

    # Frame Descriptor 6: Dinamik Özel Çözünürlük (Kullanıcı Tanımlı)
    CFG_W="${WIDTH:-}"
    CFG_H="${HEIGHT:-}"
    DEFAULT_FRAME_INDEX=1
    case "${CFG_W}x${CFG_H}" in
        640x480|"x"|"") DEFAULT_FRAME_INDEX=1 ;;
        1280x720)   DEFAULT_FRAME_INDEX=2 ;;
        320x240)    DEFAULT_FRAME_INDEX=3 ;;
        400x400)    DEFAULT_FRAME_INDEX=4 ;;
        800x600)    DEFAULT_FRAME_INDEX=5 ;;
        *)
            echo "[i] Özel çözünürlük ConfigFS'e ekleniyor: ${CFG_W}x${CFG_H}"
            register_frame_desc "custom" "$CFG_W" "$CFG_H" "111111" "83333\n111111\n166666\n333333\n666666" 6
            DEFAULT_FRAME_INDEX=6
            ;;
    esac
    (echo "$DEFAULT_FRAME_INDEX" > "$FUNC/streaming/mjpeg/m/bDefaultFrameIndex") 2>/dev/null || true

    # Color Matching Descriptor
    mkdir -p "$FUNC/streaming/color_matching/default"
    if [ "$CONFIGFS_ROOT" != "/sys/kernel/config" ]; then
        echo 1 > "$FUNC/streaming/color_matching/default/bColorPrimaries"
        echo 1 > "$FUNC/streaming/color_matching/default/bTransferCharacteristics"
        echo 4 > "$FUNC/streaming/color_matching/default/bMatrixCoefficients"
    fi
    ln -sf "$FUNC/streaming/color_matching/default" "$FUNC/streaming/mjpeg/m/color_matching"

    # Streaming Header
    mkdir -p "$FUNC/streaming/header/h"
    ln -sf "$FUNC/streaming/mjpeg/m" "$FUNC/streaming/header/h/m"

    # Symlink streaming header to Full-Speed (fs), High-Speed (hs), and Super-Speed (ss)
    mkdir -p "$FUNC/streaming/class/fs" "$FUNC/streaming/class/hs" "$FUNC/streaming/class/ss"
    ln -sf "$FUNC/streaming/header/h" "$FUNC/streaming/class/fs/h"
    ln -sf "$FUNC/streaming/header/h" "$FUNC/streaming/class/hs/h"
    ln -sf "$FUNC/streaming/header/h" "$FUNC/streaming/class/ss/h"

    # =========================================================================
    # 6. Bind Function to Configuration
    # =========================================================================
    ln -sf "$FUNC" "$CONFIG/uvc.usb0"

    # =========================================================================
    # 6b. USB Ethernet (RNDIS) Composite Gadget Support (Optional)
    # Disabled by default (ENABLE_RNDIS=0) because:
    # 1. BCM2835 dwc2 lacks periodic TX FIFOs for simultaneous High-Bandwidth
    #    Isochronous UVC + RNDIS, causing Windows usbrndis6.sys PnP Error state.
    # 2. Pupil Capture's libwdi driver installer (PupilDrvInst.exe) binds libusbK
    #    to the root USB device and hangs on CMP_WaitNoPendingInstallEvents if a
    #    faulted RNDIS child interface (MI_02) is present.
    # =========================================================================
    ENABLE_RNDIS="${ENABLE_RNDIS:-0}"
    if [ "$ENABLE_RNDIS" = "1" ] || [ "$ENABLE_RNDIS" = "true" ]; then
        RNDIS_FUNC="$GADGET/functions/rndis.usb0"
        if [ ! -d "$RNDIS_FUNC" ]; then
            modprobe usb_f_rndis 2>/dev/null || true
            mkdir -p "$RNDIS_FUNC"
        fi

        # OS Descriptors for native Microsoft Windows RNDIS 6.0 driver binding
        mkdir -p "$GADGET/os_desc"
        echo 1 > "$GADGET/os_desc/use" 2>/dev/null || true
        echo 0xcd > "$GADGET/os_desc/b_vendor_code" 2>/dev/null || true
        echo "MSFT100" > "$GADGET/os_desc/qw_sign" 2>/dev/null || true

        mkdir -p "$RNDIS_FUNC/os_desc/interface.rndis"
        echo "RNDIS" > "$RNDIS_FUNC/os_desc/interface.rndis/compatible_id" 2>/dev/null || true
        echo "5162001" > "$RNDIS_FUNC/os_desc/interface.rndis/sub_compatible_id" 2>/dev/null || true

        ln -sf "$CONFIG" "$GADGET/os_desc/c.1" 2>/dev/null || true
        ln -sf "$RNDIS_FUNC" "$CONFIG/rndis.usb0" 2>/dev/null || true
        echo "[✓] USB Ethernet (RNDIS) function linked to configuration"
    else
        echo 0 > "$GADGET/os_desc/use" 2>/dev/null || true
        rm -f "$GADGET/os_desc/c.1" "$CONFIG/rndis.usb0" 2>/dev/null || true
        rmdir "$GADGET/functions/rndis.usb0" 2>/dev/null || true
    fi

    # =========================================================================
    # 7. Bind Gadget to USB Device Controller (UDC)
    # =========================================================================
    UDC="${MOCK_UDC:-}"
    if [ -z "$UDC" ] && [ -d /sys/class/udc ]; then
        UDC=$(ls /sys/class/udc 2>/dev/null | head -1)
    fi

    # Try dynamic runtime overlay load if UDC is empty on live Pi
    if [ -z "$UDC" ] && command -v dtoverlay >/dev/null 2>&1; then
        dtoverlay dwc2 dr_mode=peripheral 2>/dev/null || true
        modprobe dwc2 2>/dev/null || true
        modprobe libcomposite 2>/dev/null || true
        sleep 1
        [ -d /sys/class/udc ] && UDC=$(ls /sys/class/udc 2>/dev/null | head -1)
    fi

    if [ -z "$UDC" ]; then
        echo "[!] Uyari: /sys/class/udc dizininde henuz aktif UDC denetleyicisi bulunamadi." >&2
        echo "[!] dtoverlay=dwc2 ayari config.txt'ye yazildi. USB aygit modunu baslatmak icin lutfen Pi'yi yeniden baslatin: sudo reboot" >&2
        return 0
    fi

    # Idempotency check: if this gadget is already bound to this UDC, we are done
    if [ -f "$GADGET/UDC" ] && [ "$(cat "$GADGET/UDC" 2>/dev/null)" = "$UDC" ]; then
        echo "[✓] UVC Gadget is already bound to UDC: $UDC"
        echo "[i] Gadget path: $GADGET"
        echo "[i] Role: $ROLE | Product: '$PRODUCT' | Serial: '$SERIAL'"
        return 0
    fi

    # Release any active UDC bindings from other ConfigFS gadgets or legacy modules
    for mod in g_ether g_serial g_mass_storage g_webcam g_cdc g_hid g_multi; do
        if command -v lsmod >/dev/null 2>&1 && lsmod | grep -q "^$mod\b"; then
            echo "[*] Unloading conflicting legacy module: $mod"
            rmmod "$mod" 2>/dev/null || true
        fi
    done

    # Unbind any existing gadget in ConfigFS to prevent EBUSY (Device or resource busy)
    if [ -d "$CONFIGFS_ROOT/usb_gadget" ]; then
        for u in "$CONFIGFS_ROOT"/usb_gadget/*/UDC; do
            if [ -f "$u" ]; then
                echo "" > "$u" 2>/dev/null || true
            fi
        done
    fi

    echo "$UDC" > "$GADGET/UDC"
    echo "[✓] UVC Gadget successfully created and bound to UDC: $UDC"
    echo "[i] Gadget path: $GADGET"
    echo "[i] Role: $ROLE | Product: '$PRODUCT' | Serial: '$SERIAL'"
}

stop_gadget() {
    echo "[*] Tearing down UVC Gadget ($GADGET)..."

    # Önce video akışını sonlandır ki UVC video endpoint'leri boşalsın
    pkill -TERM uvc-gadget 2>/dev/null || true
    sleep 0.3
    pkill -KILL uvc-gadget 2>/dev/null || true
    sleep 0.2

    if [ ! -d "$GADGET" ]; then
        echo "[i] Gadget does not exist: $GADGET"
        return 0
    fi

    # 1. Unbind from UDC
    if [ -f "$GADGET/UDC" ]; then
        echo "" > "$GADGET/UDC" 2>/dev/null || true
    fi

    # 2. Allow pending in-flight transactions to drain
    sleep 0.5

    # 3. Remove function link from configuration
    rm -f "$CONFIG/uvc.usb0" 2>/dev/null || true
    rm -rf "$CONFIG/uvc.usb0" 2>/dev/null || true
    rm -f "$CONFIG/rndis.usb0" 2>/dev/null || true
    rm -rf "$CONFIG/rndis.usb0" 2>/dev/null || true
    rm -f "$GADGET/os_desc/c.1" 2>/dev/null || true

    # 4. Remove class and header symlinks
    rm -f "$FUNC/streaming/class/fs/h" 2>/dev/null || true
    rm -rf "$FUNC/streaming/class/fs/h" 2>/dev/null || true
    rm -f "$FUNC/streaming/class/hs/h" 2>/dev/null || true
    rm -rf "$FUNC/streaming/class/hs/h" 2>/dev/null || true
    rm -f "$FUNC/streaming/class/ss/h" 2>/dev/null || true
    rm -rf "$FUNC/streaming/class/ss/h" 2>/dev/null || true
    rm -f "$FUNC/streaming/header/h/m" 2>/dev/null || true
    rm -rf "$FUNC/streaming/header/h/m" 2>/dev/null || true
    rm -f "$FUNC/streaming/header/h/u" 2>/dev/null || true
    rm -rf "$FUNC/streaming/header/h/u" 2>/dev/null || true
    rm -f "$FUNC/streaming/mjpeg/m/color_matching" 2>/dev/null || true
    rm -rf "$FUNC/streaming/mjpeg/m/color_matching" 2>/dev/null || true
    rm -f "$FUNC/control/class/fs/h" 2>/dev/null || true
    rm -rf "$FUNC/control/class/fs/h" 2>/dev/null || true
    rm -f "$FUNC/control/class/ss/h" 2>/dev/null || true
    rm -rf "$FUNC/control/class/ss/h" 2>/dev/null || true

    # 5. Remove regular files if running on standard filesystem (mock testing)
    rm -f "$FUNC/streaming/mjpeg/m/480p/"* 2>/dev/null || true
    rm -f "$FUNC/streaming/mjpeg/m/720p/"* 2>/dev/null || true
    rm -f "$FUNC/streaming/mjpeg/m/"* 2>/dev/null || true
    rm -f "$FUNC/streaming/color_matching/default/"* 2>/dev/null || true
    rm -f "$FUNC/control/header/h/"* 2>/dev/null || true
    rm -f "$FUNC/"* 2>/dev/null || true
    rm -f "$CONFIG/strings/0x409/"* 2>/dev/null || true
    rm -f "$CONFIG/"* 2>/dev/null || true
    rm -f "$GADGET/strings/0x409/"* 2>/dev/null || true
    rm -f "$GADGET/"* 2>/dev/null || true

    # 6. Remove frame directories in reverse order
    rmdir "$FUNC/streaming/mjpeg/m/480p" 2>/dev/null || true
    rmdir "$FUNC/streaming/mjpeg/m/720p" 2>/dev/null || true
    for fd in "$FUNC"/streaming/mjpeg/m/*/; do
        [ -d "$fd" ] && rmdir "$fd" 2>/dev/null || true
    done
    for fd in "$FUNC"/streaming/uncompressed/u/*/; do
        [ -d "$fd" ] && rmdir "$fd" 2>/dev/null || true
    done

    # 7. Remove format and color matching directories
    rmdir "$FUNC/streaming/mjpeg/m" 2>/dev/null || true
    rmdir "$FUNC/streaming/uncompressed/u" 2>/dev/null || true
    rmdir "$FUNC/streaming/color_matching/default" 2>/dev/null || true
    rmdir "$FUNC/streaming/color_matching" 2>/dev/null || true

    # 8. Remove streaming header and class directories
    rmdir "$FUNC/streaming/header/h" 2>/dev/null || true
    rmdir "$FUNC/streaming/header" 2>/dev/null || true
    rmdir "$FUNC/streaming/class/fs" 2>/dev/null || true
    rmdir "$FUNC/streaming/class/hs" 2>/dev/null || true
    rmdir "$FUNC/streaming/class/ss" 2>/dev/null || true
    rmdir "$FUNC/streaming/class" 2>/dev/null || true
    rmdir "$FUNC/streaming" 2>/dev/null || true

    # 9. Remove control header and class directories
    rmdir "$FUNC/control/header/h" 2>/dev/null || true
    rmdir "$FUNC/control/header" 2>/dev/null || true
    rmdir "$FUNC/control/class/fs" 2>/dev/null || true
    rmdir "$FUNC/control/class/ss" 2>/dev/null || true
    rmdir "$FUNC/control/class" 2>/dev/null || true
    rmdir "$FUNC/control" 2>/dev/null || true

    # 10. Remove function directory
    rmdir "$GADGET/functions/rndis.usb0" 2>/dev/null || true
    rmdir "$FUNC" 2>/dev/null || true

    # 11. Remove config directory
    rmdir "$CONFIG/strings/0x409" 2>/dev/null || true
    rmdir "$CONFIG" 2>/dev/null || true
    rmdir "$GADGET/configs" 2>/dev/null || true

    # 12. Remove gadget directory
    rmdir "$GADGET/strings/0x409" 2>/dev/null || true
    rmdir "$GADGET" 2>/dev/null || rm -rf "$GADGET" 2>/dev/null || true

    echo "[✓] UVC Gadget teardown complete"
}

restart_gadget() {
    stop_gadget
    sleep 0.5
    start_gadget
}

status_gadget() {
    if [ ! -d "$GADGET" ]; then
        echo "Gadget: NOT_CONFIGURED"
        return 1
    fi

    UDC_VAL=""
    if [ -f "$GADGET/UDC" ]; then
        UDC_VAL=$(cat "$GADGET/UDC" 2>/dev/null || true)
    fi

    if [ -n "$UDC_VAL" ]; then
        echo "Gadget:       ACTIVE (UDC: $UDC_VAL)"
        echo "Role:         $ROLE"
        [ -f "$GADGET/idVendor" ] && echo "Vendor ID:    $(cat "$GADGET/idVendor" 2>/dev/null)"
        [ -f "$GADGET/idProduct" ] && echo "Product ID:   $(cat "$GADGET/idProduct" 2>/dev/null)"
        [ -f "$GADGET/strings/0x409/product" ] && echo "Product:      $(cat "$GADGET/strings/0x409/product" 2>/dev/null)"
        [ -f "$GADGET/strings/0x409/manufacturer" ] && echo "Manufacturer: $(cat "$GADGET/strings/0x409/manufacturer" 2>/dev/null)"
        [ -f "$GADGET/strings/0x409/serialnumber" ] && echo "Serial:       $(cat "$GADGET/strings/0x409/serialnumber" 2>/dev/null)"
        [ -f "$FUNC/streaming_maxpacket" ] && echo "MaxPacket:    $(cat "$FUNC/streaming_maxpacket" 2>/dev/null)"

        # Search for active UVC video device node
        for dev in /dev/video*; do
            if [ -e "$dev" ] && command -v v4l2-ctl >/dev/null 2>&1; then
                if v4l2-ctl --device="$dev" --info 2>/dev/null | grep -q "uvcg"; then
                    echo "UVC Device:   $dev"
                    break
                fi
            fi
        done
        return 0
    else
        echo "Gadget: CONFIGURED (Not bound to UDC)"
        echo "Role:   $ROLE"
        return 2
    fi
}

# -----------------------------------------------------------------------------
# Action Dispatcher
# -----------------------------------------------------------------------------
case "$ACTION" in
    start)
        start_gadget
        ;;
    stop)
        stop_gadget
        ;;
    restart)
        restart_gadget
        ;;
    status)
        status_gadget
        ;;
    *)
        echo "Error: Unknown action '$ACTION'" >&2
        echo "Usage: $0 [eye0|eye1|world|generic] [start|stop|restart|status]" >&2
        exit 1
        ;;
esac
