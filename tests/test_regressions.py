#!/usr/bin/env python3
"""Deterministic regression tests for Pi Zero UVC Webcam fixes."""

from __future__ import annotations

import importlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


class UvcBandwidthAndConfigFsTests(unittest.TestCase):
    """Ensure USB ISOC maxpacket and MJPEG buffer limits prevent -ENODATA drops."""

    def test_uvc_c_separates_mjpeg_frame_size_from_yuyv(self) -> None:
        uvc_c = (REPO_ROOT / "uvc-gadget" / "lib" / "uvc.c").read_text(encoding="utf-8")
        # Separate YUYV (* 2) from MJPEG (max(w*h, 65536)) so 1024-byte ISOC stays well within budget.
        self.assertRegex(
            uvc_c,
            r"case\s+V4L2_PIX_FMT_YUYV:\s*ctrl->dwMaxVideoFrameSize\s*=\s*frame->width\s*\*\s*frame->height\s*\*\s*2;",
        )
        self.assertRegex(
            uvc_c,
            r"case\s+V4L2_PIX_FMT_MJPEG:[\s\S]*?frame->width\s*\*\s*frame->height[\s\S]*?65536",
        )

    def test_setup_gadget_mock_configfs_values(self) -> None:
        bash = shutil.which("bash") or (
            r"C:\Program Files\Git\bin\bash.exe"
            if Path(r"C:\Program Files\Git\bin\bash.exe").exists()
            else None
        )
        script = REPO_ROOT / "scripts" / "setup-gadget.sh"
        script_txt = script.read_text(encoding="utf-8")
        self.assertIn('echo 1024 > "$FUNC/streaming_maxpacket"', script_txt)
        self.assertNotIn('echo 2048 > "$FUNC/streaming_maxpacket"', script_txt)

        if bash is None:
            self.skipTest("bash not available for live ConfigFS mock run")

        with tempfile.TemporaryDirectory() as tmp:
            # Convert Windows path to POSIX path if running Git Bash
            posix_tmp = tmp.replace("\\", "/")
            if len(posix_tmp) >= 2 and posix_tmp[1] == ":":
                posix_tmp = f"/{posix_tmp[0].lower()}{posix_tmp[2:]}"
            posix_script = str(script).replace("\\", "/")
            if len(posix_script) >= 2 and posix_script[1] == ":":
                posix_script = f"/{posix_script[0].lower()}{posix_script[2:]}"

            cmd = (
                f'CONFIGFS_ROOT="{posix_tmp}" WIDTH=256 HEIGHT=256 '
                f'bash "{posix_script}" eye0 start'
            )
            res = subprocess.run([bash, "-c", cmd], capture_output=True, text=True, check=False)
            # In non-Pi mock env, UDC may not exist at the final bind step; descriptors are written before UDC bind.
            func_dir = Path(tmp) / "usb_gadget" / "pi_uvc" / "functions" / "uvc.usb0"
            if not (func_dir / "streaming_maxpacket").exists():
                self.fail(f"setup-gadget.sh failed before writing descriptors: {res.stdout}\n{res.stderr}")

            self.assertEqual((func_dir / "streaming_maxpacket").read_text().strip(), "1024")
            self.assertEqual((func_dir / "streaming_maxburst").read_text().strip(), "1")
            self.assertEqual((func_dir / "streaming_interval").read_text().strip(), "1")
            self.assertEqual(
                (func_dir / "control" / "header" / "h" / "dwClockFrequency").read_text().strip(),
                "48000000",
            )
            self.assertEqual(
                (func_dir / "streaming" / "mjpeg" / "m" / "480p" / "dwMaxVideoFrameBufferSize").read_text().strip(),
                str(640 * 480),
            )
            self.assertEqual(
                (func_dir / "streaming" / "mjpeg" / "m" / "192p" / "wWidth").read_text().strip(),
                "192",
            )
            self.assertEqual(
                (func_dir / "streaming" / "mjpeg" / "m" / "192p" / "wHeight").read_text().strip(),
                "192",
            )
            self.assertEqual(
                (func_dir / "streaming" / "mjpeg" / "m" / "192p" / "dwMaxVideoFrameBufferSize").read_text().strip(),
                "65536",
            )
            self.assertEqual(
                (func_dir / "streaming" / "mjpeg" / "m" / "custom" / "wWidth").read_text().strip(),
                "256",
            )
            self.assertEqual(
                (func_dir / "streaming" / "mjpeg" / "m" / "custom" / "dwMaxVideoFrameBufferSize").read_text().strip(),
                "65536",
            )
            self.assertEqual(
                (func_dir / "streaming" / "mjpeg" / "m" / "720p" / "dwFrameInterval").read_text().strip().splitlines(),
                ["333333", "666666"],
            )


