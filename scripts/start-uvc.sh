#!/bin/bash
# =============================================================================
# Pi Zero W UVC - Video Capture & MJPEG Streaming Pipeline Daemon
# Connects CSI camera video source to UVC gadget function (uvc.usb0)
# Supports hardware MJPEG encoding (bcm2835-v4l2) and libcamera fallback.
# =============================================================================
set -e

CONFIG_FILE="/etc/picam/config.json"
DEFAULT_ENV="/etc/default/picam-uvc"
LOG_TAG="picam-uvc"

log() {
    if command -v logger >/dev/null 2>&1; then
        logger -t "$LOG_TAG" "$1" 2>/dev/null || true
    fi
    echo "$1"
}

# -----------------------------------------------------------------------------
# Configuration Reading Helper
# -----------------------------------------------------------------------------
read_config() {
    local key=$1
    local default=$2
    if command -v jq &>/dev/null && [ -f "$CONFIG_FILE" ]; then
        val=$(jq -r "if .$key != null then .$key else empty end" "$CONFIG_FILE" 2>/dev/null)
        echo "${val:-$default}"
    else
        echo "$default"
    fi
}

# -----------------------------------------------------------------------------
# Environment & Configuration Loading
# -----------------------------------------------------------------------------
if [ -f "$DEFAULT_ENV" ]; then
    while IFS='=' read -r key val || [ -n "$key" ]; do
        case "$key" in
            \#*|"") continue ;;
        esac
        key=$(echo "$key" | tr -d '[:space:]')
        val=$(echo "$val" | sed -e 's/^[[:space:]]*["'\'']//' -e 's/["'\''][[:space:]]*$//')
        case "$key" in
            ROLE|SENSOR|FPS|WIDTH|HEIGHT|CAM_DEVICE|HFLIP|VFLIP|HORIZONTAL_FLIP|VERTICAL_FLIP)
                declare "$key=$val"
                ;;
        esac
    done < "$DEFAULT_ENV"
fi

ROLE="${ROLE:-$(read_config "role" "eye0")}"
SENSOR="${SENSOR:-$(read_config "sensor" "ov5647")}"
FPS="${FPS:-$(read_config "fps" "90")}"
WIDTH="${WIDTH:-$(read_config "width" "640")}"
HEIGHT="${HEIGHT:-$(read_config "height" "480")}"
CAM_DEVICE="${CAM_DEVICE:-}"
ALLOW_TEST_PATTERN="${ALLOW_TEST_PATTERN:-$(read_config "allow_test_pattern" "false")}"

# -----------------------------------------------------------------------------
# Sensor Profile Configuration
# -----------------------------------------------------------------------------
configure_sensor_profile() {
    local sensor="${1:-$SENSOR}"
    case "$sensor" in
        ov5647)
            log "[i] Sensor profile: OmniVision OV5647 (v1.3, rolling shutter, up to 90fps VGA)"
            ;;
        imx219)
            log "[i] Sensor profile: Sony IMX219 (v2, rolling shutter, up to 90fps VGA binned)"
            ;;
        ov9281)
            log "[i] Sensor profile: OmniVision OV9281 (global shutter, monochrome NIR, up to 120fps)"
            ;;
        *)
            log "[i] Sensor profile: generic ($sensor)"
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Camera Subdevice & Flip Controls
# -----------------------------------------------------------------------------
apply_camera_controls() {
    log "[*] Applying camera controls..."

    local hflip_cfg
    local vflip_cfg
    hflip_cfg=$(read_config "horizontal_flip" "$(read_config "hflip" "${HORIZONTAL_FLIP:-${HFLIP:-false}}")")
    vflip_cfg=$(read_config "vertical_flip" "$(read_config "vflip" "${VERTICAL_FLIP:-${VFLIP:-false}}")")

    # Discover camera subdevice (/dev/v4l-subdev*) exposing flip controls
    SUBDEV=""
    for sd in /dev/v4l-subdev*; do
        [ -e "$sd" ] || continue
        if command -v v4l2-ctl >/dev/null 2>&1; then
            if v4l2-ctl --device="$sd" --list-ctrls 2>/dev/null | grep -q "horizontal_flip"; then
                SUBDEV="$sd"
                break
            fi
        fi
    done

    # Fallback to checking the capture device node itself
    local ctrl_dev="$SUBDEV"
    if [ -z "$ctrl_dev" ] && [ -n "$CAM_SRC" ] && [ "$CAM_SRC" != "libcamera" ] && [ -e "$CAM_SRC" ]; then
        if command -v v4l2-ctl >/dev/null 2>&1; then
            if v4l2-ctl --device="$CAM_SRC" --list-ctrls 2>/dev/null | grep -q "horizontal_flip"; then
                ctrl_dev="$CAM_SRC"
            fi
        fi
    fi

    if [ -n "$ctrl_dev" ]; then
        log "[i] Camera control device: $ctrl_dev"
        if command -v v4l2-ctl >/dev/null 2>&1; then
            if [ "$hflip_cfg" = "true" ] || [ "$hflip_cfg" = "1" ]; then
                v4l2-ctl --device="$ctrl_dev" --set-ctrl horizontal_flip=1 2>/dev/null || true
            else
                v4l2-ctl --device="$ctrl_dev" --set-ctrl horizontal_flip=0 2>/dev/null || true
            fi

            if [ "$vflip_cfg" = "true" ] || [ "$vflip_cfg" = "1" ]; then
                v4l2-ctl --device="$ctrl_dev" --set-ctrl vertical_flip=1 2>/dev/null || true
            else
                v4l2-ctl --device="$ctrl_dev" --set-ctrl vertical_flip=0 2>/dev/null || true
            fi
        fi
        log "[✓] Flip controls applied: horizontal_flip=$hflip_cfg, vertical_flip=$vflip_cfg"
    else
        log "[!] Camera subdevice not found, flip controls skipped"
    fi
}

