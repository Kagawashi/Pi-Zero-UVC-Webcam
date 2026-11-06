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
   - **Hostname:** `pizero` *(veya `makinalasmak`)*
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
git clone https://github.com/muratcankoylan/pi-zero-uvc-cam.git
cd pi-zero-uvc-cam
sudo bash install.sh
```

> 💡 **`install.sh` Neleri Otomatik Yapar?**
> - Boot ayarlarını (`dwc2`, `camera_auto_detect`, `gpu_mem=128`, `modules-load=dwc2,libcomposite,usb_f_rndis`) otomatik ekler.
> - Gerekli tüm sistem kütüphanelerini (`meson`, `ninja`, `libcamera`, `v4l-utils`) kurar.
> - `uvc-gadget` sürücüsünü derler ve sisteme kurar.
> - **Composite Gadget:** Hem UVC Kamera hem de USB Ethernet (RNDIS) desteğini otomatik aktif eder.
> - Web Kontrol Panelini (`:8080`) ve UVC servisini `systemd` arka plan servisi olarak kaydeder.
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
| `/usr/local/bin/uvc-gadget` | V4L2 kamerasından gelen MJPEG video akışını USB UVC portuna aktaran C derlemesi ikili dosya. |
| `/usr/local/bin/setup-gadget.sh` | ConfigFS üzerinde hem UVC hem RNDIS USB aygıt tanımlarını oluşturan betik. |
| `/usr/local/bin/start-uvc.sh` | Donanımsal MJPEG hızlandırmasını ve kamera akışını başlatan orkestratör betik. |
| `/opt/picam-web/` | 8080 portunda çalışan ve tarayıcıdan kamera/rol ayarı yapmayı sağlayan Flask web servisi. |
| `/etc/systemd/system/uvc-gadget.service` | Pi Zero USB kablosu takıldığında kamerayı ve RNDIS ağını başlatan systemd servisi. |
| `/etc/systemd/system/picam-web.service` | Web arayüzünü arka planda çalıştıran systemd servisi. |
| `/etc/picam/config.json` | Web arayüzünün okuduğu ve kaydettiği kalıcı JSON ayar dosyası. |

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

## 10. Canlı Kullanım

1. Pi Zero'yu **ortadaki USB portundan** (PWR değil) kaliteli bir veri kablosu ile bilgisayara bağlayın.
2. Windows Aygıt Yöneticisi'nde:
   * **libusbk devices** altında **`Pupil Cam1 ID0`**
   * **Ağ bağdaştırıcıları** altında **`Remote NDIS Compatible Device`**
   cihazlarının belirdiğini görün.
3. Pupil Capture uygulamasını başlatın:
   ```powershell
   Start-Process "C:\Program Files (x86)\Pupil-Labs\Pupil v3.5.1\Pupil Capture v3.5.1\pupil_capture.exe" -ArgumentList "--skip-driver-installation"
   ```
4. Eye 0 penceresinde menüyü açtığınızda **"Pi Zero Kamera Ayarları"** panelinden 90 FPS canlı yayının keyfini çıkarın!

---

## 11. Özel Çözünürlük & Yüksek FPS (90 FPS) Rehberi

### Web Panelinden Çözünürlük Ayarlama
Web paneline (`http://pizero.local:8080`) girdiğinizde **"Sensör Profili & Çözünürlük"** bölümünden:
- **320x240 (Önerilen Göz Takibi / 90 FPS):** Pi Zero W'nin tek çekirdekli işlemcisinde JPEG sıkıştırma süresini ~80ms'den ~18ms'ye düşürerek tam 60-90 FPS akıcı göz takibi sağlar.
- **400x400 (Kare Göz Takibi):** Kare sensör alanı isteyen göz algoritmaları için optimize edilmiştir.
- **640x480 (VGA):** Standart UVC çözünürlüğü.
- **⚙️ Özel Çözünürlük:** Açılan kutucuklara dilediğiniz genişlik ve yükseklik değerini (çift sayı, 160x120 - 1920x1080) girip **"📷 Sensörü Kaydet ve Uygula"** butonuna basarak anında etkinleştirebilirsiniz.

### Pupil Capture'da Neden 10 FPS Görünür ve Nasıl Çözülür?
1. **İşlemci Darboğazı:** 640x480 çözünürlükte yazılımsal JPEG sıkıştırması nedeniyle Pi Zero işlemcisi %100 yük altına girer ve 10-12 FPS üretir. Çözünürlüğü **`320x240`** yaptığınızda işlemci yükü %75 düşer ve FPS fırlar.
2. **Ortam Işığı & Pozlama:** Loş ışıkta sensör otomatik pozlamayı 100ms'ye kadar uzatır. Web panelinden Otomatik Pozlamayı kapatıp manuel pozlamayı ayarlayarak veya ortamı iyi aydınlatarak tam 90 FPS elde edebilirsiniz.

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
