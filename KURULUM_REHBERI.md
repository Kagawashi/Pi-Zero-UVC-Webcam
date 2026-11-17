# 📷 Raspberry Pi Zero UVC Kamera - Açık Kaynak Kurulum Rehberi

Bu proje, bir **Raspberry Pi Zero W / 2W** kartını ve **CSI Kamera modülünü** tek bir USB kablosu üzerinden bilgisayara bağlandığında:
1. **Pupil Labs UVC Göz Takip Kamerasına (`Pupil Cam1 ID0`)** veya **Standart Web Kamerasına**,
2. **Wi-Fi'a ihtiyaç duymadan doğrudan USB üzerinden çalışan Sanal Ağ Kartına (RNDIS Ethernet)**

dönüştüren açık kaynaklı bir sistemdir.

Aynı zamanda tarayıcıdan erişilebilen bir **Web Kontrol Paneli (`:8080`)** ve Pupil Capture içinde doğrudan çalışan **Özel Çözünürlük/FPS Menüsü** içerir.

---

## 1. Donanım Gereksinimleri

1. **Raspberry Pi Zero W** veya **Pi Zero 2W** (Dahili Wi-Fi ve OTG USB desteği).
2. **CSI Kamera Modülü** (Örn: OV5647, IMX219 veya OV9281 global shutter) ve Pi Zero'ya uygun ince flex kablo.
3. **Micro USB Veri Kablosu**  
   > ⚠️ **ÇOK ÖNEMLİ:** Bazı Micro USB kabloları yalnızca şarj içindir ve veri hatları (D+/D-) bağlı değildir. Mutlaka **veri aktarabilen** bir kablo kullanmalısınız. Kabloyu Pi Zero üzerindeki **PWR IN** portuna değil, ortadaki **USB (veri)** portuna takmalısınız.
4. **MicroSD Kart** (En az 8 GB, Class 10 önerilir).

---

## 2. SD Kart Hazırlama (Raspberry Pi OS Lite)

