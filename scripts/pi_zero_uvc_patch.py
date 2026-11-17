# Pi Zero UVC Stream Adapter & Dedicated UI Settings Plugin for Pupil Capture
import logging
import time
import ctypes
from ctypes import wintypes
import struct
import numpy as np
import uvc

try:
    from plugin import Plugin
except ImportError:
    class Plugin:
        order = 0.5
        alive = True
        def __init__(self, g_pool):
            self.g_pool = g_pool
        def add_menu(self):
            pass
        def remove_menu(self):
            pass

try:
    import video_capture.uvc_backend as uvc_b
except ImportError:
    uvc_b = None

try:
    from pyglui import ui
except ImportError:
    ui = None

logger = logging.getLogger('pi_zero_uvc_patch')

# ============================================================================
# 1. In-Memory Hotpatch for uvc.dll (Prevents STATUS_INTEGER_DIVIDE_BY_ZERO 0xc0000094)
# ============================================================================
def apply_uvc_dll_hotpatch():
    try:
        k = ctypes.windll.kernel32
        k.GetModuleHandleW.restype = wintypes.HMODULE
        k.VirtualAlloc.restype = wintypes.LPVOID
        k.VirtualAlloc.argtypes = [wintypes.LPVOID, ctypes.c_size_t, wintypes.DWORD, wintypes.DWORD]
        k.VirtualProtect.argtypes = [wintypes.LPVOID, ctypes.c_size_t, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
        k.VirtualProtect.restype = wintypes.BOOL

        h_mod = k.GetModuleHandleW('uvc.dll')
        if not h_mod:
            return False, 'uvc.dll not yet loaded'

        target_addr = h_mod + 0x93f0
        return_addr = h_mod + 0x9401

        # Check if already patched
        buf = (ctypes.c_ubyte * 6).from_address(target_addr)
        if bytes(buf) == b'\xff\x25\x00\x00\x00\x00':
            return True, 'Already patched'

        # Verify original prologue: 48 89 6c 24 20 56 48 83 ec 20
        orig_prologue = b'\x48\x89\x6c\x24\x20\x56\x48\x83\xec\x20'
        check_buf = (ctypes.c_ubyte * 10).from_address(target_addr)
        if bytes(check_buf) != orig_prologue:
            return False, f'Unexpected prologue in uvc.dll: {bytes(check_buf).hex()}'

        # Allocate executable memory for stub
        stub_addr = k.VirtualAlloc(None, 4096, 0x1000 | 0x2000, 0x40) # MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE
        if not stub_addr:
            return False, 'VirtualAlloc failed'

        stub_code = bytearray()
        stub_code.extend(b'\x83\x79\x40\x00')             # cmp dword ptr [rcx+0x40], 0
        stub_code.extend(b'\x75\x0a')                     # jnz +10
        stub_code.extend(b'\xc7\x41\x40\x00\x6c\xdc\x02') # mov dword ptr [rcx+0x40], 48000000
        stub_code.extend(b'\x48\x89\x6c\x24\x20')         # mov [rsp+0x20], rbp
        stub_code.extend(b'\x56')                         # push rsi
        stub_code.extend(b'\x48\x83\xec\x20')             # sub rsp, 0x20
        stub_code.extend(b'\x4c\x8b\x89\x30\x04\x00\x00') # mov r9, [rcx+0x430]
        stub_code.extend(b'\xff\x25\x00\x00\x00\x00')     # jmp [rip+0]
        stub_code.extend(struct.pack('<Q', return_addr))

        ctypes.memmove(stub_addr, bytes(stub_code), len(stub_code))

        # Apply 17-byte patch at target_addr
        patch_bytes = bytearray(b'\xff\x25\x00\x00\x00\x00')
        patch_bytes.extend(struct.pack('<Q', stub_addr))
        patch_bytes.extend(b'\x90\x90\x90')

        old_prot = wintypes.DWORD()
        k.VirtualProtect(target_addr, 17, 0x40, ctypes.byref(old_prot))
        ctypes.memmove(target_addr, bytes(patch_bytes), 17)
        k.VirtualProtect(target_addr, 17, old_prot.value, ctypes.byref(old_prot))

        logger.info(f'[PiZeroUvcPatch] uvc.dll hotpatch active (stub={hex(stub_addr)})')
        return True, 'Hotpatch applied successfully'
    except Exception as e:
        logger.warning(f'[PiZeroUvcPatch] apply_uvc_dll_hotpatch failed: {e}')
        return False, str(e)

# Apply immediately on module load
apply_uvc_dll_hotpatch()

# ============================================================================
# 2. Global uvc.Capture Wrapper
# ============================================================================
if not getattr(uvc, '_is_pi_zero_patched', False):
    orig_Capture = uvc.Capture
    def WrappedCapture(*args, **kwargs):
        apply_uvc_dll_hotpatch()
        cap = orig_Capture(*args, **kwargs)
        return cap
    uvc.Capture = WrappedCapture
    uvc._is_pi_zero_patched = True
    logger.info('[PiZeroUvcPatch] Global uvc.Capture wrapper active.')

# ============================================================================
# 3. PyGLUI SafeSelector Patch (Prevents 'Synced value ... is not part of selection')
# ============================================================================
def install_safe_selector_patch():
    global ui
    try:
        if ui is None:
            from pyglui import ui as _ui
            ui = _ui
        if not ui or getattr(ui, '_is_pi_zero_patched', False):
            return
        orig_Selector = ui.Selector

        def SafeSelector(*args, **kwargs):
            property_name = args[0] if len(args) > 0 else kwargs.get('property_name')
            target = args[1] if len(args) > 1 else kwargs.get('target')
            try:
                if target is not None and property_name is not None and hasattr(target, property_name):
                    cur_val = getattr(target, property_name, None)
                    cur_tuple = tuple(cur_val) if isinstance(cur_val, list) else cur_val

                    # 1. Handle static selection argument
                    if 'selection' in kwargs and kwargs['selection']:
                        raw_sel = kwargs['selection']
                        norm_sel = [tuple(x) if isinstance(x, list) else x for x in raw_sel]

                        if cur_tuple in norm_sel:
                            # Value matches when converted to tuple
                            if cur_val != cur_tuple:
                                try:
                                    setattr(target, property_name, cur_tuple)
                                except Exception:
                                    pass
                        elif cur_val not in raw_sel and cur_tuple not in raw_sel:
                            # Value is not in selection at all (e.g. 192x192 fallback)
                            fallback = raw_sel[0]
                            logger.warning(f"[SafeSelector] Synced value '{cur_val}' for '{property_name}' not in selection. Falling back to '{fallback}'.")
                            try:
                                setattr(target, property_name, fallback)
                                if 'setter' in kwargs and callable(kwargs['setter']):
                                    kwargs['setter'](fallback)
                            except Exception as ex:
                                logger.warning(f"[SafeSelector] Could not set fallback on target: {ex}")

                    # 2. Handle dynamic selection_getter argument
                    elif 'selection_getter' in kwargs and callable(kwargs['selection_getter']):
                        orig_getter = kwargs['selection_getter']
                        try:
                            res = orig_getter()
                            if isinstance(res, (tuple, list)) and len(res) >= 1:
                                valid_vals = res[0]
                                norm_vals = [tuple(x) if isinstance(x, list) else x for x in valid_vals]
                                if cur_tuple in norm_vals:
                                    if cur_val != cur_tuple:
                                        try:
                                            setattr(target, property_name, cur_tuple)
                                        except Exception:
                                            pass
                                elif cur_val not in valid_vals and cur_tuple not in valid_vals:
                                    fallback = valid_vals[0]
                                    logger.warning(f"[SafeSelector] Synced value '{cur_val}' for '{property_name}' not in selection_getter. Falling back to '{fallback}'.")
                                    try:
                                        setattr(target, property_name, fallback)
                                        if 'setter' in kwargs and callable(kwargs['setter']):
                                            kwargs['setter'](fallback)
                                    except Exception as ex:
                                        logger.warning(f"[SafeSelector] Could not set fallback on target: {ex}")
                        except Exception as e:
                            logger.warning(f"[SafeSelector] selection_getter inspection failed: {e}")

            except Exception as e:
                logger.warning(f"[SafeSelector] pre-flight normalization error: {e}")

            try:
                return orig_Selector(*args, **kwargs)
            except ValueError as e:
                if "is not part of selection" in str(e):
                    logger.warning(f"[SafeSelector] Caught ValueError '{e}'. Retrying with current value added to selection...")
                    try:
                        if 'selection' in kwargs and kwargs['selection'] and target is not None and property_name is not None:
                            kwargs['selection'] = list(kwargs['selection']) + [getattr(target, property_name)]
                            return orig_Selector(*args, **kwargs)
                    except Exception:
                        pass
                raise

        ui.Selector = SafeSelector
        ui._is_pi_zero_patched = True
        logger.info("[PiZeroUvcPatch] pyglui.ui.Selector safely patched against type/value mismatches.")
    except Exception as e:
        logger.warning(f"[PiZeroUvcPatch] Could not patch pyglui.ui.Selector: {e}")

install_safe_selector_patch()

# ============================================================================
# 4. Patch UVC_Source (UI Menu + 500ms Timeout + Monotonic Time Sync)
# ============================================================================
if uvc_b and hasattr(uvc_b, 'UVC_Source'):
    if not getattr(uvc_b.UVC_Source, '_is_pi_zero_patched', False):
        orig_configure = uvc_b.UVC_Source.configure_capture
        def patched_configure(self, *args, **kwargs):
            apply_uvc_dll_hotpatch()
            install_safe_selector_patch()
            res = orig_configure(self, *args, **kwargs)
            self.stripe_detector = None
            return res
        uvc_b.UVC_Source.configure_capture = patched_configure

        # Tuple-normalize frame_size property
        if hasattr(uvc_b.UVC_Source, 'frame_size') and isinstance(uvc_b.UVC_Source.frame_size, property):
            orig_fget = uvc_b.UVC_Source.frame_size.fget
            orig_fset = uvc_b.UVC_Source.frame_size.fset

            def safe_frame_size_get(self):
                val = orig_fget(self)
                if isinstance(val, list):
                    return tuple(val)
                return val

            def safe_frame_size_set(self, val):
                if isinstance(val, list):
                    val = tuple(val)
                return orig_fset(self, val)

            uvc_b.UVC_Source.frame_size = property(safe_frame_size_get, safe_frame_size_set)

        _failure_counts = {}

        def patched_recent_events(self, events):
            if not self.uvc_capture:
                self._restart_logic()
                return

            key = getattr(self.g_pool, 'app', 'eye0')
            try:
                # Allow 500ms for Pi Zero single-core software MJPEG compression
                frame = self.uvc_capture.get_frame(0.5)
                _failure_counts[key] = 0

                if self.preferred_exposure_time:
                    target = self.preferred_exposure_time.calculate_based_on_frame(frame)
                    if target is not None:
                        self.exposure_time = target

            except (TimeoutError, uvc.StreamError) as e:
                count = _failure_counts.get(key, 0) + 1
                _failure_counts[key] = count
                if count > 10:
                    logger.warning(f'[PiZeroUvcPatch] 10 consecutive frame timeouts/errors ({e}). Reconnecting...')
                    self._recent_frame = None
                    self._restart_logic()
                else:
                    self._recent_frame = None
                return
            except (AttributeError, uvc.InitError):
                self._recent_frame = None
                time.sleep(0.02)
                self._restart_logic()
                return
            else:
                # Monotonic host timestamping to synchronize with Pupil pipeline
                now = uvc.get_time_monotonic()
                if self._last_ts is None or now > self._last_ts:
                    self._last_ts = now
                    frame.timestamp = now - self.g_pool.timebase.value
                    self._recent_frame = frame
                    events['frame'] = frame
                else:
                    self._recent_frame = frame
                    events['frame'] = frame

        uvc_b.UVC_Source.recent_events = patched_recent_events

        # --------------------------------------------------------------------
        # Dedicated Resolution & FPS Menu inside UVC_Source (Camera Menu)
        # --------------------------------------------------------------------
        orig_ui = uvc_b.UVC_Source.ui_elements
        def patched_ui_elements(self):
            install_safe_selector_patch()
            # If camera is disconnected (e.g. In world when device is on eye0),
            # return orig_ui directly without creating unbacked selectors.
            if self.uvc_capture is None:
                try:
                    return orig_ui(self)
                except Exception:
                    return []

            elements = []
            try:
                from pyglui import ui as _ui
                pz_menu = _ui.Growing_Menu(label="Pi Zero Kamera Ayarları")
                pz_menu.collapsed = False

                if isinstance(self.frame_size, list):
                    self.frame_size = tuple(self.frame_size)

                curr_w, curr_h = self.frame_size
                curr_fps = int(self.frame_rate)
                status = _ui.Info_Text(f"Aktif Mod: {curr_w}x{curr_h} @ {curr_fps} FPS")
                pz_menu.append(status)

                # Resolution Selector
                def set_res(sz):
                    logger.info(f"[PiZeroUvcPatch] Çözünürlük ayarlandı: {sz}")
                    self.frame_size = tuple(sz)
                    if hasattr(self, 'update_menu'):
                        self.update_menu()

                res_labels = {
                    (192, 192): "Göz Takibi - Yüksek FPS",
                    (320, 240): "QVGA - Göz Takibi",
                    (400, 400): "Kare Göz Takibi",
                    (640, 480): "VGA - Göz Takibi",
                    (800, 600): "SVGA",
                    (1280, 720): "HD Sahne",
                }
                avail_sizes = (
                    [tuple(s) for s in self.uvc_capture.frame_sizes]
                    if self.uvc_capture
                    else [(192, 192), (320, 240), (400, 400), (640, 480), (800, 600), (1280, 720)]
                )
                size_labels = [f"{w}x{h} ({res_labels.get((w, h), 'Özel')})" for w, h in avail_sizes]
                pz_menu.append(
                    _ui.Selector(
                        "frame_size",
                        self,
                        setter=set_res,
                        selection=avail_sizes,
                        labels=size_labels,
                        label="Çözünürlük (Resolution)",
                    )
                )

                # FPS Selector
                def set_fps(fps):
                    logger.info(f"[PiZeroUvcPatch] FPS ayarlandı: {fps}")
                    self.frame_rate = int(fps)
                    if hasattr(self, 'update_menu'):
                        self.update_menu()

                def rate_getter():
                    if self.uvc_capture and self.uvc_capture.frame_rates:
                        rates = [int(r) for r in self.uvc_capture.frame_rates]
                        return rates, [f"{r} FPS" for r in rates]
                    return [15, 30, 60, 90, 120], ["15 FPS", "30 FPS", "60 FPS", "90 FPS", "120 FPS"]

                pz_menu.append(
                    _ui.Selector(
                        "frame_rate",
                        self,
                        selection_getter=rate_getter,
                        setter=set_fps,
                        label="Kare Hızı (FPS)",
                    )
                )

                # Quick Presets
                def make_preset_btn(w, h, fps, title):
                    def apply_preset():
                        set_res((w, h))
                        set_fps(fps)
                    return _ui.Button(title, apply_preset)

                pz_menu.append(make_preset_btn(192, 192, 90, "Önayar: 192x192 @ 90 FPS (Pupil - En Yüksek FPS)"))
                pz_menu.append(make_preset_btn(320, 240, 90, "Önayar: 320x240 @ 90 FPS (Hızlı Göz Takibi)"))
                pz_menu.append(make_preset_btn(640, 480, 90, "Önayar: 640x480 @ 90 FPS (Önerilen - Yüksek Hızlı Göz Takibi)"))
                pz_menu.append(make_preset_btn(640, 480, 60, "Önayar: 640x480 @ 60 FPS (Dengeli Mod)"))
                pz_menu.append(make_preset_btn(1280, 720, 30, "Önayar: 1280x720 @ 30 FPS (HD Çözünürlük)"))

                # Restart Stream Button
                def restart():
                    logger.info("[PiZeroUvcPatch] Akış yeniden başlatılıyor...")
                    self._restart_logic()

                pz_menu.append(_ui.Button("Kamera Akışını Yeniden Başlat", restart))
                elements.append(pz_menu)
            except Exception as e:
                logger.error(f"[PiZeroUvcPatch] patched_ui_elements hatası: {e}")

            # Original UI elements (appended below Pi Zero dedicated settings)
            try:
                orig_elements = orig_ui(self)
                elements.extend(orig_elements)
            except Exception as e:
                logger.warning(f"[PiZeroUvcPatch] orig_ui hatası: {e}")

            return elements

        uvc_b.UVC_Source.ui_elements = patched_ui_elements
        uvc_b.UVC_Source._is_pi_zero_patched = True
        logger.info('[PiZeroUvcPatch] UVC_Source patched with dedicated Pi Zero UI elements.')

# ============================================================================
# 5. General Plugin Class for Global / World Discovery
# ============================================================================
class Pi_Zero_UVC_Patch(Plugin):
    order = 0.001
    icon_font = "roboto"
    icon_chr = "Pi"

    def __init__(self, g_pool):
        super().__init__(g_pool)
        self.menu = None
        self.menu_icon = None
        self.status_text = None
        self._fps_count = 0
        self._fps_start_time = time.time()
        self.measured_fps = 0.0
        apply_uvc_dll_hotpatch()
        install_safe_selector_patch()
        logger.info('[PiZeroUvcPatch] Plugin instance created in ' + str(getattr(g_pool, 'app', 'process')))

    @property
    def resolution(self):
        if hasattr(self.g_pool, 'capture') and self.g_pool.capture:
            return tuple(self.g_pool.capture.frame_size)
        return (640, 480)

    @property
    def framerate(self):
        if hasattr(self.g_pool, 'capture') and self.g_pool.capture:
            return int(self.g_pool.capture.frame_rate)
        return 90

    def init_ui(self):
        try:
            install_safe_selector_patch()
            from pyglui import ui as _ui
            self.add_menu()
            self.menu.label = "Pi Zero Kamera"
            self.menu_icon.tooltip = "Pi Zero Kamera Ayarları"
            self.menu.collapsed = False

            res = self.resolution
            fps = self.framerate
            self.status_text = _ui.Info_Text(f"Aktif: {res[0]}x{res[1]} @ {fps} FPS")
            self.menu.append(self.status_text)

            def get_sizes():
                sizes = [(192, 192), (320, 240), (400, 400), (640, 480), (800, 600), (1280, 720)]
                if hasattr(self.g_pool, 'capture') and self.g_pool.capture and hasattr(self.g_pool.capture, 'uvc_capture') and self.g_pool.capture.uvc_capture:
                    try:
                        sizes = [tuple(s) for s in self.g_pool.capture.uvc_capture.frame_sizes]
                    except Exception:
                        pass
                return sizes, [f"{w}x{h}" for w, h in sizes]

            def set_res(sz):
                if hasattr(self.g_pool, 'capture') and self.g_pool.capture:
                    self.g_pool.capture.frame_size = tuple(sz)
                    self.update_status_display()

            self.menu.append(
                _ui.Selector(
                    "resolution",
                    self,
                    selection_getter=get_sizes,
                    setter=set_res,
                    label="Çözünürlük (Resolution)",
                )
            )

            def get_rates():
                rates = [15, 30, 60, 90, 120]
                if hasattr(self.g_pool, 'capture') and self.g_pool.capture and hasattr(self.g_pool.capture, 'uvc_capture') and self.g_pool.capture.uvc_capture:
                    try:
                        rates = [int(r) for r in self.g_pool.capture.uvc_capture.frame_rates]
                    except Exception:
                        pass
                return rates, [f"{r} FPS" for r in rates]

            def set_rate(rt):
                if hasattr(self.g_pool, 'capture') and self.g_pool.capture:
                    self.g_pool.capture.frame_rate = int(rt)
                    self.update_status_display()

            self.menu.append(
                _ui.Selector(
                    "framerate",
                    self,
                    selection_getter=get_rates,
                    setter=set_rate,
                    label="Kare Hızı (FPS)",
                )
            )

            logger.info("[PiZeroUvcPatch] Global Plugin Menu initialized.")
        except Exception as e:
            logger.error(f"[PiZeroUvcPatch] init_ui hatası: {e}")

    def update_status_display(self):
        if self.status_text:
            try:
                res = self.resolution
                fps = self.framerate
                if self.measured_fps > 0:
                    self.status_text.text = f"Aktif: {res[0]}x{res[1]} @ {fps} FPS (Canlı: {self.measured_fps:.1f} FPS)"
                else:
                    self.status_text.text = f"Aktif: {res[0]}x{res[1]} @ {fps} FPS"
            except Exception:
                pass

    def recent_events(self, events):
        self._fps_count += 1
        now = time.time()
        elapsed = now - self._fps_start_time
        if elapsed >= 1.0:
            self.measured_fps = self._fps_count / elapsed
            self._fps_count = 0
            self._fps_start_time = now
            self.update_status_display()

    def deinit_ui(self):
        try:
            self.remove_menu()
        except Exception:
            pass
