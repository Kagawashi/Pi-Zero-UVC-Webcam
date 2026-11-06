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
    "hflip": False,
    "vflip": False,
    "brightness": 50,       # 0-100 (50 = normal)
    "contrast": 50,         # 0-100 (50 = normal)
    "saturation": 50,       # 0-100 (50 = normal)
    "sharpness": 50,        # 0-100 (50 = normal)
    "auto_exposure": True,
    "exposure_value": 1000, # µs (manuel mod için)
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
    try:
        if CONFIG_PATH.exists():
            with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                saved = json.load(f)
            config = DEFAULT_CONFIG.copy()
            config.update(saved)
            return config
    except (json.JSONDecodeError, IOError):
        pass
    return DEFAULT_CONFIG.copy()


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


def get_system_status() -> dict:
    """Sistem durumu bilgilerini topla."""
    status = {}

    # CPU sıcaklığı
    rc, out, _ = run_cmd(["vcgencmd", "measure_temp"])
    if rc == 0:
        status["cpu_temp"] = out.replace("temp=", "").replace("'C", "°C")
    else:
        # Fallback: thermal zone
        try:
            with open("/sys/class/thermal/thermal_zone0/temp") as f:
                temp_mc = int(f.read().strip())
            status["cpu_temp"] = f"{temp_mc / 1000:.1f}°C"
        except (IOError, ValueError):
            status["cpu_temp"] = "N/A"

    # CPU yükü
    try:
        if hasattr(os, "getloadavg"):
            load = os.getloadavg()
            status["cpu_load"] = f"{load[0]:.2f} / {load[1]:.2f} / {load[2]:.2f}"
        else:
            status["cpu_load"] = "N/A"
    except (OSError, AttributeError):
        status["cpu_load"] = "N/A"

    # Bellek kullanımı
    rc, out, _ = run_cmd(["free", "-m"])
    if rc == 0:
        lines = out.split("\n")
        if len(lines) >= 2:
            parts = lines[1].split()
            total, used = parts[1], parts[2]
            status["memory"] = f"{used} MB / {total} MB"
        else:
            status["memory"] = "N/A"
    else:
        status["memory"] = "N/A"

    # Disk kullanımı
    rc, out, _ = run_cmd(["df", "-h", "/"])
    if rc == 0:
        lines = out.split("\n")
        if len(lines) >= 2:
            parts = lines[1].split()
            status["disk"] = f"{parts[2]} / {parts[1]} ({parts[4]} kullanıldı)"
        else:
            status["disk"] = "N/A"
    else:
        status["disk"] = "N/A"

    # Uptime
    rc, out, _ = run_cmd(["uptime", "-p"])
    status["uptime"] = out if rc == 0 else "N/A"

    # Hostname ve IP
    status["hostname"] = socket.gethostname()
    rc, out, _ = run_cmd(["hostname", "-I"])
    status["ip_addresses"] = out if rc == 0 else "N/A"

    # UVC servis durumu
    rc, out, _ = run_cmd(["systemctl", "is-active", "uvc-gadget"])
    status["uvc_active"] = out == "active"
    status["uvc_status"] = out

    # Web servis durumu
    rc, out, _ = run_cmd(["systemctl", "is-active", "picam-web"])
    status["web_status"] = out

    # Kamera algılama
    rc, out, _ = run_cmd(["libcamera-hello", "--list-cameras"], timeout=5)
    if rc == 0 and "ov5647" in out.lower():
        status["camera"] = "OV5647 algılandı ✓"
        status["camera_detected"] = True
    elif rc == 0 and "imx219" in out.lower():
        status["camera"] = "IMX219 algılandı ✓"
        status["camera_detected"] = True
    elif rc == 0 and "ov9281" in out.lower():
        status["camera"] = "OV9281 algılandı ✓"
        status["camera_detected"] = True
    elif rc == 0 and "Available cameras" in out:
        status["camera"] = out.split("\n")[0]
        status["camera_detected"] = True
    else:
        status["camera"] = "Kamera algılanamadı ✗"
        status["camera_detected"] = False

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

    return status


def find_uvc_device() -> str | None:
    """UVC gadget /dev/video* cihazını bul."""
    try:
        # Check /sys/class/video4linux nodes
        v4l_dir = Path("/sys/class/video4linux")
        if v4l_dir.exists():
            for v_entry in sorted(v4l_dir.iterdir()):
                name_file = v_entry / "name"
                if name_file.exists():
                    try:
                        name = name_file.read_text(encoding="utf-8").strip()
                        if "uvcg" in name or "uvc" in name.lower():
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

        # Görüntü kalitesi kontrolleri (0-100)
        for key in ("brightness", "contrast", "saturation", "sharpness"):
            if key in config:
                val = int(config[key])
                run_cmd(["v4l2-ctl", "--device", dev, "--set-ctrl", f"{key}={val}"])

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
    for key in ("hflip", "vflip", "auto_exposure"):
        if key in data:
            config[key] = bool(data[key])

    # Sayısal alanlar (0-100) ve exposure
    try:
        for key in ("brightness", "contrast", "saturation", "sharpness"):
            if key in data:
                val = int(data[key])
                config[key] = max(0, min(100, val))

        if "exposure_value" in data:
            config["exposure_value"] = max(1, min(100000, int(data["exposure_value"])))
    except (ValueError, TypeError):
        return jsonify({"status": "error", "message": "Sayısal parametreler geçerli tamsayı olmalıdır"}), 400

    # AWB modu
    if "awb_mode" in data:
        allowed = ("auto", "daylight", "cloudy", "tungsten", "fluorescent", "indoor")
        if data["awb_mode"] in allowed:
            config["awb_mode"] = data["awb_mode"]

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


def restart_uvc_service_async():
    """UVC servisini HTTP isteğini bloklamadan arka planda güvenle yeniden başlatır."""
    def _worker():
        time.sleep(0.3)
        run_cmd(["systemctl", "restart", "uvc-gadget"], timeout=30)

    t = threading.Thread(target=_worker, daemon=True)
    t.start()


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

    env = save_default_env({"ROLE": role})

    # UVC servisini arka planda güvenle yeniden başlat (HTTP bağlantısını bekletme)
    restart_uvc_service_async()

    return jsonify({
        "status": "ok",
        "role": role,
        "role_title": ROLE_INFO[role]["title"],
        "restart": "UVC servisi güncelleniyor (kısa süre içinde aktif olacak)",
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

    # UVC servisini arka planda güvenle yeniden başlat (HTTP bağlantısını bekletme)
    restart_uvc_service_async()

    return jsonify({
        "status": "ok",
        "sensor": sensor,
        "fps": fps_val,
        "width": env.get("WIDTH", "640"),
        "height": env.get("HEIGHT", "480"),
        "resolution": f"{w_int}x{h_int} @ {fps_val}fps",
        "restart": "UVC servisi güncelleniyor (kısa süre içinde aktif olacak)",
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
