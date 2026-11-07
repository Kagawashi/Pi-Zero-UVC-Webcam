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
> - Boot ayarlarını (`dwc2`, `camera_auto_detect`, `gpu_mem=128`, `modules-load=dwc2,libcomposite,usb_f_rndis`) otomatik ekler.
> - Gerekli tüm sistem kütüphanelerini (`meson`, `ninja`, `libcamera`, `v4l-utils`) kurar.
> - **VideoCore IV GPU Donanım JPEG (`V4L2_MEMORY_DMABUF`)** hızlandırmalı ve donanım zaman damgası (`buf.timestamp`) destekli `uvc-gadget` sürücüsünü `--buildtype=release` (`-O3`) modunda derler ve sisteme kurar.
> - **Yüksek FPS `libcamera` IPA & Unicam Tuning:** `start-uvc.sh` üzerinden `/etc/picam/rpi_pipeline.yaml` (`min_unicam_buffers: 6`, `min_total_unicam_buffers: 8`) ve `/etc/picam/<sensor>_fast.json` (`n_iter: 0`, `bayes: 0`, `ce_enable: 0`, max pozlama `16666 µs`) yapılandırmalarını otomatik üretir.
> - **Composite Gadget:** Hem UVC Kamera hem de USB Ethernet (RNDIS) desteğini otomatik aktif eder.
> - Sıfır alt-süreç (`sysfs`) tabanlı Web Kontrol Panelini (`:8080`) ve UVC servisini `systemd` arka plan servisi olarak kaydeder.
> - Kurulum bittiğinde ekranda **"Sistemi şimdi yeniden başlatmak istiyor musunuz? [E/h]"** diye sorar ve onayınızla Pi Zero'yu yeniden başlatır.

---

## 4. 🔌 Tek USB Kablosuyla Wi-Fi'sız Doğrudan SSH (RNDIS Ethernet)

Bu projenin en büyük avantajlarından biri **Composite Gadget (Çoklu Aygıt)** mimarisidir.

### Nasıl Çalışır?
Pi Zero'yu bilgisayarınıza Micro USB veri kablosu ile bağladığınızda:
1. Windows cihazı hem bir **Pupil Labs Kamerası (`Pupil Cam1 ID0`)** hem de Ağ Bağdaştırıcıları altında **Sanal Ağ Kartı (`Remote NDIS Compatible Device`)** olarak tanır.
2. Bilgisayar ile Pi Zero arasında doğrudan yerel bir ağ (`169.254.x.x`) kurulur.
3. **Wi-Fi veya telefon interneti OLMADAN:**
   * Doğrudan terminalden:
     ```powershell
     ssh pi@pizero.local
     ```
   * Tarayıcınızdan Web Kontrol Paneline:
     ```
     http://pizero.local:8080
     ```
   yazarak sadece USB kablosu üzerinden Pi Zero'ya anında erişebilirsiniz!

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
| `/usr/local/bin/uvc-gadget` | `libcamera` ISP'den çıkan `YUV420` DMA tamponlarını sıfır kopya (`V4L2_MEMORY_DMABUF`) ile VideoCore IV GPU donanım JPEG kodlayıcısına (`/dev/video31` / `/dev/video11`) aktaran ve donanım zaman damgalı (`buf.timestamp`) UVC akışı üreten C/C++ ikili dosyası. |
| `/usr/local/bin/setup-gadget.sh` | ConfigFS üzerinde hem UVC (`320x240`, `400x400`, `640x480`, `800x600`, `1280x720`) hem RNDIS USB aygıt tanımlarını oluşturan betik. |
| `/usr/local/bin/start-uvc.sh` | Yüksek FPS `libcamera` IPA tuning (`/etc/picam/<sensor>_fast.json`) ve Unicam tampon (`/etc/picam/rpi_pipeline.yaml`) ayarlarını oluşturup GPU donanım hızlandırmalı kamera akışını başlatan orkestratör betik. |
| `/opt/picam-web/` | 8080 portunda çalışan, `sysfs` üzerinden sıfır CPU yüküyle durum izleyen ve tarayıcıdan kamera/rol ayarı yapmayı sağlayan Flask web servisi. |
| `/etc/systemd/system/uvc-gadget.service` | Pi Zero USB kablosu takıldığında kamerayı ve RNDIS ağını başlatan systemd servisi. |
| `/etc/systemd/system/picam-web.service` | Web arayüzünü arka planda çalıştıran systemd servisi. |
| `/etc/picam/config.json` | Web arayüzünün okuduğu ve kaydettiği kalıcı JSON ayar dosyası. |
| `/etc/picam/rpi_pipeline.yaml` | `libcamera` Unicam RAW tampon sayısını (`min_unicam_buffers: 6`, `min_total_unicam_buffers: 8`) artıran boru hattı yapılandırması. |
| `/etc/picam/<sensor>_fast.json` | Göz takibi için ağır 3A algoritmalarını (`alsc n_iter=0`, `awb bayes=0`, `contrast ce_enable=0`) hafifleten ve pozlama süresini `16666 µs` ile sınırlayan yüksek FPS sensör profili. |

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
- **Özel Pi Zero Menüsü:** Eye0 penceresinde doğrudan çözünürlük (`640x480`, `1280x720`) ve FPS (`15` - `90` / `120`) seçenekleri sunar.

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

