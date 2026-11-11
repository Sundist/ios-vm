# PocketVM — iPhone için sanal makine yöneticisi

PocketVM, VirtualBox tarzı bir sanal makine uygulamasıdır ve iPhone / iPad üzerinde çalışır.
Sanal makine oluşturabilir, ayarlarını düzenleyebilir, makineyi başlatıp duraklatabilir,
sıfırlayabilir ve kapatabilirsiniz. Makinenin durumunu **snapshot** olarak kaydedip daha sonra
geri yükleyebilir, misafir sistemi de tam ekran seri konsoldan kullanabilirsiniz.

> **Neden VirtualBox'ın kendisi değil?** iOS, App Store uygulamalarının Hypervisor.framework
> kullanmasına ve JIT (çalışma anında kod üretme) yapmasına izin vermez. Bu yüzden
> VirtualBox'taki gibi donanım destekli sanallaştırma iPhone'da mümkün değildir. PocketVM,
> UTM SE'nin kullandığı yolu izler: misafir CPU'yu **yorumlayıcı (interpreter)** ile
> emüle eder. Bu yöntem iOS kurallarına uyar ve jailbreak gerektirmez.

## Özellikler

- **VM Yöneticisi**: makine listesi, ayrıntı paneli (Genel, Sistem, Depolama, Seri Port,
  Snapshot'lar, Açıklama), oluşturma sihirbazı, ayarlar, klonlama ve silme.
- **Emüle edilen donanım** (`mini-rv32ima` ile uyumlu bellek haritası):
  - RV32IMA + Zicsr CPU (machine mode, tek çekirdek)
  - 1–512 MB RAM (`0x8000_0000`)
  - NS16550A UART seri konsol (`0x1000_0000`)
  - CLINT zamanlayıcısı, 1 MHz (`0x1100_0000`)
  - syscon ile kapatma ve yeniden başlatma (`0x1110_0000`)
  - Linux için otomatik üretilen device tree (DTB) ve önyükleme argümanları
- **Misafir sistemler**:
  - **PocketVM Monitor**: uygulamaya gömülü küçük bir firmware. Hiçbir dosya gerektirmez.
    Yazdığınızı ekrana geri yazar, Ctrl‑D ile makineyi kapatır.
  - **Linux (RISC‑V 32‑bit, no‑MMU)**: `mini-rv32ima` için derlenmiş, initramfs içeren bir
    `Image` çekirdek dosyasıyla Linux açılır.
- **Konsol**: VT100 kaçış dizilerini destekler (silme, imleç, renk kodlarını yok sayma).
  Hem yazılım hem donanım klavyesiyle doğrudan tuş girişi yapılır. Esc, Tab, Ctrl, ok tuşları
  için bir tuş çubuğu vardır. Kopyalama, yapıştırma ve yazı boyutu ayarı da desteklenir.
- **Snapshot'lar**: CPU, cihaz durumu ve RAM'in tamamı kaydedilir. "Restore" ile makine
  kaydedildiği yerden devam eder.
- Boştaki misafir `WFI` komutunu çalıştırır ve motor bu sırada uyur. Böylece işlemci ve pil
  boşa harcanmaz.
- Makineler `Documents/Machines/` altında tutulur ve Dosyalar (Files) uygulamasından
  görülebilir.

## Windows ve ISO çalıştırma (x86 PC)

PC makineleri, açık kaynak x86 emülatörü [v86](https://github.com/copy/v86) ile çalışır
(BSD-2, sürüm 0.5.471, `App/PCWeb` içinde). v86, x86 kodunu WebAssembly'ye çevirir. iOS'ta
JIT yalnızca WebKit'e izinli olduğu için v86 bir `WKWebView` içinde çalışır ve yorumlayıcıdan
çok daha hızlıdır.

- **Desteklenenler:** 32-bit x86 sistemler. Windows 95/98/ME, Windows 2000/XP,
  Windows Vista/7 32-bit (deneysel ve çok yavaş), 32-bit Linux ISO'ları, FreeDOS, KolibriOS,
  ReactOS…
- **Desteklenmeyenler:** 64-bit sistemler. **Windows 10/11 64-bit çalışmaz.**
- **CD/DVD:** ISO dosyası olduğu yerden (Dosyalar, iCloud, iPhone'umda) okunur, kopyalanmaz.
- **Sabit disk:** boş disk oluşturulabilir veya mevcut bir raw `.img` eklenebilir. Misafirin
  diske yazdıkları anında iPhone'daki disk dosyasına kaydedilir.
- **Save State:** makineyi kaldığı yerden devam ettirmek için RAM ve CPU durumu kaydedilir.
- **Kontroller:** dokunmatik trackpad (dokun = tık, iki parmak = sağ tık, iki parmakla
  kaydırma). Ekran klavyesi ⌨︎ ile açılır. Tuş çubuğunda Ctrl+Alt+Del, F1–F12, Esc, Win ve
  ok tuşları var. Donanım klavyesi de çalışır.
- **Windows XP kurulumu:** 512 MB RAM, 4 GB disk, ACPI kapalı. Kurulum başında F5'e basıp
  "Standard PC" seçin.

## Ana ekrana ekleme

Her sanal makine ana ekrana iki şekilde eklenebilir (uygulamada **Add to Home Screen…**
adım adım gösterir):

1. **Uygulama simgesi:** Kestirmeler (Shortcuts) uygulamasında *Start Virtual Machine*
   eylemini seçip makineyi belirleyin, ardından *Ana Ekrana Ekle* deyin. İsim ve simgeyi siz
   seçersiniz; simge ayrı bir uygulama gibi görünür. Siri'ye "Start ‹ad› in PocketVM" de
   diyebilirsiniz.
2. **Widget:** *PocketVM › Virtual Machine* widget'ını ekleyip düzenleyerek makineyi seçin.

Her ikisi de `pocketvm://start?id=<uuid>` bağlantısıyla uygulamayı açar ve makineyi başlatır.
Widget ile uygulama aynı App Group'u kullanır. İmzalamadan önce `project.yml` dosyasındaki
`APP_BUNDLE_ID` ve `APP_GROUP_ID` değerlerini kendi kimliklerinizle değiştirin.

## Proje yapısı

```
VMCore/                    Platformdan bağımsız emülatör çekirdeği (Swift Package)
  Sources/VMCore/
    RV32Machine.swift      CPU yorumlayıcısı + bellek + UART/CLINT/syscon
    DeviceTree.swift       FDT (DTB) üretici
    RVAssembler.swift      Küçük RISC-V assembler (firmware ve testler için)
    MonitorFirmware.swift  Gömülü demo firmware
    MachineSnapshot.swift  Durum kaydetme / geri yükleme
    TerminalBuffer.swift   VT100 benzeri terminal modeli
    VMEngine.swift         Arka plan iş parçacığında çalışan VM motoru
    VMConfiguration.swift  Makine ayarları (Codable)
    VMStore.swift          Diskteki makine kütüphanesi
  Tests/VMCoreTests/       Birim testleri
App/                       SwiftUI iOS uygulaması
  AppModel.swift, VMSession.swift
  Views/                   RootView, MachineDetailView, NewMachineView,
                           MachineSettingsView, ConsoleView, TerminalInputView
App/PC/                    x86 PC motoru (WKWebView + v86, disk/durum köprüsü)
App/PCWeb/                 v86, BIOS'lar ve sayfa betikleri (pvm.js, pvm-disk.js)
App/Intents/, Shared/      App Intents (Kestirmeler / Siri)
Widget/                    Ana ekran widget'ı
tests/pcweb/               Disk köprüsü testleri (Node.js)
scripts/fetch-v86.sh       v86 ve BIOS'ları sabit sürümden indirir
project.yml                XcodeGen proje tanımı
```

## Derleme

Gereksinimler: Xcode 15 veya üstü (iOS 17 SDK) ve [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate          # PocketVM.xcodeproj dosyasını üretir
open PocketVM.xcodeproj
```

Xcode'da *Signing & Capabilities* sekmesinden kendi Team'inizi seçin, gerekiyorsa
`PRODUCT_BUNDLE_IDENTIFIER` değerini değiştirin ve uygulamayı iPhone'unuzda çalıştırın.
Hız için **Release** yapılandırmasıyla derlemenizi öneririm. Debug derlemede yorumlayıcı
çok daha yavaştır.

Çekirdek testleri:

```bash
swift test --package-path VMCore
```

GitHub Actions (`.github/workflows/ci.yml`) her push'ta macOS üzerinde testleri çalıştırır
ve uygulamayı iOS Simulator için derler.

## Linux çalıştırmak

1. RV32 no-MMU bir Linux `Image` dosyası edinin. Örneğin
   [cnlohr/mini-rv32ima](https://github.com/cnlohr/mini-rv32ima) projesinin buildroot
   yapılandırmasıyla derleyebilir ya da projenin yayınladığı hazır görüntülerden birini
   kullanabilirsiniz.
2. Uygulamada **+** → Tür: *Linux (RISC‑V 32‑bit, no‑MMU)* seçin, belleği 64 MB yapın ve
   *Kernel Image* olarak dosyayı seçin.
3. **Start**'a basın. Açılış mesajları konsolda görünür. `poweroff` yazarak makineyi
   düzgünce kapatabilirsiniz.

Varsayılan önyükleme argümanları:
`earlycon=uart8250,mmio,0x10000000,1000000 console=ttyS0`

## Yol haritası

- QEMU (TCG/TCI) tabanlı bir motorla x86_64 ve ARM64 misafirler (64-bit Windows için gerekli)
- virtio-blk ile disk imajları (`.img`, `.qcow2`) ve paylaşılan klasörler
- virtio-gpu / framebuffer ile grafik ekran
- virtio-net ile ağ (NAT)
- Sıkıştırılmış snapshot'lar ve makineyi "kaydederek kapatma" (Save State)
