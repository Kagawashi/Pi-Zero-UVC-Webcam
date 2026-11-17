#!/usr/bin/env python3
"""
Pi Zero UVC Camera - Web Kontrol Paneli
========================================
Kamera ayarları, Pupil Capture rol seçimi (eye0, eye1, world, generic),
sensör profili (ov5647, imx219, ov9281), servis yönetimi ve sistem durumu izleme.
Video akışı UVC üzerinden gider, bu arayüz sadece kontrol ve konfigürasyon içindir.
"""

import json
import os
import subprocess
import socket
import time
import threading
from pathlib import Path

from flask import Flask, render_template, jsonify, request

# =============================================================================
# Konfigürasyon Yolları ve Varsayılanlar
# =============================================================================
CONFIG_PATH = Path(os.environ.get("PICAM_CONFIG_PATH", "/etc/picam/config.json"))
DEFAULT_ENV_PATH = Path(os.environ.get("PICAM_DEFAULT_ENV", "/etc/default/picam-uvc"))

DEFAULT_CONFIG = {
    "role": "eye0",
    "sensor": "ov5647",
    "fps": 90,
    "width": 640,
    "height": 480,
    "fast_crop": {
        "192x192": False,
        "320x240": False,
        "400x400": False,
        "640x480": False,
        "800x600": False,
        "1280x720": False,
    },
    "hflip": False,
    "vflip": False,
    "brightness": 50,       # 0-100 (50 = normal)
    "contrast": 50,         # 0-100 (50 = normal)
    "saturation": 50,       # 0-100 (50 = normal)
    "sharpness": 50,        # 0-100 (50 = normal)
    "auto_exposure": True,
    "exposure_value": 5000, # µs (manuel mod için)
    "analogue_gain": 8.0,   # 1.0-16.0 (manuel mod kazancı)
    "spatial_denoise": True, # VideoCore IV GPU Spatial Denoise (NoiseReductionModeFast)
    "awb_mode": "auto",     # auto, daylight, cloudy, tungsten, fluorescent
}

DEFAULT_ENV_CONFIG = {
    "ROLE": "eye0",
    "SENSOR": "ov5647",
    "FPS": "90",
    "WIDTH": "640",
    "HEIGHT": "480",
}

# Pupil Capture UVC Hardware Identity Mapping
ROLE_INFO = {
    "eye0": {
        "title": "Pupil Cam1 ID0 (eye0)",
        "label": "Sağ Göz Kamerası (Right Eye)",
        "vid": "0x05a3",
        "pid": "0x9230",
        "product": "Pupil Cam1 ID0",
        "default_fps": "90",
    },
    "eye1": {
        "title": "Pupil Cam1 ID1 (eye1)",
        "label": "Sol Göz Kamerası (Left Eye)",
        "vid": "0x05a3",
        "pid": "0x9231",
        "product": "Pupil Cam1 ID1",
        "default_fps": "90",
    },
    "world": {
        "title": "Pupil Cam1 ID2 (world)",
        "label": "Dünya / Sahne Kamerası (World / Scene)",
        "vid": "0x05a3",
        "pid": "0x9232",
        "product": "Pupil Cam1 ID2",
        "default_fps": "30",
    },
    "generic": {
        "title": "Pi Zero UVC Camera (generic)",
        "label": "Standart UVC Web Kamera (Standard UVC)",
        "vid": "0x1d6b",
        "pid": "0x0104",
        "product": "Pi Zero UVC Camera",
        "default_fps": "30",
    },
}

# Sensor Profiles
SENSOR_INFO = {
    "ov5647": {
        "name": "OmniVision OV5647",
        "description": "Pi Camera v1.3 (Rolling Shutter, 90fps @ VGA)",
        "shutter": "rolling",
        "default_fps": "90",
        "default_width": "640",
        "default_height": "480",
        "max_vga_fps": 90,
        "max_720p_fps": 60,
    },
    "imx219": {
        "name": "Sony IMX219",
        "description": "Pi Camera v2 (Rolling Shutter, 90fps @ VGA)",
        "shutter": "rolling",
        "default_fps": "90",
        "default_width": "640",
        "default_height": "480",
        "max_vga_fps": 90,
        "max_720p_fps": 60,
    },
    "ov9281": {
        "name": "OmniVision OV9281",
        "description": "Global Shutter NIR (120fps @ VGA, Eye Tracking)",
        "shutter": "global",
        "default_fps": "120",
        "default_width": "640",
        "default_height": "480",
        "max_vga_fps": 120,
        "max_720p_fps": 120,
    },
}

app = Flask(__name__)