class LibcameraPerformanceTests(unittest.TestCase):
    """Ensure IPA control caching and fast tuning exclusions are intact."""

    def test_libcamera_source_caches_controls_and_mjpeg_sizeimage(self) -> None:
        src_txt = (REPO_ROOT / "uvc-gadget" / "lib" / "libcamera-source.cpp").read_text(encoding="utf-8")
        for symbol in (
            "controls_applied_",
            "applied_auto_exposure_",
            "spatial_denoise_",
            "applied_spatial_denoise_",
            "analogue_gain_",
            "brightness_",
            "contrast_",
            "saturation_",
            "sharpness_",
            "apply_tuning_controls",
            "src->controls_applied_ = false;",
            "if (fmt->pixelformat == V4L2_PIX_FMT_MJPEG)",
        ):
            self.assertIn(symbol, src_txt)

    def test_start_uvc_fast_tuning_drops_contrast_and_geq_keeps_sdn(self) -> None:
        start_txt = (REPO_ROOT / "scripts" / "start-uvc.sh").read_text(encoding="utf-8")
        # Extract the inline python snippet directly by marker
        m = re.search(r"<<\s*'PYEOF'\n(.*?)\nPYEOF", start_txt, re.DOTALL)
        self.assertIsNotNone(m, "Fast tuning Python block missing in start-uvc.sh")
        py_snippet = m.group(1)

        with tempfile.TemporaryDirectory() as tmp:
            src_json = Path(tmp) / "ov5647.json"
            dst_json = Path(tmp) / "ov5647_fast.json"
            src_json.write_text(
                json.dumps(
                    {
                        "version": 2.0,
                        "target": "bcm2835",
                        "algorithms": [
                            {"rpi.black_level": {"black_level": 1024}},
                            {"rpi.dpc": {}},
                            {"rpi.lux": {"reference_Y": 8961}},
                            {"rpi.noise": {"reference_slope": 4.25}},
                            {"rpi.geq": {"offset": 401}},
                            {"rpi.sdn": {}},
                            {"rpi.awb": {"bayes": 1}},
                            {"rpi.agc": {"channels": [{"exposure_modes": {"normal": {"shutter": [1, 2, 3, 4, 5], "gain": [1, 1, 1, 1, 1]}}}]}},
                            {"rpi.contrast": {"ce_enable": 1}},
                            {"rpi.sharpen": {}},
                            {"rpi.alsc": {}},
                            {"rpi.ccm": {}},
                        ],
                    }
                ),
                encoding="utf-8",
            )
            res = subprocess.run(
                [sys.executable, "-c", py_snippet, str(src_json), str(dst_json)],
                capture_output=True,
                text=True,
                check=True,
            )
            self.assertEqual(res.returncode, 0)
            out = json.loads(dst_json.read_text(encoding="utf-8"))
            names = [next(iter(a.keys())) for a in out["algorithms"]]
            self.assertIn("rpi.sdn", names)
            self.assertNotIn("rpi.contrast", names)
            self.assertNotIn("rpi.geq", names)
            self.assertNotIn("rpi.sharpen", names)
            self.assertNotIn("rpi.alsc", names)
            awb = next(a["rpi.awb"] for a in out["algorithms"] if "rpi.awb" in a)
            self.assertEqual(awb["bayes"], 0)