# -----------------------------------------------------------------------------
# UVC Output Node Detection
# -----------------------------------------------------------------------------
find_uvc_device() {
    # 1. Search /sys/class/video4linux/ for UVC gadget driver nodes
    if [ -d /sys/class/video4linux ]; then
        for v4l in /sys/class/video4linux/video*; do
            [ -e "$v4l" ] || continue
            local dev_node="/dev/$(basename "$v4l")"
            if [ -f "$v4l/name" ]; then
                local dev_name
                dev_name=$(cat "$v4l/name" 2>/dev/null || true)
                if echo "$dev_name" | grep -qiE "uvc|uvcg|uvc-gadget"; then
                    echo "$dev_node"
                    return 0
                fi
            fi
        done
    fi

    # 2. Search /dev/video* via v4l2-ctl for uvcg driver
    for dev in /dev/video*; do
        [ -e "$dev" ] || continue
        if command -v v4l2-ctl >/dev/null 2>&1; then
            if v4l2-ctl --device="$dev" --info 2>/dev/null | grep -qiE "uvcg|uvc-gadget|UVC"; then
                echo "$dev"
                return 0
            fi
        fi
    done
    return 1
}

# -----------------------------------------------------------------------------
# Camera Source Detection & Prioritization
# -----------------------------------------------------------------------------
find_camera_device() {
    # If explicitly configured via CAM_DEVICE in /etc/default/picam-uvc, use it
    if [ -n "$CAM_DEVICE" ]; then
        echo "$CAM_DEVICE"
        return 0
    fi

    # 0. Fast sysfs check for unicam (libcamera) without spawning 30 v4l2-ctl processes
    if grep -qi "unicam" /sys/class/video4linux/video*/name 2>/dev/null; then
        echo "libcamera"
        return 0
    fi

    # 1. Prioritize /dev/video0 if running bcm2835-v4l2 (VideoCore IV hardware MJPEG)
    # Delivers hardware MJPEG at <10% CPU load on single-core ARM11 @ 90fps
    if [ -e "/dev/video0" ]; then
        local v0_driver=""
        if command -v v4l2-ctl >/dev/null 2>&1; then
            v0_driver=$(v4l2-ctl --device="/dev/video0" --info 2>/dev/null || true)
        elif [ -f "/sys/class/video4linux/video0/name" ]; then
            v0_driver=$(cat "/sys/class/video4linux/video0/name" 2>/dev/null || true)
        fi

        if echo "$v0_driver" | grep -qiE "bcm2835-v4l2|mmal" && ! echo "$v0_driver" | grep -qiE "codec|isp|m2m"; then
            echo "/dev/video0"
            return 0
        fi
    fi

    # 2. Search other /dev/video* devices for bcm2835-v4l2 or mmal hardware MJPEG
    # Strictly exclude hardware codecs (video10..12) and ISP nodes (video13..16)
    for dev in /dev/video*; do
        [ -e "$dev" ] || continue
        [ -n "$UVC_DEV" ] && [ "$dev" = "$UVC_DEV" ] && continue
        if command -v v4l2-ctl >/dev/null 2>&1; then
            local dev_info
            dev_info=$(v4l2-ctl --device="$dev" --info 2>/dev/null || true)
            if echo "$dev_info" | grep -qiE "codec|isp|m2m"; then
                continue
            fi
            if echo "$dev_info" | grep -qiE "bcm2835-v4l2|bcm2835|mmal"; then
                echo "$dev"
                return 0
            fi
        fi
    done

    # 3. Check for unicam (libcamera) or libcamera-hello availability
    if [ -e "/dev/video0" ]; then
        local v0_info=""
        if command -v v4l2-ctl >/dev/null 2>&1; then
            v0_info=$(v4l2-ctl --device="/dev/video0" --info 2>/dev/null || true)
        elif [ -f "/sys/class/video4linux/video0/name" ]; then
            v0_info=$(cat "/sys/class/video4linux/video0/name" 2>/dev/null || true)
        fi
        if echo "$v0_info" | grep -qi "unicam"; then
            echo "libcamera"
            return 0
        fi
    fi

    for dev in /dev/video*; do
        [ -e "$dev" ] || continue
        [ -n "$UVC_DEV" ] && [ "$dev" = "$UVC_DEV" ] && continue
        if command -v v4l2-ctl >/dev/null 2>&1; then
            local dev_info
            dev_info=$(v4l2-ctl --device="$dev" --info 2>/dev/null || true)
            if echo "$dev_info" | grep -qi "unicam"; then
                echo "libcamera"
                return 0
            fi
        fi
    done

    if command -v libcamera-hello >/dev/null 2>&1; then
        if libcamera-hello --list-cameras 2>/dev/null | grep -qiE "Available cameras|ov5647|imx219|ov9281"; then
            echo "libcamera"
            return 0
        fi
    fi

    # 4. Fallback: Any real video capture node that is not a codec, ISP, or UVC gadget
    for dev in /dev/video*; do
        [ -e "$dev" ] || continue
        [ -n "$UVC_DEV" ] && [ "$dev" = "$UVC_DEV" ] && continue
        if command -v v4l2-ctl >/dev/null 2>&1; then
            local dev_all
            dev_all=$(v4l2-ctl --device="$dev" --all 2>/dev/null || true)
            if echo "$dev_all" | grep -qiE "codec|isp|m2m"; then
                continue
            fi
            if echo "$dev_all" | grep -qi "Video Capture"; then
                echo "$dev"
                return 0
            fi
        fi
    done

    return 1
}