# =============================================================================
# Yardımcı Fonksiyonlar: Environment & JSON Konfigürasyon
# =============================================================================

def load_default_env() -> dict:
    """Read /etc/default/picam-uvc shell variable file."""
    env = DEFAULT_ENV_CONFIG.copy()
    if DEFAULT_ENV_PATH.exists():
        try:
            with open(DEFAULT_ENV_PATH, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    if "=" in line:
                        k, v = line.split("=", 1)
                        k = k.strip().upper()
                        v = v.strip()
                        if v.startswith('"'):
                            end_idx = v.find('"', 1)
                            if end_idx != -1:
                                val = v[1:end_idx]
                            else:
                                rest = v[1:]
                                if "#" in rest:
                                    rest = rest.split("#", 1)[0]
                                val = rest.strip().rstrip('"\'')
                        elif v.startswith("'"):
                            end_idx = v.find("'", 1)
                            if end_idx != -1:
                                val = v[1:end_idx]
                            else:
                                rest = v[1:]
                                if "#" in rest:
                                    rest = rest.split("#", 1)[0]
                                val = rest.strip().rstrip('"\'')
                        else:
                            if "#" in v:
                                v = v.split("#", 1)[0]
                            val = v.strip().strip("'\"")
                        if k:
                            env[k] = val
        except Exception:
            pass
    return env


def save_default_env(env_updates: dict) -> dict:
    """Update and write /etc/default/picam-uvc environment file safely."""
    current = load_default_env()
    for k, v in env_updates.items():
        if v is not None:
            current[k.upper()] = str(v)

    DEFAULT_ENV_PATH.parent.mkdir(parents=True, exist_ok=True)
    content = (
        "# Pi Zero W UVC Camera Default Settings for Pupil Capture\n"
        f'ROLE="{current.get("ROLE", "eye0")}"\n'
        f'SENSOR="{current.get("SENSOR", "ov5647")}"\n'
        f'FPS="{current.get("FPS", "90")}"\n'
        f'WIDTH="{current.get("WIDTH", "640")}"\n'
        f'HEIGHT="{current.get("HEIGHT", "480")}"\n'
    )
    tmp_path = DEFAULT_ENV_PATH.with_suffix(".tmp")
    with open(tmp_path, "w", encoding="utf-8") as f:
        f.write(content)
    os.replace(tmp_path, DEFAULT_ENV_PATH)

    # Sync with /etc/picam/config.json
    try:
        cfg = load_config()
        cfg["role"] = current.get("ROLE", "eye0")
        cfg["sensor"] = current.get("SENSOR", "ov5647")
        try:
            cfg["fps"] = int(current.get("FPS", 90))
        except ValueError:
            cfg["fps"] = current.get("FPS", 90)
        try:
            cfg["width"] = int(current.get("WIDTH", 640))
        except ValueError:
            cfg["width"] = current.get("WIDTH", 640)
        try:
            cfg["height"] = int(current.get("HEIGHT", 480))
        except ValueError:
            cfg["height"] = current.get("HEIGHT", 480)
        save_config(cfg)
    except Exception:
        pass

    return current


def load_config() -> dict:
    """Konfigürasyon dosyasını oku."""
    config = DEFAULT_CONFIG.copy()
    config["fast_crop"] = DEFAULT_CONFIG["fast_crop"].copy()
    try:
        if CONFIG_PATH.exists():
            with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                saved = json.load(f)
            if isinstance(saved, dict):
                saved_fc = saved.get("fast_crop")
                config.update(saved)
                merged_fc = DEFAULT_CONFIG["fast_crop"].copy()
                if isinstance(saved_fc, dict):
                    merged_fc.update({str(k): bool(v) for k, v in saved_fc.items()})
                config["fast_crop"] = merged_fc
            return config
    except (json.JSONDecodeError, IOError):
        pass
    return config


def save_config(config: dict):
    """Konfigürasyon dosyasını yaz."""
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(CONFIG_PATH, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2)


def run_cmd(cmd: list[str], timeout: int = 10) -> tuple[int, str, str]:
    """Komut çalıştır, returncode + stdout + stderr döndür."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout.strip(), r.stderr.strip()
    except subprocess.TimeoutExpired:
        return -1, "", "timeout"
    except FileNotFoundError:
        return -1, "", f"command not found: {cmd[0]}"


_prev_cpu_stat: tuple[int, int] | None = None


def _read_proc_stat() -> tuple[int, int] | None:
    """Read (idle, total) jiffies from /proc/stat."""
    try:
        with open("/proc/stat", "r", encoding="utf-8") as f:
            first = f.readline()
        parts = [int(x) for x in first.split()[1:]]
        if len(parts) >= 4:
            idle = parts[3] + (parts[4] if len(parts) > 4 else 0)
            total = sum(parts)
            return idle, total
    except Exception:
        pass
    return None


def get_cpu_usage_percent() -> str:
    """Calculate CPU usage as a percentage (%) from /proc/stat."""
    global _prev_cpu_stat
    cur = _read_proc_stat()
    if cur is None:
        return "N/A"
    if _prev_cpu_stat is None:
        time.sleep(0.08)
        cur2 = _read_proc_stat()
        if cur2 is None:
            _prev_cpu_stat = cur
            return "%0.0"
        prev_idle, prev_total = cur
        cur_idle, cur_total = cur2
        _prev_cpu_stat = cur2
    else:
        prev_idle, prev_total = _prev_cpu_stat
        cur_idle, cur_total = cur
        _prev_cpu_stat = cur

    diff_total = cur_total - prev_total
    diff_idle = cur_idle - prev_idle
    if diff_total <= 0:
        return "%0.0"
    pct = max(0.0, min(100.0, (1.0 - (diff_idle / diff_total)) * 100.0))
    return f"%{pct:.1f}"


def get_gpu_usage_percent(width: int, height: int, fps: int, is_streaming: bool) -> tuple[str, str, str]:
    """VideoCore IV ISP ve Donanımsal MJPEG Encoder tahmini yükünü hesapla."""
    if not is_streaming:
        return "%0.0", "128 MB", "VideoCore IV V4L2 M2M (Boşta)"

    # Full-FOV modunda OV5647 + bcm2835-isp en az 640x480 ham sensör karesi işleyip ölçekler,
    # ardından V4L2 M2M (/dev/video31) çıkış çözünürlüğünü JPEG'e kodlar (~75 MP/s tepe kapasite).
    try:
        w = max(1, width)
        h = max(1, height)
        f = max(1, min(fps, 100))
        isp_pixels = max(w * h, 640 * 480)
        enc_pixels = w * h
        pixels_per_sec = (isp_pixels + enc_pixels) * f
        max_throughput = 75_000_000
        pct = min(100.0, max(1.0, (pixels_per_sec / max_throughput) * 100.0))
        return f"%{pct:.1f}", "128 MB", "VideoCore IV ISP+M2M (~Tahmini)"
    except Exception:
        return "%0.0", "128 MB", "VideoCore IV V4L2 M2M"


def get_system_status() -> dict:
    """Sistem durumu bilgilerini topla (sıfır alt-süreç maliyetiyle doğrudan sysfs ve procfs üzerinden)."""
    status = {}

    # 1. CPU sıcaklığı (doğrudan thermal zone - 0ms, 0% CPU)
    try:
        with open("/sys/class/thermal/thermal_zone0/temp", "r") as f:
            temp_mc = int(f.read().strip())
        status["cpu_temp"] = f"{temp_mc / 1000:.1f}°C"
    except Exception:
        status["cpu_temp"] = "N/A"

    # 2. CPU kullanımı (%)
    status["cpu_load"] = get_cpu_usage_percent()

    # 3. Bellek kullanımı (doğrudan /proc/meminfo - alt-süreç başlatmaz)
    try:
        with open("/proc/meminfo", "r") as f:
            mem_info = {}
            for line in f:
                parts = line.split(":")
                if len(parts) == 2:
                    mem_info[parts[0].strip()] = int(parts[1].split()[0])
            total_mb = mem_info.get("MemTotal", 0) // 1024
            free_mb = mem_info.get("MemAvailable", mem_info.get("MemFree", 0)) // 1024
            used_mb = max(0, total_mb - free_mb)
            status["memory"] = f"{used_mb} MB / {total_mb} MB"
    except Exception:
        status["memory"] = "N/A"

    # 4. Disk kullanımı (statvfs - alt-süreç başlatmaz)
    try:
        st = os.statvfs("/")
        total_gb = (st.f_blocks * st.f_frsize) / (1024**3)
        free_gb = (st.f_bavail * st.f_frsize) / (1024**3)
        used_gb = total_gb - free_gb
        pct = (used_gb / total_gb) * 100 if total_gb > 0 else 0
        status["disk"] = f"{used_gb:.1f}G / {total_gb:.1f}G (%{pct:.0f} kullanıldı)"
    except Exception:
        status["disk"] = "N/A"

    # 5. Uptime (doğrudan /proc/uptime)
    try:
        with open("/proc/uptime", "r") as f:
            secs = int(float(f.read().split()[0]))
            days, rem = divmod(secs, 86400)
            hours, rem = divmod(rem, 3600)
            mins, _ = divmod(rem, 60)
            parts = []
            if days:
                parts.append(f"{days} gün")
            if hours:
                parts.append(f"{hours} saat")
            parts.append(f"{mins} dakika")
            status["uptime"] = " ".join(parts) if parts else "< 1 dakika"
    except Exception:
        status["uptime"] = "N/A"

    # 6. Hostname ve IP
    try:
        status["hostname"] = socket.gethostname()
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(0.1)
        s.connect(("8.8.8.8", 80))
        status["ip_addresses"] = s.getsockname()[0]
        s.close()
    except Exception:
        status["hostname"] = socket.gethostname()
        status["ip_addresses"] = "127.0.0.1"

    # 7. UVC ve Web servis durumu
    uvc_active = False
    try:
        udc_path = Path("/sys/kernel/config/usb_gadget/pi_uvc/UDC")
        if udc_path.exists() and udc_path.read_text(encoding="utf-8").strip():
            uvc_active = True
    except Exception:
        pass
    status["uvc_active"] = uvc_active
    status["uvc_status"] = "active" if uvc_active else "inactive"
    status["web_status"] = "active"

    # 8. Kamera algılama (aktif yayını ve I2C veri yolunu kesmemek için sysfs üzerinden oku)
    camera_detected = False
    camera_label = "Kamera algılanamadı ✗"
    try:
        v4l_dir = Path("/sys/class/video4linux")
        if v4l_dir.exists():
            for subdev in sorted(v4l_dir.glob("v4l-subdev*")):
                name_file = subdev / "name"
                if name_file.exists():
                    sub_name = name_file.read_text(encoding="utf-8", errors="ignore").strip().lower()
                    if "ov5647" in sub_name:
                        camera_label = "OV5647 algılandı ✓"
                        camera_detected = True
                        break
                    if "imx219" in sub_name:
                        camera_label = "IMX219 algılandı ✓"
                        camera_detected = True
                        break
                    if "ov9281" in sub_name:
                        camera_label = "OV9281 algılandı ✓"
                        camera_detected = True
                        break
    except Exception:
        pass

    status["camera"] = camera_label
    status["camera_detected"] = camera_detected

    # UVC gadget cihazı
    uvc_dev = find_uvc_device()
    status["uvc_device"] = uvc_dev if uvc_dev else "Gadget cihazı bulunamadı"

    # Role, Sensör, FPS ve Çözünürlük bilgisi
    env = load_default_env()
    role = env.get("ROLE", "eye0")
    sensor = env.get("SENSOR", "ov5647")
    fps = env.get("FPS", "90")
    width = env.get("WIDTH", "640")
    height = env.get("HEIGHT", "480")

    status["role"] = role
    status["role_title"] = ROLE_INFO.get(role, {}).get("title", role)
    status["role_label"] = ROLE_INFO.get(role, {}).get("label", role)
    status["role_product"] = ROLE_INFO.get(role, {}).get("product", role)
    status["sensor"] = sensor
    status["sensor_name"] = SENSOR_INFO.get(sensor, {}).get("name", sensor)
    status["sensor_description"] = SENSOR_INFO.get(sensor, {}).get("description", sensor)
    status["fps"] = fps
    status["width"] = width
    status["height"] = height
    status["resolution"] = f"{width}x{height} @ {fps}fps"

    # GPU Kullanımı (VideoCore IV ISP & Donanımsal Encoder)
    try:
        w_int = int(width)
        h_int = int(height)
        f_int = int(fps)
    except (ValueError, TypeError):
        w_int, h_int, f_int = 640, 480, 90
    gpu_pct, gpu_mem, gpu_stat = get_gpu_usage_percent(w_int, h_int, f_int, status.get("uvc_active", False))
    status["gpu_load"] = gpu_pct
    status["gpu_mem"] = gpu_mem
    status["gpu_status"] = gpu_stat

    # USB MaxPacket & Aktif Kamera Kontrol Durumu
    try:
        mp_path = Path("/sys/kernel/config/usb_gadget/pi_uvc/functions/uvc.usb0/streaming_maxpacket")
        if mp_path.exists():
            mp_val = mp_path.read_text(encoding="utf-8").strip()
            status["usb_maxpacket"] = mp_val if mp_val else "1024"
        else:
            status["usb_maxpacket"] = "1024"
    except Exception:
        status["usb_maxpacket"] = "1024"

    # Fast-Crop (Yüksek FPS Kırpma) ayarları ve sysfs durumu
    cfg = load_config()
    status["fast_crop"] = cfg.get("fast_crop", DEFAULT_CONFIG["fast_crop"].copy())
    status["spatial_denoise"] = bool(cfg.get("spatial_denoise", True))
    status["auto_exposure"] = bool(cfg.get("auto_exposure", True))
    try:
        status["exposure_value"] = int(cfg.get("exposure_value", 5000))
    except (ValueError, TypeError):
        status["exposure_value"] = 5000
    try:
        status["analogue_gain"] = float(cfg.get("analogue_gain", 8.0))
    except (ValueError, TypeError):
        status["analogue_gain"] = 8.0
    try:
        fc_sys = Path("/sys/module/ov5647/parameters/fast_crop")
        if fc_sys.exists():
            val = fc_sys.read_text(encoding="utf-8").strip()
            status["fast_crop_sysfs"] = (val in ("Y", "1"))
        else:
            status["fast_crop_sysfs"] = None
    except Exception:
        status["fast_crop_sysfs"] = None

    return status


def find_uvc_device() -> str | None:
    """UVC gadget /dev/video* cihazını bul."""
    try:
        # Check /sys/class/video4linux nodes without spawning v4l2-ctl
        v4l_dir = Path("/sys/class/video4linux")
        if v4l_dir.exists():
            for v_entry in sorted(v4l_dir.iterdir()):
                if not v_entry.name.startswith("video"):
                    continue
                name_file = v_entry / "name"
                if name_file.exists():
                    try:
                        name = name_file.read_text(encoding="utf-8").strip().lower()
                        if "uvcg" in name or "uvc" in name or ".usb" in name or "gadget" in name:
                            return f"/dev/{v_entry.name}"
                    except Exception:
                        pass
        # Fallback: probe with v4l2-ctl
        for entry in sorted(Path("/dev").glob("video*")):
            dev = str(entry)
            rc, out, _ = run_cmd(["v4l2-ctl", "--device", dev, "--info"])
            if rc == 0 and ("uvcg" in out or "UVC" in out):
                return dev
    except Exception:
        pass
    return None


def find_camera_control_devices() -> list[str]:
    """Kamera kontrollerini destekleyen /dev/v4l-subdev* ve video yakalama cihazlarını bul."""
    devices = []
    # 1. /dev/v4l-subdev* (CSI sensör alt cihazları)
    try:
        for entry in sorted(Path("/dev").glob("v4l-subdev*")):
            devices.append(str(entry))
    except Exception:
        pass

    # 2. /dev/video* (bcm2835-unicam veya bcm2835-v4l2 video giriş cihazları - UVC hariç)
    try:
        for entry in sorted(Path("/dev").glob("video*")):
            dev = str(entry)
            rc, out, _ = run_cmd(["v4l2-ctl", "--device", dev, "--info"])
            if rc == 0 and ("uvcg" not in out and "UVC" not in out):
                devices.append(dev)
    except Exception:
        pass

    return devices


def apply_runtime_camera_controls(config: dict) -> dict:
    """Kamera ayarlarını (pozlama, parlaklık, kontrast, flip) USB gadget ve UVC servisini
    kesmeden doğrudan V4L2 üzerinden canlı olarak uygular."""
    ctrl_devices = find_camera_control_devices()

    for dev in ctrl_devices:
        # Flip kontrolleri
        if "hflip" in config:
            val = 1 if config["hflip"] else 0
            run_cmd(["v4l2-ctl", "--device", dev, "--set-ctrl", f"horizontal_flip={val}"])
        if "vflip" in config:
            val = 1 if config["vflip"] else 0
            run_cmd(["v4l2-ctl", "--device", dev, "--set-ctrl", f"vertical_flip={val}"])

        # Pozlama (Otomatik / Manuel)
        if "auto_exposure" in config:
            auto_exp = bool(config["auto_exposure"])
            if auto_exp:
                run_cmd(["v4l2-ctl", "--device", dev, "--set-ctrl", "auto_exposure=0"])
                run_cmd(["v4l2-ctl", "--device", dev, "--set-ctrl", "exposure_auto=0"])
            else:
                run_cmd(["v4l2-ctl", "--device", dev, "--set-ctrl", "auto_exposure=1"])
                run_cmd(["v4l2-ctl", "--device", dev, "--set-ctrl", "exposure_auto=1"])
                if "exposure_value" in config:
                    exp_val = int(config["exposure_value"])
                    run_cmd(["v4l2-ctl", "--device", dev, "--set-ctrl", f"exposure_time_absolute={exp_val}"])
                    run_cmd(["v4l2-ctl", "--device", dev, "--set-ctrl", f"exposure={exp_val}"])

        # Görüntü kalitesi ve kazanç kontrolleri
        for key in ("brightness", "contrast", "saturation", "sharpness"):
            if key in config:
                val = int(config[key])
                run_cmd(["v4l2-ctl", "--device", dev, "--set-ctrl", f"{key}={val}"])

        if "analogue_gain" in config:
            gain_val = max(1, min(16, int(round(float(config["analogue_gain"])))))
            run_cmd(["v4l2-ctl", "--device", dev, "--set-ctrl", f"analogue_gain={gain_val}"])

    return {"devices": ctrl_devices, "status": "applied"}


# =============================================================================
# Web Route'ları
# =============================================================================

@app.route("/")
def index():
    """Ana sayfa — kontrol paneli."""
    config = load_config()
    status = get_system_status()
    env = load_default_env()
    return render_template(
        "index.html",
        config=config,
        status=status,
        env=env,
        roles=ROLE_INFO,
        sensors=SENSOR_INFO,
    )


# ---- API: Sistem Durumu ----

@app.route("/api/status")
def api_status():
    """Sistem durumunu JSON olarak döndür."""
    return jsonify(get_system_status())


# ---- API: Konfigürasyon ----

@app.route("/api/config", methods=["GET"])
def api_get_config():
    """Mevcut konfigürasyonu döndür."""
    return jsonify(load_config())


@app.route("/api/config", methods=["POST"])
def api_set_config():
    """Konfigürasyonu güncelle ve servisi yeniden başlat."""
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return jsonify({"status": "error", "message": "Geçersiz veya boş JSON nesnesi"}), 400

    config = load_config()

    # Boolean alanlar
    for key in ("hflip", "vflip", "auto_exposure", "spatial_denoise"):
        if key in data:
            config[key] = bool(data[key])

    # Sayısal alanlar (0-100), exposure ve analogue_gain
    try:
        for key in ("brightness", "contrast", "saturation", "sharpness"):
            if key in data:
                val = int(data[key])
                config[key] = max(0, min(100, val))

        if "exposure_value" in data:
            config["exposure_value"] = max(1, min(100000, int(data["exposure_value"])))

        if "analogue_gain" in data:
            config["analogue_gain"] = round(max(1.0, min(16.0, float(data["analogue_gain"]))), 1)
    except (ValueError, TypeError):
        return jsonify({"status": "error", "message": "Sayısal parametreler geçerli sayı olmalıdır"}), 400

    # AWB modu
    if "awb_mode" in data:
        allowed = ("auto", "daylight", "cloudy", "tungsten", "fluorescent", "indoor")
        if data["awb_mode"] in allowed:
            config["awb_mode"] = data["awb_mode"]

    # Fast-Crop sözlüğü
    if "fast_crop" in data and isinstance(data["fast_crop"], dict):
        if "fast_crop" not in config or not isinstance(config["fast_crop"], dict):
            config["fast_crop"] = DEFAULT_CONFIG["fast_crop"].copy()
        for res_key, is_on in data["fast_crop"].items():
            config["fast_crop"][str(res_key)] = bool(is_on)

    save_config(config)

    # Runtime kamera kontrollerini USB bağlantısını ve uvc-gadget servisini kesmeden canlı olarak uygula
    try:
        apply_runtime_camera_controls(config)
    except Exception:
        pass

    return jsonify({
        "status": "ok",
        "config": config,
        "restart": "Ayarlar canlı uygulandı (bağlantı kesilmedi)",
    })


@app.route("/api/fast_crop", methods=["GET", "POST"])
def api_fast_crop():
    """Çözünürlük bazında Hızlı Kırpma (High-FPS Center Crop) ayarlarını yönet."""
    config = load_config()
    if "fast_crop" not in config or not isinstance(config["fast_crop"], dict):
        config["fast_crop"] = DEFAULT_CONFIG["fast_crop"].copy()

    if request.method == "POST":
        data = request.get_json(silent=True)
        if not isinstance(data, dict):
            return jsonify({"status": "error", "message": "Geçersiz veya boş JSON nesnesi"}), 400

        for res_key, is_enabled in data.items():
            config["fast_crop"][str(res_key)] = bool(is_enabled)

        save_config(config)

        # Aktif seçili çözünürlük için sysfs parametresini canlı güncelle
        try:
            cur_w = int(config.get("width", 640))
            cur_h = int(config.get("height", 480))
            res_key = f"{cur_w}x{cur_h}"
            active_val = config["fast_crop"].get(res_key, False)
            fc_path = Path("/sys/module/ov5647/parameters/fast_crop")
            if fc_path.exists():
                fc_path.write_text("1\n" if active_val else "0\n", encoding="utf-8")
        except Exception:
            pass

        return jsonify({
            "status": "ok",
            "fast_crop": config["fast_crop"],
            "message": "Çözünürlük kırpma tercihleri canlı olarak uygulandı",
        })

    return jsonify({
        "status": "ok",
        "fast_crop": config["fast_crop"],
    })


PRESET_RESOLUTIONS = {(192, 192), (320, 240), (400, 400), (640, 480), (800, 600), (1280, 720)}


def schedule_safe_reboot():
    """USB descriptor değişikliklerini (rol / özel çözünürlük) güvenle uygular.

    Neden reboot: canlı bir UVC akışı varken UDC'yi unbind etmek (systemctl restart
    uvc-gadget -> setup-gadget.sh start -> stop_gadget) Pi Zero'nun dwc2 sürücüsünü
    kilitliyor ve Pi'yi Wi-Fi dahil tamamen erişilemez yapıyor. Temiz bir açılışta
    gadget, host akışı açmadan önce kurulduğu için bu risk yok.
    """
    def _worker():
        time.sleep(1.5)  # HTTP yanıtı tarayıcıya ulaşsın
        run_cmd(["systemctl", "stop", "uvc-gadget"], timeout=5)
        try:
            udc_path = Path("/sys/kernel/config/usb_gadget/pi_uvc/UDC")
            if udc_path.exists():
                udc_path.write_text("\n", encoding="utf-8")
                time.sleep(0.5)
        except Exception:
            pass
        run_cmd(["systemctl", "reboot"], timeout=10)

    threading.Thread(target=_worker, daemon=True).start()


def restart_uvc_service_async():
    """Geriye dönük uyumluluk: artık canlı UDC restart yerine güvenli reboot planlar."""
    schedule_safe_reboot()


# ---- API: Rol Seçimi (Pupil Capture Eye0/Eye1/World/Generic) ----

@app.route("/api/role", methods=["POST"])
def api_set_role():
    """Kamera rolünü değiştir (eye0, eye1, world, generic) ve /etc/default/picam-uvc dosyasını güncelle."""
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return jsonify({"status": "error", "message": "Geçersiz veya boş JSON nesnesi"}), 400
    if "role" not in data:
        return jsonify({"status": "error", "message": "'role' alanı gereklidir"}), 400

    role = str(data["role"]).strip().lower()
    if role not in ROLE_INFO:
        return jsonify({
            "status": "error",
            "message": f"Geçersiz rol '{role}'. Desteklenen roller: {list(ROLE_INFO.keys())}"
        }), 400

    old_role = load_default_env().get("ROLE")
    env = save_default_env({"ROLE": role})

    needs_reboot = role != old_role
    if needs_reboot:
        schedule_safe_reboot()

    return jsonify({
        "status": "ok",
        "role": role,
        "role_title": ROLE_INFO[role]["title"],
        "reboot": needs_reboot,
        "restart": "USB kimliği değişti: Pi güvenli şekilde yeniden başlatılıyor (~45 sn)" if needs_reboot else "Rol zaten aktif",
        "env": env,
    })


# ---- API: Sensör Profili Seçimi (OV5647, IMX219, OV9281) ----

@app.route("/api/sensor", methods=["POST"])
def api_set_sensor():
    """Sensör profilini değiştir (ov5647, imx219, ov9281) ve /etc/default/picam-uvc dosyasını güncelle."""
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return jsonify({"status": "error", "message": "Geçersiz veya boş JSON nesnesi"}), 400
    if "sensor" not in data:
        return jsonify({"status": "error", "message": "'sensor' alanı gereklidir"}), 400

    sensor = str(data["sensor"]).strip().lower()
    if sensor not in SENSOR_INFO:
        return jsonify({
            "status": "error",
            "message": f"Geçersiz sensör '{sensor}'. Desteklenen sensörler: {list(SENSOR_INFO.keys())}"
        }), 400

    # Validate FPS
    fps_raw = data.get("fps")
    if fps_raw is None:
        fps_val = str(SENSOR_INFO[sensor]["default_fps"])
    else:
        fps_val = str(fps_raw).strip()

    allowed_fps = [15, 30, 60, 90, 120]
    if not fps_val.isdigit() or int(fps_val) not in allowed_fps:
        return jsonify({"status": "error", "message": "Geçersiz FPS değeri. Desteklenen: 15, 30, 60, 90, 120"}), 400

    # Validate Width and Height (supports presets and custom resolutions)
    width_raw = data.get("width")
    width_val = "640" if width_raw is None else str(width_raw).strip()

    height_raw = data.get("height")
    height_val = "480" if height_raw is None else str(height_raw).strip()

    try:
        w_int = int(width_val)
        h_int = int(height_val)
        if w_int < 160 or w_int > 1920 or h_int < 120 or h_int > 1080:
            return jsonify({"status": "error", "message": "Çözünürlük 160x120 ile 1920x1080 arasında olmalıdır"}), 400
        if w_int % 2 != 0 or h_int % 2 != 0:
            return jsonify({"status": "error", "message": "Çözünürlük değerleri çift sayı (even) olmalıdır"}), 400
    except (ValueError, TypeError):
        return jsonify({"status": "error", "message": "Geçersiz çözünürlük formatı"}), 400

    updates = {
        "SENSOR": sensor,
        "FPS": fps_val,
        "WIDTH": str(w_int),
        "HEIGHT": str(h_int),
    }

    # İsteğe bağlı olarak role de gönderilmişse tek seferde kaydet
    if "role" in data:
        r = str(data["role"]).strip().lower()
        if r in ROLE_INFO:
            updates["ROLE"] = r

    old_env = load_default_env()
    env = save_default_env(updates)

    # Sync to config.json as well
    cfg = load_config()
    cfg["sensor"] = sensor
    cfg["fps"] = int(fps_val)
    cfg["width"] = w_int
    cfg["height"] = h_int
    if "role" in data and str(data["role"]).strip().lower() in ROLE_INFO:
        cfg["role"] = str(data["role"]).strip().lower()
    save_config(cfg)

    # Tüm hazır çözünürlükler ve FPS değerleri USB descriptor'larında ZATEN kayıtlı;
    # hangisinin kullanılacağını Pupil Capture (host) seçer. Bu yüzden FPS/hazır
    # çözünürlük değişikliği için USB'yi yeniden kurmaya gerek yok.
    role_changed = updates.get("ROLE", old_env.get("ROLE")) != old_env.get("ROLE")
    old_res = (old_env.get("WIDTH"), old_env.get("HEIGHT"))
    custom_changed = (w_int, h_int) not in PRESET_RESOLUTIONS and old_res != (str(w_int), str(h_int))
    needs_reboot = role_changed or custom_changed

    if needs_reboot:
        schedule_safe_reboot()
        msg = "USB kimliği değişti: Pi güvenli şekilde yeniden başlatılıyor (~45 sn)"
    else:
        msg = "Kaydedildi. Çözünürlük/FPS'i Pupil Capture içinden seçin (yeniden başlatma gerekmez)"

    return jsonify({
        "status": "ok",
        "sensor": sensor,
        "fps": fps_val,
        "width": env.get("WIDTH", "640"),
        "height": env.get("HEIGHT", "480"),
        "resolution": f"{w_int}x{h_int} @ {fps_val}fps",
        "reboot": needs_reboot,
        "restart": msg,
        "env": env,
    })


# ---- API: Servis Yönetimi ----

@app.route("/api/service/<action>")
def api_service(action: str):
    """UVC servisini başlat/durdur/yeniden başlat."""
    if action not in ("start", "stop", "restart", "status"):
        return jsonify({"status": "error", "message": "Geçersiz eylem"}), 400

    if action == "status":
        rc, out, _ = run_cmd(["systemctl", "status", "uvc-gadget"])
        return jsonify({"status": "ok", "output": out})

    rc, out, err = run_cmd(["systemctl", action, "uvc-gadget"], timeout=15)
    return jsonify({
        "status": "ok" if rc == 0 else "error",
        "action": action,
        "output": out,
        "error": err,
    })


@app.route("/api/reboot")
def api_reboot():
    """Sistemi yeniden başlat."""
    subprocess.Popen(["sudo", "reboot"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return jsonify({"status": "ok", "message": "Sistem yeniden başlatılıyor..."})


# =============================================================================
# Uygulama Başlatma
# =============================================================================

if __name__ == "__main__":
    # İlk çalıştırmada default config ve environment dosyası oluştur
    if not CONFIG_PATH.exists():
        save_config(DEFAULT_CONFIG)
        print(f"[i] Default konfigürasyon oluşturuldu: {CONFIG_PATH}")
    if not DEFAULT_ENV_PATH.exists():
        save_default_env(DEFAULT_ENV_CONFIG)
        print(f"[i] Default environment dosyası oluşturuldu: {DEFAULT_ENV_PATH}")

    print("=" * 50)
    print("  Pi Zero UVC Camera - Web Kontrol Paneli")
    print(f"  http://0.0.0.0:8080")
    print("=" * 50)

    app.run(host="0.0.0.0", port=8080, debug=False, threaded=True)
