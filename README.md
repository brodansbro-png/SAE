# SAE — Flutter App

Aplikasi absensi pegawai untuk Android & iOS dengan verifikasi lokasi GPS,
deteksi wajah *liveness*, dan penyimpanan foto ke Cloudinary.

---

## Arsitektur

```
lib/
├── main.dart                     ← Bootstrap: dotenv → Firebase → runApp
├── app/
│   └── theme.dart                ← SaeTheme (Material3, Nunito, teal #00695C)
├── data/                         ← Infrastruktur (Firestore, Cloudinary, sensors)
│   ├── cloudinary_service.dart   ← Upload foto via Dio multipart
│   ├── face_detection_service.dart ← ML Kit + liveness challenge
│   ├── firebase_config.dart      ← Inisialisasi Firebase
│   ├── location_service.dart     ← GPS + deteksi mock location
│   ├── security_service.dart     ← AES-256-GCM + root/emulator detection
│   └── transport_security.dart   ← HTTPS assertion
├── domain/
│   ├── logic/                    ← Haversine, shift rules, geofence, access
│   ├── models/                   ← AttendanceDoc, PermissionDoc, UserDoc, …
│   └── services/                 ← Firestore CRUD + repository layer
│       ├── attendance_repository.dart  ← Full punch cycle
│       ├── leave_repository.dart       ← Pengajuan izin/cuti
│       └── …
├── state/
│   └── app_state.dart            ← ChangeNotifier: auth, GPS, punch, history
└── ui/
    ├── pages/                    ← Layar utama
    │   ├── login_page.dart       ← Animated gradient + pulsing logo
    │   ├── home_shell.dart       ← Bottom nav + SVG icons dari absensiapp
    │   ├── attendance_page.dart  ← Peta zona + kamera liveness + punch buttons
    │   ├── leave_request_page.dart ← Form izin/cuti
    │   ├── history_page.dart
    │   ├── profile_page.dart
    │   └── permissions_page.dart
    └── widgets/
        ├── greeting_animation.dart ← Lottie pagi/siang/sore/malam + ThemeSwitcher
        ├── face_capture_sheet.dart ← Kamera overlay liveness challenge
        ├── zone_map.dart           ← flutter_map + Haversine readout
        └── common.dart
```

---

## Fitur Keamanan

| Lapisan | Implementasi |
|---|---|
| Anti-Fake GPS | `geolocator: Position.isMocked` + `safe_device` |
| Anti-Root/Emulator | `safe_device.isSafeDevice` + `safe_device.isRealDevice` + heuristik HARDWARE fingerprint |
| Liveness | ML Kit: blink + head-turn challenge (2 aksi acak per sesi) |
| Enkripsi koordinat | AES-256-GCM via `pointycastle`, kunci disimpan di Android Keystore / iOS Keychain (`flutter_secure_storage`) |
| Obfuskasi APK | R8 full-mode + `--obfuscate --split-debug-info` + `-repackageclasses 'a'` |
| Anti-MITM | `android:usesCleartextTraffic="false"` + `network_security_config.xml` (blokir user CA) |
| Secret management | `flutter_dotenv` + `--dart-define` (tidak pernah ada `api_secret` di binary) |

---

## Assets yang Diadaptasi

| Sumber | Isi | Dipakai di |
|---|---|---|
| `absensi/assets/animation/` | `pagi.json`, `siang.json`, `sore.json`, `malam.json`, `sun.json`, `moon.json` | `GreetingAnimation` |
| `absensi/assets/fonts/` | Nunito (semua variant) | `SaeTheme.fontFamily` |
| `absensiapp/assets/icons/` | `clock_in.svg`, `clock_out.svg`, `home.svg`, `inbox.svg`, `karyawan.svg`, `add.svg` | `HomeShell` bottom nav |
| `absensiapp/assets/models/` | `MobileFaceNet.tflite`, `face_antispoof.tflite` | `face_detection_service.dart` |
| `sae.png` (root) | Logo master | `sae_logo.png` → launcher icon + `SaeLogo` widget |

---

## Setup

### 1. Prasyarat

- Flutter ≥ 3.13
- Java 17 (untuk Gradle)
- Firebase project dengan Firestore + Authentication diaktifkan
- Akun Cloudinary dengan dua upload preset:
  - `sae_attendance` — untuk foto absensi
  - `sae_leave` — untuk lampiran izin/cuti

### 2. Konfigurasi Firebase

```bash
# Taruh google-services.json di:
android/app/google-services.json

# Pastikan package_name = com.sae.absensi
```

### 3. File `.env`

```bash
cp .env.example .env
# Edit .env dan isi:
# CLOUDINARY_CLOUD_NAME=xxx
# CLOUDINARY_UPLOAD_PRESET=sae_attendance
# CLOUDINARY_LEAVE_PRESET=sae_leave
```

### 4. Jalankan development

```bash
./tools/run-dev.sh
# atau spesifik device:
./tools/run-dev.sh emulator-5554
```

---

## Build Release

### APK (sideload / distribusi internal)

```bash
export CLOUDINARY_CLOUD_NAME="nama-cloud"
export CLOUDINARY_UPLOAD_PRESET="sae_attendance"
export CLOUDINARY_LEAVE_PRESET="sae_leave"
export KEY_STORE="path/ke/keystore.jks"
export KEY_STORE_PASSWORD="password"
export KEY_ALIAS="alias"
export KEY_PASSWORD="password_kunci"

./tools/build-release.sh apk
```

Output: `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`

### AAB (Google Play)

```bash
./tools/build-release.sh aab
```

Output: `build/app/outputs/bundle/release/app-release.aab`

### Debug symbols

Simpan `build/debug-info/` bersama setiap release tag. Upload ke Firebase
Crashlytics untuk deobfuscate stack trace di production.

---

## Skema Firestore

Lihat [`/docs/FIRESTORE-SCHEMA.md`](../../docs/FIRESTORE-SCHEMA.md) untuk
kontrak data lengkap termasuk index komposit yang wajib dibuat manual.

---

## SAE-Dashboard

Dashboard admin berada di `../SAE-Dashboard/`. Gunakan Firebase project yang
**sama** — tidak ada server REST di antara keduanya.

Fitur dashboard terbaru:
- **AttendancePhotoDialog** — foto Cloudinary + data geofence + badge integritas perangkat
- **LeaveStatusTimeline** — alur visual PENDING → APPROVED/REJECTED per pengajuan

```bash
cd ../SAE-Dashboard
npm install
cp .env.example .env   # isi kredensial Firebase
npm run dev
```

---

## Batasan yang Diketahui

- **Geofence di sisi klien** — Firestore tidak punya primitif geospatial. Jarak
  terukur disimpan bersama punch untuk audit.
- **Liveness tidak memverifikasi identitas** — hanya membuktikan wajah hidup
  di depan kamera. Tidak ada perbandingan embedding antar punch (butuh server).
- **Enkripsi koordinat advisory** — kunci harus dijangkau client untuk enkripsi,
  jadi ini bukan E2E. Melindungi dump database, bukan intersep aktif.
- **App Check belum aktif** — langkah hardening tertinggi yang tersedia tanpa
  server. Aktifkan di Firebase Console dan pin ke `firestore.rules`.