# -----------------------------------------------------------------------------
# Main Streaming Daemon Entry Point
# -----------------------------------------------------------------------------
main() {
    log "========================================="
    log "[*] Starting Pi Zero W UVC Streaming Pipeline..."
    log "========================================="

    # Apply sensor profile
    configure_sensor_profile "$SENSOR"
    log "[i] Stream configuration: Role=$ROLE, Sensor=$SENSOR, Format=${WIDTH}x${HEIGHT}@${FPS}fps"

    # Wait for UVC ConfigFS gadget output device to appear
    RETRIES=10
    UVC_DEV=""
    while [ $RETRIES -gt 0 ]; do
        UVC_DEV=$(find_uvc_device) && break
        log "[*] Waiting for UVC gadget device... ($RETRIES retries left)"
        sleep 1
        RETRIES=$((RETRIES - 1))
    done

    if [ -z "$UVC_DEV" ]; then
        log "[!] ERROR: UVC gadget device node not found in /sys/class/video4linux or /dev/video*!"
        log "[i] Ensure setup-gadget.sh start was executed and UDC is bound."
        exit 1
    fi
    log "[✓] Found UVC gadget output device: $UVC_DEV"

    # Detect camera capture source
    CAM_SRC=$(find_camera_device || true)
    if [ -z "$CAM_SRC" ]; then
        if [ "$ALLOW_TEST_PATTERN" = "true" ] || [ "$ALLOW_TEST_PATTERN" = "1" ]; then
            log "[!] WARNING: Camera hardware not detected (check CSI ribbon cable)."
            log "[*] Falling back to built-in test pattern stream to keep USB UVC gadget alive."
            CAM_SRC="test-pattern"
        else
            log "[!] ERROR: Camera capture source not found!"
            log "[i] Verify CSI ribbon cable connection and kernel overlays."
            exit 1
        fi
    else
        log "[✓] Selected camera capture source: $CAM_SRC"
        # Apply camera controls (flips, subdev controls)
        apply_camera_controls
    fi

    # Pre-flight check for uvc-gadget binary
    if ! command -v uvc-gadget >/dev/null 2>&1; then
        log "[!] ERROR: uvc-gadget binary not found in PATH!"
        log "[i] Please compile and install uvc-gadget (run install.sh)."
        exit 1
    fi

    # Launch uvc-gadget with clean exec process handoff
    if [ "$CAM_SRC" = "libcamera" ]; then
        mkdir -p /etc/picam
        cat > /etc/picam/rpi_pipeline.yaml << 'EOF'
{
    "version": 1.0,
    "target": "bcm2835",
    "pipeline_handler": {
        "min_unicam_buffers": 6,
        "min_total_unicam_buffers": 8
    }
}
EOF
        export LIBCAMERA_RPI_CONFIG_FILE="/etc/picam/rpi_pipeline.yaml"

        SRC_TUNING="/usr/share/libcamera/ipa/rpi/vc4/${SENSOR}.json"
        if [ ! -f "$SRC_TUNING" ] && [ -f "/usr/share/libcamera/ipa/rpi/vc4/${SENSOR}_mono.json" ]; then
            SRC_TUNING="/usr/share/libcamera/ipa/rpi/vc4/${SENSOR}_mono.json"
        fi
        FAST_TUNING="/etc/picam/${SENSOR}_fast.json"
        if [ ! -f "$FAST_TUNING" ] && [ -f "$SRC_TUNING" ] && command -v python3 >/dev/null 2>&1; then
            python3 - "$SRC_TUNING" "$FAST_TUNING" << 'PYEOF'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, "r") as f:
    data = json.load(f)
