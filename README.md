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

- QEMU (TCG/TCI) tabanlı ikinci bir motorla x86_64 ve ARM64 misafirler (UTM SE yaklaşımı)
- virtio-blk ile disk imajları (`.img`, `.qcow2`) ve paylaşılan klasörler
- virtio-gpu / framebuffer ile grafik ekran
- virtio-net ile ağ (NAT)
- Sıkıştırılmış snapshot'lar ve makineyi "kaydederek kapatma" (Save State)