1. [Raspberry Pi Imager](https://www.raspberrypi.com/software/) programını açın.
2. İşletim Sistemi olarak **Raspberry Pi OS Lite (32-bit veya 64-bit)** seçin.
3. Ayarları yapılandırın (Çark simgesi veya `Ctrl+Shift+X`):
   - **Hostname:** `pizero` *(veya tercih ettiğiniz bir isim)*
   - **Kullanıcı Adı:** `pi`
   - **Şifre:** `raspberry` *(veya belirlediğiniz şifre)*
   - **Wi-Fi Yapılandırması:** Bulunduğunuz Wi-Fi ağının veya telefon Hotspot'unuzun adı ve şifresi
   - **SSH:** Etkinleştirin (Enable SSH -> Use password authentication)
4. SD karta yazma işlemini tamamlayın.
5. SD kartı Pi Zero'ya takın ve Pi Zero'yu çalıştırın.

---

## 3. 🚀 Açık Kaynak Tek Komutla Kurulum (En Kolay Yol)

Pi Zero açıldığında terminal veya PowerShell üzerinden bağlanın:

```bash
# 1. Pi Zero'ya SSH ile bağlanın:
ssh pi@pizero.local
# (veya IP adresi ile: ssh pi@192.168.1.XX / ssh pi@10.23.11.XX)

# 2. Proje deposunu çekin ve kurulumu başlatın:
git clone https://github.com/Kagawashi/Pi-Zero-UVC-Webcam.git
cd Pi-Zero-UVC-Webcam
sudo bash install.sh
```

> 💡 **`install.sh` Neleri Otomatik Yapar?**
> - Windows CRLF satır sonlarını temizler ve boot ayarlarını (`dwc2`, `ov5647`, `camera_auto_detect=1`, `gpu_mem=128`, `modules-load=dwc2,libcomposite`) otomatik ekler.
> - Gerekli tüm sistem kütüphanelerini (`meson`, `ninja-build`, `libcamera-dev`, `libjpeg-dev`, `libevent-dev`, `v4l-utils`, `jq`, `linux-headers`) kurar.
> - **OV5647 Yüksek FPS Çekirdek Sürücüsü:** Standart Linux sürücüsündeki ADC sınırlarını ($HTS \ge 1730$) çözen modifiye `ov5647.ko` modülünü (`fast_crop` sysfs parametreli) otomatik derler ve sisteme kurar (`scripts/build-ov5647-driver.sh`).
> - **VideoCore IV GPU Donanım JPEG (`V4L2_MEMORY_DMABUF`) + Spatial Denoise:** Donanım zaman damgalı (`buf.timestamp`) ve IPA kontrol önbelleklemeli (`controls_applied_`) `uvc-gadget` ikilisini `--buildtype=release` (`-O3`) modunda derler.
> - **Yüksek FPS `libcamera` IPA & Unicam Tuning:** `start-uvc.sh` üzerinden `/etc/picam/rpi_pipeline.yaml` (`min_unicam_buffers: 6`, `min_total_unicam_buffers: 8`) ve `/etc/picam/<sensor>_fast.json` (`rpi.sdn` Spatial Denoise korunur, `awb bayes=0`, `agc` maks. shutter `9500 µs`, ağır `alsc/geq/contrast/sharpen` çıkarılır) dosyalarını otomatik üretir.
> - **Sıfır Bozuk JPEG USB Gadget Ayarı:** `setup-gadget.sh` içinde `streaming_maxpacket=1024`, MJPEG kare boyutu $\max(w \times h, 65536)$ ve `192x192`–`1280x720` (`720p` 30/15 fps) UVC tanımlayıcılarını kurar.
> - **Varsayılan Full FOV Haritası:** OV5647 `192x192` / `320x240` Bayer şeritlenmesini önlemek için tüm çözünürlüklerde `fast_crop: false` (Full FOV + VideoCore IV ISP ölçekleme) ayarını `/etc/picam/config.json` içine yazar.
> - Sıfır alt-süreç (`sysfs`) tabanlı Web Kontrol Panelini (`:8080` — GPU kullanımı, GPU Spatial Denoise, Analog Kazanç ve Fast-Crop anahtarları) ve UVC servisini `systemd` arka plan servisi olarak kaydeder.
> - Kurulum bittiğinde ekranda **"Sistemi şimdi yeniden başlatmak istiyor musunuz? [E/h]"** diye sorar ve onayınızla Pi Zero'yu yeniden başlatır.

---

### 3.1. 💻 Bilgisayardan Uzaktan Tek Komutla Kurulum (`deploy.ps1` & `deploy.sh`)

Eğer Pi Zero'ya git clone yapmak yerine doğrudan geliştirme yaptığınız bilgisayarınızdan tüm kodları tek komutla aktarıp kurmak isterseniz:

#### Windows Üzerinden (PowerShell):
```powershell
# Tam kurulum (Sürücü derleme, uvc-gadget derleme ve servis kurulumu):
powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -TargetHost "192.168.1.152" -User "pi" -Role "eye0" -Sensor "ov5647"

# Hızlı güncelleme + C/C++ uvc-gadget yeniden derleme:
powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -TargetHost "192.168.1.152" -SkipInstall -Compile

# Sadece betikleri, servisleri ve web panelini güncelleme (derlemesiz):
powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -TargetHost "192.168.1.152" -Quick
```

#### Linux / macOS Üzerinden (Bash):
```bash
# Tam kurulum:
chmod +x deploy.sh
./deploy.sh -H 192.168.1.152 -u pi -r eye0 -s ov5647

# Hızlı güncelleme + uvc-gadget yeniden derleme:
./deploy.sh -H 192.168.1.152 -q -c

# Sadece betikleri, servisleri ve web panelini güncelleme:
./deploy.sh -H 192.168.1.152 -q
```

---

## 4. 🔌 USB Bağlantısı, Wi-Fi ve İsteğe Bağlı RNDIS USB Ağ Modu

Varsayılan olarak `setup-gadget.sh` yalnızca UVC kamera cihazını aktif eder (`ENABLE_RNDIS=0`). Bunun nedeni `BCM2835 dwc2` denetleyicisinde eşzamanlı UVC + RNDIS açıldığında Windows `PupilDrvInst.exe` sürücü yükleyicisinin PnP çakışması nedeniyle takılabilmesidir.

Normal kullanımda Pi Zero'ya ev/okul/telefon hotspot Wi-Fi ağı üzerinden (`ssh pi@pizero.local` veya `http://pizero.local:8080`) bağlanmanız önerilir. Eğer Wi-Fi olmadan USB kablosu üzerinden RNDIS ağ adaptörünü de açmak isterseniz:
1. Pi Zero'da `ENABLE_RNDIS=1 /usr/local/bin/setup-gadget.sh eye0 restart` ile test edebilir veya kalıcıleştirebilirsiniz.
2. Windows cihazı sanal ağ kartı (`Remote NDIS Compatible Device`) aldığında `169.254.x.x` link-local ağından `ssh pi@pizero.local` ve `http://pizero.local:8080` erişilebilir.

---

## 5. 🌍 Farklı Ortamlara Geçiş ve Çoklu Wi-Fi Yönetimi

Okul, iş yeri, kafe veya ev gibi farklı ortamlara geçtiğinizde Pi Zero'nun Wi-Fi bağlantısını yönetmek çok kolaydır:

### A. Pi Zero Onlarca Ağı Hafızasında Tutar (Otomatik Geçiş)
Raspberry Pi'ye istediğiniz kadar Wi-Fi ağı ekleyebilirsiniz. Hangi ortamdaysanız Pi Zero o ortamın modemiyle otomatik eşleşir:

```bash
# 1. Yeni bir Wi-Fi ağı ekleme ve otomatik bağlanmayı açma:
sudo nmcli connection add type wifi con-name "Ev-Wifi" ifname wlan0 ssid "TurkNet1000Mbps_3C992" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "tLu788rXG8Ga" connection.autoconnect yes connection.autoconnect-priority 10

# 2. Telefon Hotspot'unu ikinci ağ olarak ekleme:
sudo nmcli connection add type wifi con-name "Telefon-Hotspot" ifname wlan0 ssid "Redmi 9T" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "telefon_sifresi" connection.autoconnect yes connection.autoconnect-priority 5

# 3. Kayıtlı tüm ağları görme:
sudo nmcli connection show
```

### B. Yeni Bir Ortamda Wi-Fi'a Hızlıca Bağlanma
Yeni bir yere gittiğinizde Wi-Fi'a bağlanmak için:
1. Pi Zero'yu USB ile bilgisayara takın.
2. `ssh pi@pizero.local` diyerek USB üzerinden terminale girin.
3. Şu tek satırı yazın:
   ```bash
   sudo nmcli dev wifi connect "Yeni_Ortam_Wifi_Adi" password "Wifi_Sifresi"
   ```
Pi Zero yeni ağa hemen bağlanır ve bu ağı bir daha asla unutmaz!

---

## 6. 🔍 Pi Zero'ya Neler Kuruluyor? (Sistem Mimarisi)

Açık kaynak şeffaflığı gereği, sisteminize kurulan tüm dosyalar ve servisler aşağıda listelenmiştir:

| Dosya / Dizin | Görevi / Açıklama |
|---|---|
| `/boot/firmware/config.txt` | `dtoverlay=dwc2,dr_mode=peripheral`, `gpu_mem=128`, kamera algılama tanımları. |
| `/lib/modules/$(uname -r)/kernel/drivers/media/i2c/ov5647.ko.xz` | 120–190 FPS destekli, ADC zamanlama düzeltmeli ($HTS \ge 1730$) modifiye Linux çekirdek sürücüsü. |
| `/usr/local/bin/build-ov5647-driver.sh` | OV5647 yüksek FPS modülünü derleyen, kuran ve yedek alan yardımcı yönetim betiği. |
| `/etc/picam/ov5647.ko.xz.bak` | Sistemin orijinal çekirdek sürücüsünün otomatik alınan yedeği. |
| `/usr/local/bin/uvc-gadget` | `libcamera` ISP'den çıkan `YUV420` DMA tamponlarını sıfır kopya (`V4L2_MEMORY_DMABUF`) ile VideoCore IV GPU donanım JPEG kodlayıcısına (`/dev/video31` / `/dev/video11`) aktaran, GPU Spatial Denoise ve önbellekli canlı kamera kontrolü uygulayan C/C++ ikili dosyası. |
| `/usr/local/bin/setup-gadget.sh` | ConfigFS üzerinde `streaming_maxpacket=1024`, $\max(w \times h, 65536)$ MJPEG tamponları ve yerleşik UVC (`192x192`, `320x240`, `400x400`, `640x480`, `800x600`, `1280x720@30/15`) tanımlayıcılarını oluşturan betik. |
| `/usr/local/bin/start-uvc.sh` | Yüksek FPS `libcamera` IPA tuning (`/etc/picam/<sensor>_fast.json`), Unicam tampon (`/etc/picam/rpi_pipeline.yaml`) ve başlangıç `fast_crop=0` yapılandırmasını yöneten orkestratör betik. |
| `/opt/picam-web/` | 8080 portunda çalışan, `sysfs`/`procfs` üzerinden durum izleyen; GPU yük tahmini, GPU Spatial Denoise, Analog Gain, `192x192` önayarı ve Fast-Crop anahtarlarını sunan Flask web servisi. |
| `/etc/systemd/system/uvc-gadget.service` | Pi Zero açıldığında ConfigFS gadget'ını kurup kamera akışını başlatan systemd servisi. |
| `/etc/systemd/system/picam-web.service` | Web arayüzünü arka planda çalıştıran systemd servisi. |
| `/etc/picam/config.json` | Web arayüzü ve `uvc-gadget` tarafından paylaşılan kalıcı JSON ayar dosyası (`exposure_value`, `analogue_gain`, `spatial_denoise`, `brightness..sharpness`, `fast_crop`). |
| `/etc/picam/rpi_pipeline.yaml` | `libcamera` Unicam RAW tampon sayısını (`min_unicam_buffers: 6`, `min_total_unicam_buffers: 8`) artıran boru hattı yapılandırması. |
| `/etc/picam/<sensor>_fast.json` | GPU Spatial Denoise (`rpi.sdn`) açık tutulurken ağır `alsc`, `geq`, `contrast`, `sharpen` algoritmalarını devre dışı bırakan, `awb bayes=0` ve `agc` maks. pozlama `9500 µs` ile yüksek FPS sağlayan sensör profili. |

---

## 7. Shell / Terminal Üzerinden Manuel Dosya Açma ve İnceleme

Eğer `install.sh` betiği yerine dosyaları elle açıp incelemek veya değiştirmek isterseniz:

### 1. `config.txt` Dosyasını Açma (`nano`)
```bash
# Raspberry Pi OS Bookworm için:
sudo nano /boot/firmware/config.txt

# Eski sürümler için:
sudo nano /boot/config.txt
```
*En alta eklenecek satırlar:*
```text
dtoverlay=dwc2,dr_mode=peripheral
gpu_mem=128
camera_auto_detect=1
dtoverlay=ov5647
```
> **Nano Kısayolları:** Kaydetmek için `Ctrl + O` -> `Enter`, çıkmak için `Ctrl + X`.

### 2. `cmdline.txt` Dosyasını Açma (`nano`)
```bash
sudo nano /boot/firmware/cmdline.txt
```
`rootwait` sonrasına bir boşluk bırakarak `modules-load=dwc2,libcomposite,usb_f_rndis` ekleyin.  
*(Kesinlikle tek bir satırda kalmalıdır, Enter'a basıp alt satıra geçmeyin).*

---

## 8. Servisleri Yönetme ve Log İzleme Komutları

```bash
# UVC Kamera Servis Durumu ve Canlı Logları:
sudo systemctl status uvc-gadget
sudo journalctl -u uvc-gadget -f -n 50

# Web Paneli Durumu ve Canlı Logları:
sudo systemctl status picam-web
sudo journalctl -u picam-web -f -n 50

# Servisleri Yeniden Başlatma:
sudo systemctl restart uvc-gadget
sudo systemctl restart picam-web

# Kamera Donanım Testi:
vcgencmd get_camera
v4l2-ctl --list-devices
```

---

## 9. Windows ve Pupil Capture Kurulumu

Pupil Capture'ın Pi Zero ile çökmeden tam uyumlu çalışması için Windows tarafındaki eklentiyi kurun:

1. Bu depodaki `windows` dizinine girin.
2. Windows PowerShell'i açın ve şu komutu çalıştırın:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\windows\install_plugin.ps1
   ```
3. Bu işlem `pi_zero_uvc_patch.py` dosyasını Pupil Capture eklenti dizinine kopyalar.

### Bu Eklenti Ne Sağlar?
- **0xc0000094 Çökme Yaması:** Pupil Capture'ın `uvc.dll` kütüphanesindeki sıfıra bölünme hatasını bellekte engeller.
- **PyGLUI SafeSelector Koruması:** Çözünürlük/FPS seçiminde Eye0 penceresinin aniden kapanmasını önler.
- **Özel Pi Zero Menüsü:** Eye0 / Eye1 / World penceresinde tüm yerleşik çözünürlükler (`192x192`, `320x240`, `400x400`, `640x480`, `800x600`, `1280x720`) ve hızlı FPS önayarları (`192x192 @ 90`, `320x240 @ 90`, `640x480 @ 90/60`, `1280x720 @ 30`) sunar.

---

## 10. Canlı Kullanım ve Rol Değiştirme (`eye0` / `eye1` / `world`)

1. Pi Zero'yu **ortadaki USB portundan** (PWR değil) kaliteli bir veri kablosu ile bilgisayara bağlayın.
2. Windows Aygıt Yöneticisi'nde **libusbk devices** altında seçili role göre aşağıdaki cihazlardan birinin belirdiğini görün:
   * **`eye0` (Sağ Göz):** `Pupil Cam1 ID0` (`VID_05A3&PID_9230` / `1443:37424`)
   * **`eye1` (Sol Göz):** `Pupil Cam1 ID1` (`VID_05A3&PID_9231` / `1443:37425`)
   * **`world` (Dünya / Sahne):** `Pupil Cam1 ID2` (`VID_05A3&PID_9232` / `1443:37426`)
   > **Not (İlk Kez Rol Değiştirirken Sürücü Kurulumu):** Windows her USB PID (`9230`, `9231`, `9232`) için `libusbK` sürücüsünü ayrı kaydeder. Web panelinden (`http://pizero.local:8080`) kamera rolünü ilk kez `world` veya `eye1` yaptığınızda, `powershell -ExecutionPolicy Bypass -File .\windows\install_plugin.ps1` komutunu çalıştırarak (veya Pupil Capture açılırken çıkan yönetici iznini onaylayarak) `PupilDrvInst.exe`'nin yeni rol için `libusbK` sürücüsünü tek seferlik kurmasını sağlayın. (`setup-gadget.sh` içinde RNDIS varsayılan olarak kapatıldığı (`ENABLE_RNDIS=0`) için sürücü kurulumu PnP çakışması olmadan saniyeler içinde tamamlanır.)
3. Sürücü kurulduktan sonra Pupil Capture uygulamasını başlatın:
   ```powershell
   Start-Process "C:\Program Files (x86)\Pupil-Labs\Pupil v3.5.1\Pupil Capture v3.5.1\pupil_capture.exe" -ArgumentList "--skip-driver-installation"
   ```
4. Kamera penceresinde (`Eye 0`, `Eye 1` veya `World`) menüyü açtığınızda **"Pi Zero Kamera Ayarları"** panelinden yüksek FPS canlı yayının keyfini çıkarın!

---

## 11. Özel Çözünürlük, VideoCore IV GPU Sıkıştırma & Yüksek FPS Mimari Rehberi

### A. VideoCore IV GPU Donanım JPEG, Spatial Denoise & Sıfır Bozuk Kare Mimarisi
Tek çekirdekli **Raspberry Pi Zero W (1 GHz ARM11)** üzerinde yazılımsal `libjpeg` kullanıldığında `640x480` çözünürlükte kare başına **45.75 ms (%100 CPU, ~21.9 FPS)** harcanırken, bu projedeki çok katmanlı donanım optimizasyonu ile hem FPS artırılmış hem de `Corrupt JPEG data` kesintileri sıfırlanmıştır:

1. **Sıfır Kopya (`V4L2_MEMORY_DMABUF`) VideoCore IV GPU Donanım Kodlaması (`/dev/video31` & `/dev/video11`):**
   - `libcamera` ISP'den çıkan `YUV420` DMA tampon tanıtıcısı (`dmabuf_fd`), CPU belleğine kopyalanmadan VideoCore IV GPU `bcm2835-codec-encode_image` motoruna iletilir.
   - Tek kare donanım sıkıştırma süreleri: `320x240` **1.62 ms**, `400x400` **1.98 ms**, `640x480` **2.65 ms**.

2. **USB `streaming_maxpacket = 1024` & MJPEG Tampon Ayrımı:**
   - BCM2835 `dwc2` denetleyicisinde High-Bandwidth ISOC (`2048`) modu kare ortasında paket düşürerek Pupil Capture'da `Corrupt JPEG data: premature end of data segment` hatasına yol açıyordu.
   - `streaming_maxpacket = 1024` (8.192 MB/s kararlı ISOC) ve MJPEG için `dwMaxVideoFrameSize = max(w*h, 65536)` ayarıyla tüm çözünürlüklerde **`%0` bozuk JPEG** (`no_soi=0, no_eoi=0, tj_fails=0`) elde edilmiştir.

3. **GPU Spatial Denoise (`rpi.sdn`) + IPA Kontrol Önbellekleme (`controls_applied_`):**
   - Renkli sensör karıncalanmasını (kırmızı/mavi/yeşil gürültü) önlemek için donanımsal **GPU Spatial Denoise (`NoiseReductionModeFast` + `rpi.sdn`)** açık tutulur ve Web panelinden tek tıkla açılıp kapatılabilir.
   - Her karede IPA'ya kontrol (`AeEnable`, `ExposureTime`, `AnalogueGain`, `Brightness/Contrast/Saturation/Sharpness`, `NoiseReductionMode`) göndermek yerine sadece akış başlangıcında veya `/etc/picam/config.json` değiştiğinde gönderen önbellek yapısı sayesinde gereksiz IPC CPU maliyeti kaldırılmıştır.
   - `/etc/picam/<sensor>_fast.json` dosyası `rpi.alsc`, `rpi.geq`, `rpi.contrast` ve `rpi.sharpen` bloklarını çıkararak ARM11 üzerindeki kare işleme süresini kısaltır; `agc` pozlama penceresini `<= 9500 µs` ile sınırlar.
   - `rpi_pipeline.yaml` ile Unicam iç RAW tampon sayısı **`6`'ya (`min_total_unicam_buffers: 8`)**, `uvc-gadget` tampon sayısı **`8`'e** çıkarılmıştır.

4. **Donanım Kare Zaman Damgası (`buf.timestamp`) Aktarımı:**
   - Sensörün mikrosaniye hassasiyetindeki yakalama zamanı UVC paket başlığına aktarılır; böylece host tarafında kare aralığı jitter'ı azalır.

5. **Canlı Performans Tablosu (Pi Zero W ARM11 + OV5647 + Spatial Denoise Açık, Full FOV):**
   | Çözünürlük | Teslim Edilen Canlı FPS | USB Bant Genişliği (`maxpacket=1024`) | Ortalama Kare Boyutu | Bozuk JPEG |
   |---|---|---|---|---|
   | **`192x192` (192p)** | **~69.3 FPS** | `80 / 1024` | ~2.5 KB | **0** |
   | **`320x240` (240p)** | **~67.5 FPS** | `153 / 1024` | ~5.0 KB | **0** |
   | **`640x480` (VGA)** | **~58–60 FPS** *(ısınma sonrası)* | `579 / 1024` | ~25.3 KB | **0** |
   | **`800x600` (SVGA)** | **~36.7 FPS** | `606 / 1024` | ~31.0 KB | **0** |
   | **`1280x720` (720p)** | **~29.2 FPS** *(30 FPS tavanı)* | `592 / 1024` | ~94.4 KB | **0** |
   > 💡 **CPU Notu:** Tek çekirdekli Pi Zero W (1 GHz ARM11) aktif Full-FOV yayın sırasında `libcamera vc4/IPA` + saniyede `8.100+` USB ISOC kesmesi nedeniyle **~%84–%95 CPU** kullanır; bu donanım tavanıdır (`Pi Zero 2 W` üzerinde dört çekirdek sayesinde çok daha yüksek boşluk kalır). Akış sırasında eşzamanlı SSH oturumu açılması anlık FPS düşüşüne yol açabilir.

### B. 🏎️ 120–190 FPS OV5647 Modifiye Çekirdek Sürücüsü & ADC Zamanlama Çözümü

Standart Linux çekirdeğinde (`drivers/media/i2c/ov5647.c`) OV5647 sensörü en fazla 640x480 @ 90 FPS veya 1296x972 @ 42 FPS modlarına sahiptir. Göz takibinde deneysel 120–190 FPS merkez kırpma ihtiyacını desteklemek için özel bir sürücü modifikasyonu eklenmiştir:

#### 1. ADC Zamanlama Problemi ve Donanımsal Gri/Beyaz Ekran Hatası:
- OV5647 sensörünün ADC devresi yatay satır süresine ($HTS$) bağımlıdır; $PCLK = 80\text{ MHz}$ altında $HTS < 1730$ olursa görüntü donuk gri/beyaz kalır.
- Sürücüde $HTS = 1730$ sabitlenip $VTS = 248$ ayarlanarak `fast_crop=1` modunda donanımsal **190.95 FPS** teorik tavanı sağlanmıştır.

#### 2. Merkez Kırpma (`fast_crop=1`) vs Tam Görüş Alanı (`fast_crop=0` Varsayılan):
- **Tam Görüş Alanı (`fast_crop=0`, Varsayılan):** Sensörün `2x2` binned geniş açı okuması kullanılır ve alt çözünürlükler (`192x192`, `320x240`, `400x400`) VideoCore IV GPU ISP tarafından kırpmasız ve şeritlenmesiz ölçeklenir. `192x192` ve `320x240` çözünürlüklerde Bayer renk/şerit bozulmalarını önlemek için varsayılan mod budur.
- **Merkez Kırpma (`fast_crop=1`, İsteğe Bağlı):** Sensör merkezinden `640x480` piksel okunur (`crop_left=976, crop_top=732`); daha yüksek sensör hızı ve optik yakınlaştırma verir ancak `192x192` gibi modlarda ISP Bayer hizalamasına duyarlı olabilir. Web panelinden tek tıkla açılıp test edilebilir.

#### 3. Sürücünün Derlenmesi ve Kurulması:
`install.sh` sırasında otomatik derlenir. Bağımsız derlemek için:
```bash
sudo bash /usr/local/bin/build-ov5647-driver.sh
# veya repo içindeyken:
sudo bash scripts/build-ov5647-driver.sh
```

---

### C. 🎯 Çözünürlük Başına Hızlı Kırpma (Fast-Crop) Modu & Varsayılan Harita

| Çözünürlük | Varsayılan Mod | Canlı UVC Hızı (OV5647 Full FOV) | Sensör / ISP Okuma Modu | Kullanım Amacı |
|---|---|---|---|---|
| **`192x192`** | **Tam Görüş (Kapalı)** | **~69.3 FPS** | 640x480 Full FOV + ISP Ölçekleme | En yüksek FPS, düşük USB bant genişliği pupil takibi |
| **`320x240`** | **Tam Görüş (Kapalı)** | **~67.5 FPS** | 640x480 Full FOV + ISP Ölçekleme | Hızlı göz takibi |
| **`400x400`** | **Tam Görüş (Kapalı)** | **~60 FPS** | Full FOV + ISP Ölçekleme | Geniş açılı kare göz alanı |
| **`640x480`** | **Tam Görüş (Kapalı)** | **~58–60 FPS** | 640x480 / Binned Full FOV | Standart geniş açılı VGA görüntü |
| **`800x600`** | **Tam Görüş (Kapalı)** | **~36.7 FPS** | Tam Sensör Geniş Açı | Yüksek çözünürlüklü çevre / göz takibi |
| **`1280x720`** | **Tam Görüş (Kapalı)** | **~29.2 FPS** *(30/15)* | 1920x1080 Binned HD Full FOV | HD dünya/sahne kamerası |

> 💡 **İpucu:** İstediğiniz herhangi bir çözünürlükte `fast_crop` kırpma modunu denemek isterseniz, Web Panelindeki **Fast-Crop** tablosundan tek tıkla açıp kapatabilirsiniz.

---

### D. 🌐 Web Kontrol Paneli (:8080) Özellikleri & REST API

Web arayüzüne (`http://pizero.local:8080` veya `http://<pi-ip>:8080`) girdiğinizde sunulan canlı kontroller:
- **Sistem & Donanım İzleme:** CPU Sıcaklığı, CPU Kullanımı (`%`), **GPU Kullanımı (`VideoCore IV ISP+M2M ~Tahmini`)**, **Gürültü Azaltma & USB (`GPU SDN Aktif/Kapalı · 1024B ISOC`)**, Bellek, Disk, Uptime, Kamera Algılama, Pupil Rolü, Sensör ve Çözünürlük.
- **Pupil Rolü & Çözünürlük/FPS Profili:** `eye0` / `eye1` / `world` / `generic`, sensör (`ov5647`, `imx219`, `ov9281`), yerleşik çözünürlükler (`192x192` dahil) ve Özel Çözünürlük. *(Hazır çözünürlükler Pupil Capture içinden yeniden başlatmasız seçilir; yalnızca Rol veya Özel Çözünürlük değişiminde güvenli reboot yapılır.)*
- **Canlı Kamera Ayarları (`/api/config`):** Yatay/Dikey Çevirme, Otomatik Pozlama, **VideoCore IV GPU Spatial Denoise (`spatial_denoise`)**, **Analog Kazanç / Gain (`analogue_gain`: 1.0x–16.0x)**, Manuel Pozlama (`exposure_value`, 90 FPS için $\le 10000\text{ µs}$ önerilir), Parlaklık, Kontrast, Doygunluk, Keskinlik ve AWB.
- **Fast-Crop Switch'leri & REST API:**
  ```bash
  # Mevcut Fast-Crop durumunu JSON olarak okuma:
  curl http://pizero.local:8080/api/fast_crop

  # Fast-Crop ayarlarını güncelleme (ör. sadece 320x240 için kırpma açma):
  curl -X POST http://pizero.local:8080/api/fast_crop \
       -H "Content-Type: application/json" \
       -d '{"192x192": false, "320x240": true, "640x480": false}'
  ```

---

### E. 🔮 Farklı ve Gelecekteki Kameralar İçin Durum (OV9281, IMX219 vb.)

Sisteme gelecekte farklı bir kamera modülü taktığınızda durum ne olacak?

1. **OV9281 (Monochrome Global Shutter - Önerilen Profesyonel Göz Kamerası):**
   - OV9281 donanımsal olarak **Global Shutter** özelliğine sahiptir (hareket bulanıklığı sıfırdır).
   - Sensörün doğal modları zaten `1280x800 @ 120 FPS` ve `640x480 @ 120-150 FPS` hızlarını **tam görüş alanında (kırpma olmadan)** destekler.
   - OV9281 takıldığında çekirdek yamasına veya daraltılmış merkeze gerek kalmadan doğrudan geniş açıda 120 FPS alınabilir.
2. **IMX219 (Sony 8MP - Pi Camera v2):**
   - IMX219 donanımında `640x480` @ 90-200 FPS doğal 2x2 analog binning modu mevcuttur.
3. **Modüler Tasarım:**
   - Projemizin orkestratör betiği (`start-uvc.sh`), `/etc/default/picam-uvc` içindeki `SENSOR` değişkenine göre otomatik çalışır.
   - Yeni bir kamera taktığınızda tek yapmanız gereken Web Panelinden veya terminalden sensör tipini seçmektir (`SENSOR=ov9281`).

---

### F. Web Panelinden Çözünürlük Ayarlama
Web paneline (`http://pizero.local:8080`) girdiğinizde **"Sensör Profili & Çözünürlük"** bölümünden:
- **192x192 (Pupil En Yüksek FPS):** En düşük USB bant genişliği (`80 / 1024`) ve ~69.3 FPS canlı akış ile pupil göz bebeği takibi için optimize edilmiştir.
- **320x240 (240p):** Düşük bant genişliği (`153 / 1024`) ve ~67.5 FPS (OV9281 ile 90-120 FPS) akıcı göz takibi sağlar.
- **400x400 (Kare Göz Takibi):** Kare sensör alanı isteyen göz algoritmaları için optimize edilmiştir.
- **640x480 (VGA):** VideoCore IV GPU donanım kodlaması + Spatial Denoise ile ~58–60 FPS hızında akıcı çalışır.
- **⚙️ Özel Çözünürlük:** Kutucuklara dilediğiniz çift genişlik ve yükseklik değerini (160x120 - 1920x1080) girip **"📷 Sensörü Kaydet ve Uygula"** butonuna basabilirsiniz.

> ⚠️ **Önemli Not:** Pupil Capture üzerinde aktif video akışı açıkken `uvc-gadget` servisini yeniden başlatmayın; çözünürlük veya servis değişikliği yapmadan önce Pupil Capture'ı kapatın. Canlı GPU FPS değerlerini izlemek için `sudo journalctl -u uvc-gadget -f` komutunu kullanabilirsiniz (her 5 saniyede bir `[GPU] Streaming WxH @ XX.X fps` satırı yazdırılır).

### Pupil Capture'da Kayıt Alma ve Gerçek FPS'i Ölçme
- Kayıt almak için Pupil Capture'da **`R`** tuşuna basın.
- Kayıtlar `C:\Users\murat\recordings\<TARİH>\<SESSION>\` klasörüne kaydedilir.
- Gerçek kayıt FPS'ini ölçmek için PowerShell'de şu komutu çalıştırabilirsiniz:
  ```powershell
  python -c "import numpy as np, glob, os; recs = sorted(glob.glob(os.path.expanduser('~/recordings/*/*/eye0_timestamps.npy'))); ts = np.load(recs[-1]) if recs else None; print('Gerçek Kayıt FPS:', round(1.0/np.mean(np.diff(ts)), 1) if ts is not None and len(ts)>1 else 'Kayıt bulunamadı')"
  ```

---

## 📄 Lisans

Bu proje [MIT Lisansı](LICENSE) ile lisanslanmıştır. Açık kaynak olarak serbestçe kullanılabilir, geliştirilebilir ve dağıtılabilir.