class WebAppAndFastCropRegressionTests(unittest.TestCase):
    """Ensure fast_crop defaults to False everywhere and GPU metric stays realistic."""

    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory()
        os.environ["PICAM_CONFIG_PATH"] = str(Path(self._tmpdir.name) / "config.json")
        os.environ["PICAM_DEFAULT_ENV"] = str(Path(self._tmpdir.name) / "picam-uvc")
        sys.path.insert(0, str(REPO_ROOT / "web"))
        if "app" in sys.modules:
            self.app_mod = importlib.reload(sys.modules["app"])
        else:
            import app as app_mod  # type: ignore
            self.app_mod = app_mod

    def tearDown(self) -> None:
        os.environ.pop("PICAM_CONFIG_PATH", None)
        os.environ.pop("PICAM_DEFAULT_ENV", None)
        if str(REPO_ROOT / "web") in sys.path:
            sys.path.remove(str(REPO_ROOT / "web"))
        self._tmpdir.cleanup()

    def test_fast_crop_defaults_are_all_false(self) -> None:
        for res, val in self.app_mod.DEFAULT_CONFIG["fast_crop"].items():
            self.assertFalse(val, f"DEFAULT_CONFIG['fast_crop'][{res!r}] must be False")

        html = (REPO_ROOT / "web" / "templates" / "index.html").read_text(encoding="utf-8")
        m = re.search(r"currentFastCropConfig\s*=\s*\{(.*?)\};", html, re.DOTALL)
        self.assertIsNotNone(m, "JS fallback currentFastCropConfig block missing")
        self.assertNotIn(": true", m.group(1).lower())

    def test_gpu_usage_accounts_for_full_fov_isp_pipeline(self) -> None:
        idle_pct, _, idle_status = self.app_mod.get_gpu_usage_percent(192, 192, 90, False)
        self.assertEqual(idle_pct, "%0.0")
        self.assertIn("Boşta", idle_status)

        active_pct, _, active_status = self.app_mod.get_gpu_usage_percent(192, 192, 90, True)
        pct_num = float(active_pct.lstrip("%"))
        self.assertGreater(pct_num, 20.0)
        self.assertIn("Tahmini", active_status)

    def test_api_fast_crop_does_not_overwrite_with_true_fallback(self) -> None:
        client = self.app_mod.app.test_client()
        resp = client.post("/api/fast_crop", json={"640x480": False})
        self.assertEqual(resp.status_code, 200)
        data = resp.get_json()
        self.assertFalse(data["fast_crop"]["192x192"])
        self.assertFalse(data["fast_crop"]["320x240"])

    def test_deploy_and_install_scripts_support_crlf_tilde_and_compile(self) -> None:
        deploy_ps1 = (REPO_ROOT / "deploy.ps1").read_text(encoding="utf-8")
        self.assertIn("sed -i", deploy_ps1)
        self.assertIn("meson setup build --buildtype=release", deploy_ps1)
        self.assertIn("RemoteDestBash", deploy_ps1)

        deploy_sh = (REPO_ROOT / "deploy.sh").read_text(encoding="utf-8")
        self.assertIn("--compile", deploy_sh)
        self.assertIn("REMOTE_DEST_BASH", deploy_sh)
        self.assertIn("NORMALIZE_EOL_CMD", deploy_sh)

        install_sh = (REPO_ROOT / "install.sh").read_text(encoding="utf-8")
        self.assertIn('"spatial_denoise": true', install_sh)
        self.assertIn('"analogue_gain": 8.0', install_sh)
        self.assertIn("sed -i 's/\\r$//'", install_sh)

    def test_preset_192p_and_web_api_controls_and_status(self) -> None:
        self.assertIn((192, 192), self.app_mod.PRESET_RESOLUTIONS)
        html = (REPO_ROOT / "web" / "templates" / "index.html").read_text(encoding="utf-8")
        self.assertIn('<option value="192x192"', html)
        self.assertIn('id="spatial_denoise"', html)
        self.assertIn('id="analogue_gain"', html)

        # Partial fast_crop on disk must merge with defaults instead of dropping keys
        Path(os.environ["PICAM_CONFIG_PATH"]).write_text(
            json.dumps({"fast_crop": {"640x480": True}}),
            encoding="utf-8",
        )
        merged = self.app_mod.load_config()
        self.assertTrue(merged["fast_crop"]["640x480"])
        self.assertFalse(merged["fast_crop"]["192x192"])

        client = self.app_mod.app.test_client()
        resp = client.post(
            "/api/config",
            json={"spatial_denoise": False, "analogue_gain": 12.5, "exposure_value": 4500},
        )
        self.assertEqual(resp.status_code, 200)
        cfg = resp.get_json()["config"]
        self.assertFalse(cfg["spatial_denoise"])
        self.assertEqual(cfg["analogue_gain"], 12.5)
        self.assertEqual(cfg["exposure_value"], 4500)

        bad_resp = client.post("/api/config", json={"analogue_gain": "not-a-float"})
        self.assertEqual(bad_resp.status_code, 400)

        status_resp = client.get("/api/status")
        self.assertEqual(status_resp.status_code, 200)
        st = status_resp.get_json()
        for key in ("usb_maxpacket", "spatial_denoise", "analogue_gain", "exposure_value", "gpu_load"):
            self.assertIn(key, st)

    def test_pupil_plugins_are_in_sync_and_include_192p(self) -> None:
        win_plugin = (REPO_ROOT / "windows" / "pi_zero_uvc_patch.py").read_text(encoding="utf-8")
        scr_plugin = (REPO_ROOT / "scripts" / "pi_zero_uvc_patch.py").read_text(encoding="utf-8")
        self.assertEqual(win_plugin, scr_plugin)
        self.assertIn("(192, 192)", win_plugin)

    def test_web_ui_bilingual_tr_en_support(self) -> None:
        client = self.app_mod.app.test_client()

        # Default language
        get_default = client.get("/api/language")
        self.assertEqual(get_default.status_code, 200)
        self.assertEqual(get_default.get_json()["language"], "tr")

        # Update via /api/language
        post_en = client.post("/api/language", json={"language": "en"})
        self.assertEqual(post_en.status_code, 200)
        self.assertEqual(post_en.get_json()["language"], "en")

        status_en = client.get("/api/status").get_json()
        self.assertEqual(status_en["language"], "en")

        # Reject unsupported language
        bad_lang = client.post("/api/language", json={"language": "de"})
        self.assertEqual(bad_lang.status_code, 400)

        # Update back via /api/config
        post_cfg = client.post("/api/config", json={"language": "tr"})
        self.assertEqual(post_cfg.status_code, 200)
        self.assertEqual(post_cfg.get_json()["config"]["language"], "tr")

        # Template contains switcher and every data-i18n key is defined in both tr and en
        html = (REPO_ROOT / "web" / "templates" / "index.html").read_text(encoding="utf-8")
        for token in ('id="langBtnTr"', 'id="langBtnEn"', "setLanguage(", "const I18N = {"):
            self.assertIn(token, html)
        i18n_block = html.split("const I18N = {", 1)[1].split("const GUIDE_HTML", 1)[0]
        self.assertIn("tr: {", i18n_block)
        self.assertIn("en: {", i18n_block)
        tr_block, en_block = i18n_block.split("en: {", 1)
        keys = set(re.findall(r'data-i18n(?:-html)?="([^"]+)"', html))
        self.assertGreater(len(keys), 20)
        for key in keys:
            self.assertIn(f"{key}:", tr_block, f"Missing TR translation for {key}")
            self.assertIn(f"{key}:", en_block, f"Missing EN translation for {key}")


if __name__ == "__main__":
    unittest.main()