drop = {"rpi.dpc", "rpi.geq", "rpi.sdn", "rpi.hdr", "rpi.sharpen"}
algos = []
for item in data.get("algorithms", []):
    name = next(iter(item.keys()), "")
    if name in drop:
        continue
    cfg = item[name]
    if name == "rpi.alsc" and isinstance(cfg, dict):
        cfg["n_iter"] = 0
    elif name == "rpi.awb" and isinstance(cfg, dict):
        cfg["bayes"] = 0
    elif name == "rpi.contrast" and isinstance(cfg, dict):
        cfg["ce_enable"] = 0
    elif name == "rpi.agc" and isinstance(cfg, dict):
        for mode in cfg.get("exposure_modes", {}).values():
            if isinstance(mode, dict) and "shutter" in mode:
                mode["shutter"] = [min(int(x), 16666) for x in mode["shutter"]]
        for chan in cfg.get("channels", []):
            for mode in chan.get("exposure_modes", {}).values():
                if isinstance(mode, dict) and "shutter" in mode:
                    mode["shutter"] = [min(int(x), 16666) for x in mode["shutter"]]
    algos.append({name: cfg})
data["algorithms"] = algos
with open(dst, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
        fi
        if [ -f "$FAST_TUNING" ]; then
            export LIBCAMERA_RPI_TUNING_FILE="$FAST_TUNING"
            log "[✓] Enabled high-FPS libcamera tuning: $FAST_TUNING"
        fi

        # Wait up to 10s on early boot for both Unicam and ISP media devices + CSI subdev
        CAM_WAIT=20
        while [ $CAM_WAIT -gt 0 ]; do
            if [ -e /dev/v4l-subdev0 ] && [ -e /dev/media0 ] && [ -e /dev/media1 ]; then
                break
            fi
            sleep 0.5
            CAM_WAIT=$((CAM_WAIT - 1))
        done

        log "[*] Launching uvc-gadget (libcamera backend)..."
        exec uvc-gadget -c 0 uvc.usb0
    elif [ "$CAM_SRC" = "test-pattern" ]; then
        log "[*] Launching uvc-gadget (built-in test pattern generator)..."
        exec uvc-gadget uvc.usb0
    else
        log "[*] Launching uvc-gadget (V4L2 hardware MJPEG backend: $CAM_SRC)..."
        exec uvc-gadget -d "$CAM_SRC" uvc.usb0
    fi
}

main "$@"
