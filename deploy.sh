#!/usr/bin/env bash
# ==============================================================================
# Automated Deployment Script for Raspberry Pi Zero UVC Camera Gadget
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

show_usage() {
    cat << 'EOF'
Usage: deploy.sh [OPTIONS] [TARGET_HOST] [USER] [ROLE] [SENSOR]

Automated deployment tool for Raspberry Pi Zero UVC Camera gadget.

Options:
  -h, --help                  Show this help message and exit
  -H, --host, --target-host   Target Pi hostname or IP (default: makinalasmak.local)
  -u, --user                  Remote username (default: pi)
  -r, --role                  UVC camera role: eye0, eye1, world, generic (default: eye0)
  -s, --sensor                Camera sensor: ov5647, imx219, ov9281 (default: ov5647)
  -p, --port                  SSH/SCP port (1-65535, default: 22)
  -i, -k, --key, --key-path   Path to custom private SSH key
  -d, --dest, --remote-dest   Remote destination directory (default: ~/pi-zero-uvc-cam/)
  -q, --quick, --skip-install Quick mode: update scripts/units/config without recompiling
  -n, --dry-run               Preview commands without executing network operations

Positional arguments (fallback):
  1: TARGET_HOST  2: USER  3: ROLE  4: SENSOR
EOF
}

TARGET_HOST=""
USER=""
ROLE=""
SENSOR=""
PORT=""
KEY_PATH=""
REMOTE_DEST=""
QUICK_MODE=0
DRY_RUN=0

POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_usage
            exit 0
            ;;
        -H|--host|--target-host)
            TARGET_HOST="$2"; shift 2 ;;
        --host=*|--target-host=*)
            TARGET_HOST="${1#*=}"; shift ;;
        -u|--user)
            USER="$2"; shift 2 ;;
        --user=*)
            USER="${1#*=}"; shift ;;
        -r|--role)
            ROLE="$2"; shift 2 ;;
        --role=*)
            ROLE="${1#*=}"; shift ;;
        -s|--sensor)
            SENSOR="$2"; shift 2 ;;
        --sensor=*)
            SENSOR="${1#*=}"; shift ;;
        -p|--port)
            PORT="$2"; shift 2 ;;
        --port=*)
            PORT="${1#*=}"; shift ;;
        -i|-k|--key|--key-path)
            KEY_PATH="$2"; shift 2 ;;
        --key=*|--key-path=*)
            KEY_PATH="${1#*=}"; shift ;;
        -d|--dest|--remote-dest)
            REMOTE_DEST="$2"; shift 2 ;;
        --dest=*|--remote-dest=*)
            REMOTE_DEST="${1#*=}"; shift ;;
        -q|--quick|--skip-install)
            QUICK_MODE=1; shift ;;
        -n|--dry-run)
            DRY_RUN=1; shift ;;
        -*)
            echo "ERROR: Unknown option '$1'" >&2
            show_usage >&2
            exit 1
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done