### A. VideoCore IV GPU Donanım JPEG Sıkıştırması & Yüksek FPS Mimarisi
Tek çekirdekli **Raspberry Pi Zero W (1 GHz ARM11)** üzerinde yazılımsal `libjpeg` kullanıldığında `640x480` çözünürlükte kare başına **45.75 ms (%100 CPU, ~21.9 FPS)** harcanırken, bu projede uygulanan **4 katmanlı donanım optimizasyonu** ile CPU darboğazı ve FPS dalgalanması tamamen ortadan kaldırılmıştır:

1. **Sıfır Kopya (`V4L2_MEMORY_DMABUF`) VideoCore IV GPU Donanım Kodlaması (`/dev/video31` & `/dev/video11`):**
   - `libcamera` ISP'den çıkan `YUV420` görüntünün DMA tampon tanıtıcısı (`dmabuf_fd`), CPU belleğine kopyalanmadan doğrudan VideoCore IV GPU'nun `bcm2835-codec-encode_image` (`/dev/video31`) donanım JPEG motoruna iletilir.
   - **GPU Sıkıştırma Süreleri (Canlı Ölçüm):**
     - `320x240`: **1.62 ms / kare** (**616.4 FPS** teorik kapasite)
     - `400x400`: **1.98 ms / kare** (**505.8 FPS** teorik kapasite)
     - `640x480`: **2.65 ms / kare** (**377.6 FPS** teorik kapasite)
   - `uvc-gadget` sürecinin toplam CPU kullanımı %100'den **~%13.4** seviyesine düşürülmüştür.

2. **Hızlı Göz Takibi `libcamera` IPA Tuning (`/etc/picam/<sensor>_fast.json`) & Unicam Tamponları (`/etc/picam/rpi_pipeline.yaml`):**
   - Standart `libcamera` sensör dosyalarında (`ov5647.json`) bulunan ve tek çekirdekli ARM11 işlemciyi her karede **~24.38 ms (~41 FPS sınırı)** bloklayan ağır fotoğrafçılık algoritmaları (`rpi.alsc` üzerinde 100 iterasyonlu Gauss-Seidel matris çözücüsü, Bayesyen AWB, dinamik histogram kontrast `ce_enable: 1`, `geq`, `sdn`, `dpc`, `hdr`) `start-uvc.sh` tarafından otomatik olarak hafifletilir (`n_iter: 0`, `bayes: 0`, `ce_enable: 0`).
   - Otomatik pozlama (`rpi.agc`) maksimum örtücü (shutter) süresi **16666 µs** ile sınırlandırılarak düşük ışıkta bile sensörün 60 FPS altına düşmesi engellenir.
   - `rpi_pipeline.yaml` ile Unicam iç RAW tampon sayısı `2`'den **`6`'ya (`min_total_unicam_buffers: 8`)**, `uvc-gadget` tampon sayısı ise `4`'ten **`8`'e** çıkarılarak VSYNC kare düşmeleri sıfırlanmıştır.

3. **Donanım Kare Zaman Damgası (`buf.timestamp`) Aktarımı:**
   - CSI sensörünün mikrosaniye hassasiyetindeki donanım yakalama zaman damgası (`framebuf->metadata().timestamp`), `v4l2_queue_buffer()` üzerinden UVC paket başlığına (`dwPresentationTime`) doğrudan yazılır.
   - Böylece Pupil Capture (`pyuvc`), Windows USB paket varış zamanı yerine gerçek sensör zaman damgalarını (**16.00 ms medyan kare aralığı**) okur ve FPS göstergesindeki dalgalanma (jitter) ortadan kalkar.

4. **Canlı Performans Tablosu (OV5647 Sensör + Pi Zero W):**
   | Çözünürlük | GPU Sıkıştırma Süresi | Teslim Edilen Canlı FPS (`pyuvc`) | Ortalama Kare Boyutu | Pi Zero CPU Yükü |
   |---|---|---|---|---|
   | **`320x240`** | **1.62 ms** | **58.13 FPS** *(OV5647 58.92 FPS donanım tavanı)* | ~5.9 KB | **~%13.4** |
   | **`400x400`** | **1.98 ms** | **57.5+ FPS** | ~12.7 KB | **~%14.5** |
   | **`640x480`** | **2.65 ms** | **55.61 FPS** *(Yazılımsal libjpeg ile 21.9 FPS idi)* | ~29.9 KB | **~%16.0** |

### B. Web Panelinden Çözünürlük Ayarlama
Web paneline (`http://pizero.local:8080`) girdiğinizde **"Sensör Profili & Çözünürlük"** bölümünden:
- **320x240 (Önerilen Göz Takibi):** En düşük USB bant genişliği (~340 KB/sn) ve en düşük gecikme ile sabit ~58.1 FPS (OV9281 ile 90-120 FPS) akıcı göz takibi sağlar.
- **400x400 (Kare Göz Takibi):** Kare sensör alanı isteyen göz algoritmaları için optimize edilmiştir.
- **640x480 (VGA):** VideoCore IV GPU donanım kodlaması sayesinde artık VGA çözünürlükte de ~55.6+ FPS hızında akıcı çalışır.
- **⚙️ Özel Çözünürlük:** Açılan kutucuklara dilediğiniz genişlik ve yükseklik değerini (çift sayı, 160x120 - 1920x1080) girip **"📷 Sensörü Kaydet ve Uygula"** butonuna basarak anında etkinleştirebilirsiniz.

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
