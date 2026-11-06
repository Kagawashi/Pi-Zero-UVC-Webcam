# 📷 Pi Zero UVC Camera & Pupil Labs Eye Tracker

[![Raspberry Pi](https://img.shields.io/badge/Raspberry%20Pi-Zero%20W%20%7C%20Zero%202W-red.svg?logo=raspberry-pi)](https://www.raspberrypi.com/)
[![USB Gadget](https://img.shields.io/badge/USB%20Gadget-UVC%201.10%20ConfigFS-blue.svg)](https://www.kernel.org/doc/html/latest/usb/gadget_configfs.html)
[![Pupil Labs](https://img.shields.io/badge/Pupil%20Labs-Pupil%20Cam1%20ID0-brightgreen.svg)](https://pupil-labs.com/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Python](https://img.shields.io/badge/Python-3.9%2B-yellow.svg)](https://www.python.org/)

Turn your **Raspberry Pi Zero W** or **Pi Zero 2W** with a CSI camera into a high-performance **USB UVC Webcam** that behaves as an authentic **Pupil Labs Eye Tracking Camera (`Pupil Cam1 ID0/ID1/ID2`)** or a standard plug-and-play webcam.

Includes **90 FPS hardware MJPEG streaming**, a browser-based **Web Control Panel (`:8080`)**, and an automatic **Pupil Capture plugin** with in-memory crash prevention and an in-app resolution/FPS selector.

---

## ✨ Features

- **🎯 Authentic Pupil Labs Emulation**: Full USB descriptors, VID/PID (`0x05a3:0x9230`), and serial numbers recognized immediately by **Pupil Capture** as `Pupil Cam1 ID0` (eye0), `ID1` (eye1), or `ID2` (world).
- **🚀 90 FPS Hardware Encoding**: Leverages Broadcom VideoCore IV hardware MJPEG encoder to achieve up to **90 FPS @ 640×480** with low latency on a lightweight Pi Zero.
- **🔌 Dual-Function Composite Gadget (Direct USB SSH)**: Simultaneously exposes both a UVC Webcam and an Ethernet adapter (RNDIS). Connect to SSH (`ssh pi@pizero.local`) and the web dashboard directly through the single USB cable without any Wi-Fi network!
- **🌐 Web Control Panel (:8080)**: On-device Flask web service to switch camera roles, flip orientation, adjust brightness/contrast, and restart services from any browser.
- **🌍 Multi-Wi-Fi Network Roaming**: Pre-configure multiple Wi-Fi networks (home router, mobile hotspot, lab); Pi Zero auto-connects to whichever is in range.
- **🛡️ Pupil Capture Windows Patch**:
  - Memory hotpatch for the notorious `uvc.dll` zero-division crash (`0xc0000094`).
  - `SafeSelector` monkey patch preventing PyGLUI Cython crashes when selecting resolutions.
  - Interactive **"Pi Zero Camera Settings"** menu inside Pupil Capture's Eye0 window.
- **⚡ 1-Command Installation**: Bulletproof installer detecting Raspberry Pi OS (Bookworm & Bullseye), automatically configuring boot overlays, compiling UVC gadget, and enabling systemd daemons.

---

## 🏗️ Architecture

```mermaid
graph LR
    subgraph PiZero["Raspberry Pi Zero W / 2W"]
        CSI["CSI Camera Module\n(OV5647 / IMX219 / OV9281)"] -->|RAW/Bayer| VC4["VideoCore IV GPU\nHardware MJPEG"]
        VC4 -->|/dev/video0| UVCG["uvc-gadget\nUser Daemon"]
        UVCG -->|ConfigFS| DWC2["dwc2 USB Controller\n(OTG Peripheral)"]
        WEB["picam-web (:8080)\nFlask Dashboard"] -.->|Config JSON| UVCG
    end

    subgraph HostPC["Host PC (Windows / Linux / macOS)"]
        DWC2 ==>|Micro USB Data Cable| USB["libusb / UVC Driver\n(Pupil Cam1 ID0)"]
        USB --> PCAP["Pupil Capture / OpenCV / OBS"]
        PEXP["pi_zero_uvc_patch.py\n(Crash Patch & UI Menu)"] --> PCAP
    end
```

---

## 📦 Hardware Requirements

| Component | Recommendation | Note |
|---|---|---|
| **Board** | Raspberry Pi Zero W or Pi Zero 2W | Built-in Wi-Fi enables the web control panel. |
| **Camera** | OV5647, IMX219, or OV9281 | OV5647 (Pi Cam v1) supports 640x480 @ 90 FPS natively. |
| **Flex Cable** | 15-pin to 22-pin mini CSI cable | Required for the smaller CSI port on Pi Zero. |
| **USB Cable** | **Micro USB Data Cable** | ⚠️ Must have data lines (D+/D-). Do **not** use charge-only cables! |
| **SD Card** | 8 GB+ Class 10 MicroSD | Raspberry Pi OS Lite (32-bit or 64-bit). |

> ⚠️ **CRITICAL USB CONNECTION**:  
> Pi Zero has two Micro USB ports. Connect the cable to the **middle USB (Data)** port, **NOT** the outer `PWR IN` port! The USB port supplies both power and data to the Pi Zero.

---

## 🚀 Quick Start (Pi Zero Installation)

### Step 1: Prepare SD Card
Flash **Raspberry Pi OS Lite** using [Raspberry Pi Imager](https://www.raspberrypi.com/software/).  
In OS Customization settings (`Ctrl + Shift + X`):
- Set Hostname: `makinalasmak` (or your preferred name)
- Set Username & Password: e.g. `pi` / `raspberry`
- Enable Wi-Fi & SSH

### Step 2: SSH into Pi Zero & Run Installer
Once booted and connected to your network:

```bash
# 1. Connect via SSH
ssh pi@makinalasmak.local

# 2. Clone the repository
git clone https://github.com/muratcankoylan/pi-zero-uvc-cam.git

# 3. Run the automated installer
cd pi-zero-uvc-cam
sudo bash install.sh
```

*(The installer will configure `/boot/firmware/config.txt`, compile `uvc-gadget`, install services, and offer to reboot).*

---

## 💻 Windows & Pupil Capture Setup

To connect to **Pupil Capture** without crashes:

1. Open PowerShell on Windows and navigate to the `windows` folder:
   ```powershell
   cd windows
   powershell -ExecutionPolicy Bypass -File .\install_plugin.ps1
   ```
2. Plug the Pi Zero into your PC via the **USB data port**.
3. Launch Pupil Capture:
   ```powershell
   Start-Process "C:\Program Files (x86)\Pupil-Labs\Pupil v3.5.1\Pupil Capture v3.5.1\pupil_capture.exe" -ArgumentList "--skip-driver-installation"
   ```
4. In the **Eye 0 window**, press `C` to reveal the **Pi Zero Camera Settings** panel to adjust resolution (`640x480`, `1280x720`) and FPS (`15` to `90` / `120`).

---

## 🔍 What Gets Installed on the Pi Zero?

| Component | Destination | Description |
|---|---|---|
| **Kernel Overlays** | `/boot/firmware/config.txt` | `dtoverlay=dwc2,dr_mode=peripheral`, `gpu_mem=128`, `camera_auto_detect=1` |
| **Kernel Modules** | `/etc/modules` & `cmdline.txt` | Loads `dwc2` and `libcomposite` for USB ConfigFS support. |
| **UVC Gadget Engine** | `/usr/local/bin/uvc-gadget` | Patched UVC daemon bridging V4L2 video stream to USB endpoint. |
| **ConfigFS Script** | `/usr/local/bin/setup-gadget.sh` | Builds the USB descriptors, formats, and vendor identity. |
| **Stream Wrapper** | `/usr/local/bin/start-uvc.sh` | Orchestrates hardware encoding and starts streaming on USB connect. |
| **Web Service** | `/opt/picam-web/` | Flask web control dashboard on port `8080`. |
| **Systemd Units** | `/etc/systemd/system/` | `uvc-gadget.service` and `picam-web.service` (auto-start on boot). |
| **Configuration** | `/etc/picam/config.json` | Persistent camera and hardware settings. |

---

## 🌐 Web Control Panel

Access the dashboard from any browser on the local network:
```
http://makinalasmak.local:8080
# or http://<pi-zero-ip>:8080
```

- **Roles**: `eye0` (Pupil Eye 0), `eye1` (Pupil Eye 1), `world` (Scene Cam), `generic` (Standard UVC Webcam).
- **Controls**: Real-time Horizontal/Vertical Flip, Brightness, Contrast, Saturation, Sharpness.
- **Service Management**: Instant service restart and hardware status monitoring.

---

## 🛠️ CLI Diagnostics

```bash
# Check UVC streaming service
sudo systemctl status uvc-gadget

# View live stream logs
sudo journalctl -u uvc-gadget -f

# Verify camera sensor
vcgencmd get_camera
v4l2-ctl --list-devices

# Verify USB Gadget status
sudo /usr/local/bin/setup-gadget.sh status
```

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
Pupil Labs is a registered trademark of Pupil Labs GmbH. This open-source project is independently developed for academic and developer applications.