# Fallback to positional arguments if not provided via flags
if [[ -z "$TARGET_HOST" ]] && [[ ${#POSITIONAL_ARGS[@]} -ge 1 ]]; then
    TARGET_HOST="${POSITIONAL_ARGS[0]}"
fi
if [[ -z "$USER" ]] && [[ ${#POSITIONAL_ARGS[@]} -ge 2 ]]; then
    USER="${POSITIONAL_ARGS[1]}"
fi
if [[ -z "$ROLE" ]] && [[ ${#POSITIONAL_ARGS[@]} -ge 3 ]]; then
    ROLE="${POSITIONAL_ARGS[2]}"
fi
if [[ -z "$SENSOR" ]] && [[ ${#POSITIONAL_ARGS[@]} -ge 4 ]]; then
    SENSOR="${POSITIONAL_ARGS[3]}"
fi

# Apply environment variable fallbacks or defaults
TARGET_HOST="${TARGET_HOST:-${HOST:-makinalasmak.local}}"
USER="${USER:-${TARGET_USER:-${REMOTE_USER:-${USER_NAME:-pi}}}}"
ROLE="${ROLE:-eye0}"
SENSOR="${SENSOR:-ov5647}"
PORT="${PORT:-22}"
KEY_PATH="${KEY_PATH:-}"
REMOTE_DEST="${REMOTE_DEST:-~/pi-zero-uvc-cam/}"

# Validation
if [[ -z "${TARGET_HOST//[[:space:]]/}" ]]; then
    echo "ERROR: TargetHost cannot be empty" >&2
    exit 1
fi

if [[ -z "${USER//[[:space:]]/}" ]]; then
    echo "ERROR: User cannot be empty" >&2
    exit 1
fi

if [[ -z "${REMOTE_DEST//[[:space:]]/}" ]]; then
    echo "ERROR: RemoteDest cannot be empty" >&2
    exit 1
fi

VALID_ROLES=("eye0" "eye1" "world" "generic")
ROLE_VALID=0
for r in "${VALID_ROLES[@]}"; do
    if [[ "$r" == "$ROLE" ]]; then
        ROLE_VALID=1
        break
    fi
done
if [[ $ROLE_VALID -eq 0 ]]; then
    echo "ERROR: Invalid role '$ROLE'. Must be one of: eye0, eye1, world, generic" >&2
    exit 1
fi

VALID_SENSORS=("ov5647" "imx219" "ov9281")
SENSOR_VALID=0
for s in "${VALID_SENSORS[@]}"; do
    if [[ "$s" == "$SENSOR" ]]; then
        SENSOR_VALID=1
        break
    fi
done
if [[ $SENSOR_VALID -eq 0 ]]; then
    echo "ERROR: Invalid sensor '$SENSOR'. Must be one of: ov5647, imx219, ov9281" >&2
    exit 1
fi

# Port validation
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo "ERROR: Invalid port '$PORT'. Must be an integer between 1 and 65535" >&2
    exit 1
fi

# KeyPath validation
if [[ -n "$KEY_PATH" && ! -f "$KEY_PATH" ]]; then
    echo "ERROR: SSH key file not found: '$KEY_PATH'" >&2
    exit 1
fi

# Diagnostics on failure
cleanup_and_report_error() {
    local exit_code=$1
    local line_no=$2
    if [ "$exit_code" -ne 0 ] && [ "$DRY_RUN" -eq 0 ]; then
        echo "" >&2
        echo "==========================================================" >&2
        echo "  DEPLOYMENT FAILED (Exit Code: $exit_code at line $line_no)" >&2
        echo "==========================================================" >&2
        echo "Troubleshooting steps:" >&2
        echo "  1. Check SSH reachability: ssh -p $PORT ${USER}@${TARGET_HOST}" >&2
        echo "  2. Check remote service logs: ssh -p $PORT ${USER}@${TARGET_HOST} 'sudo journalctl -u uvc-gadget -n 50'" >&2
        echo "  3. Verify dwc2 overlay in /boot/config.txt or /boot/firmware/config.txt (reboot needed on fresh install)" >&2
        echo "  4. Check authentication / credentials or SSH key path: '$KEY_PATH'" >&2
        echo "==========================================================" >&2
    fi
}
trap 'cleanup_and_report_error $? $LINENO' EXIT

echo "=========================================================="
echo "  Raspberry Pi Zero UVC Gadget - Automated Deployment (Bash)"
echo "=========================================================="
echo "Target Host : ${USER}@${TARGET_HOST}"
echo "Port        : ${PORT}"
echo "Role        : ${ROLE}"
echo "Sensor      : ${SENSOR}"
echo "Remote Dest : ${REMOTE_DEST}"
echo "Quick Mode  : ${QUICK_MODE}"
echo "Dry Run     : ${DRY_RUN}"
echo "----------------------------------------------------------"

# Expected product descriptor string per role
case "$ROLE" in
    eye0)    EXPECTED_PRODUCT="Pupil Cam1 ID0" ;;
    eye1)    EXPECTED_PRODUCT="Pupil Cam1 ID1" ;;
    world)   EXPECTED_PRODUCT="Pupil Cam1 ID2" ;;
    generic) EXPECTED_PRODUCT="Pi Zero UVC Camera" ;;
esac

# Payload whitelist validation
PAYLOAD_NAMES=("scripts" "services" "uvc-gadget" "web" "install.sh")
PAYLOAD_ITEMS=()
for item in "${PAYLOAD_NAMES[@]}"; do
    if [[ -e "${SCRIPT_DIR}/${item}" ]]; then
        PAYLOAD_ITEMS+=("${SCRIPT_DIR}/${item}")
    else
        echo "ERROR: Required payload item '${item}' not found in ${SCRIPT_DIR}" >&2
        exit 1
    fi
done

# Clean host uvc-gadget/build if present
if [[ -d "${SCRIPT_DIR}/uvc-gadget/build" ]]; then
    rm -rf "${SCRIPT_DIR}/uvc-gadget/build"
fi

# Build SSH / SCP options
SSH_OPTS=()
SCP_OPTS=(-r)
if [[ "$PORT" -ne 22 ]]; then
    SSH_OPTS+=(-p "$PORT")
    SCP_OPTS+=(-P "$PORT")
fi
if [[ -n "$KEY_PATH" ]]; then
    SSH_OPTS+=(-i "$KEY_PATH")
    SCP_OPTS+=(-i "$KEY_PATH")
fi

MKDIR_CMD="mkdir -p '${REMOTE_DEST}'"

CONFIG_UPDATE_CMD="sudo mkdir -p /etc/default && sudo sh -c 'if [ ! -f /etc/default/picam-uvc ]; then printf \"ROLE=\\\"${ROLE}\\\"\nSENSOR=\\\"${SENSOR}\\\"\nFPS=\\\"90\\\"\nWIDTH=\\\"640\\\"\nHEIGHT=\\\"480\\\"\nALLOW_TEST_PATTERN=\\\"true\\\"\n\" > /etc/default/picam-uvc; else grep -q \"^ROLE=\" /etc/default/picam-uvc && sed -i \"s/^ROLE=.*/ROLE=\\\"${ROLE}\\\"/\" /etc/default/picam-uvc || echo \"ROLE=\\\"${ROLE}\\\"\" >> /etc/default/picam-uvc; grep -q \"^SENSOR=\" /etc/default/picam-uvc && sed -i \"s/^SENSOR=.*/SENSOR=\\\"${SENSOR}\\\"/\" /etc/default/picam-uvc || echo \"SENSOR=\\\"${SENSOR}\\\"\" >> /etc/default/picam-uvc; grep -q \"^ALLOW_TEST_PATTERN=\" /etc/default/picam-uvc && sed -i \"s/^ALLOW_TEST_PATTERN=.*/ALLOW_TEST_PATTERN=\\\"true\\\"/\" /etc/default/picam-uvc || echo \"ALLOW_TEST_PATTERN=\\\"true\\\"\" >> /etc/default/picam-uvc; fi; chmod 644 /etc/default/picam-uvc'"

if [[ "$QUICK_MODE" -eq 1 ]]; then
    REMOTE_SETUP_CMD="cd '${REMOTE_DEST}' && sudo install -m 755 scripts/setup-gadget.sh /usr/local/bin/setup-gadget.sh && sudo install -m 755 scripts/start-uvc.sh /usr/local/bin/start-uvc.sh && sudo install -m 644 services/uvc-gadget.service /etc/systemd/system/uvc-gadget.service && sudo install -m 644 services/picam-web.service /etc/systemd/system/picam-web.service && sudo systemctl daemon-reload && ${CONFIG_UPDATE_CMD} && sudo systemctl stop uvc-gadget && sudo /usr/local/bin/setup-gadget.sh '${ROLE}' restart && sudo systemctl start uvc-gadget"
else
    REMOTE_SETUP_CMD="cd '${REMOTE_DEST}' && sudo bash install.sh && ${CONFIG_UPDATE_CMD} && sudo /usr/local/bin/setup-gadget.sh '${ROLE}' restart && sudo systemctl restart uvc-gadget"
fi

VERIFY_CMD="systemctl is-active uvc-gadget >/dev/null 2>&1 && test -f /sys/kernel/config/usb_gadget/pi_uvc/strings/0x409/product && test -s /sys/kernel/config/usb_gadget/pi_uvc/UDC && cat /sys/kernel/config/usb_gadget/pi_uvc/strings/0x409/product"

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY RUN] Command preview:"
    echo "1. Create Remote Destination:"
    echo "   ssh ${SSH_OPTS[*]:-} ${USER}@${TARGET_HOST} \"${MKDIR_CMD}\""
    echo "2. Sync Payload (SCP):"
    echo "   scp ${SCP_OPTS[*]:-} ${PAYLOAD_ITEMS[*]} ${USER}@${TARGET_HOST}:${REMOTE_DEST}"
    echo "3. Remote Setup & Service Restart:"
    echo "   ssh ${SSH_OPTS[*]:-} ${USER}@${TARGET_HOST} \"${REMOTE_SETUP_CMD}\""
    echo "4. Remote Verification:"
    echo "   ssh ${SSH_OPTS[*]:-} ${USER}@${TARGET_HOST} \"${VERIFY_CMD}\""
    echo "   Expected product: '${EXPECTED_PRODUCT}'"
    echo ""
    echo "[DRY RUN] Completed successfully without network operations."
    exit 0
fi

echo "[1/3] Preparing remote destination directory and syncing files via SCP..."
ssh "${SSH_OPTS[@]}" "${USER}@${TARGET_HOST}" "${MKDIR_CMD}"
scp "${SCP_OPTS[@]}" "${PAYLOAD_ITEMS[@]}" "${USER}@${TARGET_HOST}:${REMOTE_DEST}"
echo "  -> Sync complete."

echo "[2/3] Executing remote installer and gadget activation..."
ssh "${SSH_OPTS[@]}" "${USER}@${TARGET_HOST}" "${REMOTE_SETUP_CMD}"
echo "  -> Gadget configured, persistence saved, and service restarted."

echo "[3/3] Verifying remote UVC service status and USB gadget identity..."
ACTUAL_PRODUCT="$(ssh "${SSH_OPTS[@]}" "${USER}@${TARGET_HOST}" "${VERIFY_CMD}")"
ACTUAL_PRODUCT="$(echo -e "${ACTUAL_PRODUCT}" | tr -d '\r\n')"

if [[ "$ACTUAL_PRODUCT" != "$EXPECTED_PRODUCT" ]]; then
    echo "ERROR: Product string mismatch! Expected '$EXPECTED_PRODUCT', got '$ACTUAL_PRODUCT'" >&2
    exit 1
fi
echo "  -> Verification passed: service active, UDC bound, product='$ACTUAL_PRODUCT'"

echo "=========================================================="
echo "  Deployment Successful!"
echo "  Device is ready in role: ${ROLE} (${EXPECTED_PRODUCT}), sensor: ${SENSOR}"
echo "=========================================================="
