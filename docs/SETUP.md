# SAE — Panduan Setup Lengkap

## Prasyarat

| Tool | Versi minimum |
|---|---|
| Flutter | 3.13 |
| Dart | 3.1 |
| Java | 17 |
| Android SDK | API 21+ |
| Xcode (iOS) | 15+ |
| Node.js (dashboard) | 18+ |

---

## 1. Firebase Setup

1. Buka [Firebase Console](https://console.firebase.google.com)
2. Pilih project `subbagum-mipa`
3. **Android:** Download `google-services.json` → taruh di `android/app/`
4. **iOS:** Download `GoogleService-Info.plist` → taruh di `ios/Runner/`
5. Aktifkan Firestore, Authentication (Email/Password), FCM

### Composite Indexes (wajib dibuat manual)

Di Firebase Console → Firestore → Indexes:

| Collection | Fields |
|---|---|
| `attendance` | `userId` ASC + `recordDate` DESC |
| `attendance` | `recordDate` ASC |
| `permissions` | `userId` ASC + `createdAt` DESC |
| `permissions` | `status` ASC + `createdAt` DESC |

---

## 2. Cloudinary Setup

1. Buka [Cloudinary Console](https://cloudinary.com)
2. Cloud name: `f882n2ov`
3. Buat **Unsigned Upload Preset**:
   - `subbagum` → untuk foto absensi & lampiran izin
4. **JANGAN** pakai `api_secret` di Flutter — hanya preset

---

## 3. Jalankan Development

```bash
cd SAE

# .env sudah terisi dengan kredensial nyata
# Pastikan google-services.json sudah ada

./tools/run-dev.sh
```

---

## 4. Build Release APK

```bash
export KEY_STORE="path/ke/keystore.jks"
export KEY_STORE_PASSWORD="password"
export KEY_ALIAS="alias"
export KEY_PASSWORD="password_kunci"

./tools/build-release.sh apk
```

APK ter-obfuskasi: `build/app/outputs/flutter-apk/`

---

## 5. Dashboard Admin

```bash
cd SAE-Dashboard
npm install
# .env sudah ada dengan kredensial
npm run dev  # http://localhost:5173
```

---

## 6. Fitur Keamanan Aktif

| Fitur | Implementasi |
|---|---|
| Anti Fake GPS | `geolocator.Position.isMocked` |
| Anti Root | `safe_device.isSafeDevice` |
| Anti Emulator | `safe_device.isRealDevice` + hardware fingerprint |
| Anti ganti jam | `FieldValue.serverTimestamp()` + ServerTimeService delta check |
| Enkripsi koordinat | AES-256-GCM, kunci di Android Keystore / iOS Keychain |
| Anti MITM | `usesCleartextTraffic=false` + network_security_config (blokir user CA) |
| Anti decompile | R8 full-mode + `--obfuscate` + `-repackageclasses 'a'` |
| Face liveness | ML Kit blink + head turn 2-challenge random |
| Foto wajib wajah | Punch ditolak jika tidak ada wajah di frame |

---

## 7. Push Notification

Payload FCM yang harus dikirim dari server/dashboard:

```json
{
  "token": "<fcmToken dari users/{uid}>",
  "notification": {
    "title": "Waktunya Absen!",
    "body": "Shift Pagi dimulai pukul 08:00"
  },
  "data": {
    "route": "/attendance"
  }
}
```

Route yang didukung: `/attendance`, `/permissions`, `/profile`

---

## 8. Jadwal Shift & Titik Absen (per pegawai)

Di Dashboard → Pengaturan:
- Tambah zona (titik koordinat + radius 10-2000m)
- Tambah shift (jam mulai, jam selesai, hari kerja, toleransi terlambat)

Di Dashboard → Data Pegawai:
- Assign `zoneId` dan `shiftId` per pegawai
- Setiap pegawai bisa punya zona dan shift berbeda

App Flutter membaca `users/{uid}.shiftId` dan `users/{uid}.zoneId` → resolusi ke dokumen zone/shift dari server → tidak bisa diakali dari client.
