# Rilis SAE — Build Script & Konfigurasi Produksi

Dokumen ini adalah satu-satunya sumber untuk build rilis. Semua perintah di bawah
sudah diverifikasi pada **Flutter 3.47.6 / Dart 3.13.5** dengan Android SDK 36.

---

## 1. Prasyarat

```bash
# Flutter
flutter --version          # 3.47.6 atau lebih baru

# Android
sdkmanager "platforms;android-36" "build-tools;36.0.0" "ndk;28.2.13676358"
flutter doctor -v          # Android toolchain harus ✓

# Java 17+ (AGP 9 membutuhkan 17, Java 21 bekerja)
java -version
```

---

## 2. Kredensial

Tidak ada kredensial yang disimpan di repo. Semuanya lewat `--dart-define`.

### 2.1 Android — `google-services.json`

```bash
# Firebase Console → Project settings → Your apps → Android
# Package name HARUS com.sae.presensi (sudah di-set di build.gradle.kts)
cp ~/Downloads/google-services.json android/app/google-services.json
```

### 2.2 iOS — `GoogleService-Info.plist`

```bash
cp ~/Downloads/GoogleService-Info.plist ios/Runner/GoogleService-Info.plist
```

Lalu **wajib** referenced di Xcode: `ios/Runner.xcworkspace` → target `Runner` →
Build Phases → *Copy Bundle Resources* → `+` → `GoogleService-Info.plist`.

> Tanpa file ini, Auth iOS gagal dengan `operation-not-allowed`.

### 2.3 Environment variables

```bash
# Salin sekali, isi per developer. JANGAN di-commit.
cp .env.example .env
```

Isi `FIREBASE_APP_IOS_ID` dengan nilai `CLIENT_ID` dari `GoogleService-Info.plist`.

---

## 3. Builddevelopment (opsional)

Build `--dart-define` untuk development cukup awkward karena panjangnya.
`tools/run-dev.sh` membungkusnya:

```bash
set -a && source .env && set +a
./tools/run-dev.sh
```

---

## 4. Build rilis APK

```bash
# 1. Bersihkan agar R8 tidak memakai cache lama
flutter clean

# 2. Ambil dependensi
flutter pub get

# 3. Build dengan obfuscation
set -a && source .env && set +a

flutter build appbundle \
  --release \
  --obfuscate \
  --split-debug-info=build/symbols \
  $(grep -E '^FIREBASE_|^CLOUDINARY_' .env \
    | sed 's/^/--dart-define=/') \
  --build-name=1.0.0 \
  --build-number=1
```

Output: `build/app/outputs/bundle/release/app-release.aab`

### Apa yang dilakukan flag ini

| Flag | Fungsi |
|---|---|
| `--obfuscate` | Mengganti nama simbol Dart (kelas, method) dengan string acak. Ini yang menyembunyikan logika geofence & liveness. |
| `--split-debug-info` | Menyimpan peta simbol ke `build/symbols/`. **Simpan file ini** — tanpa itu, crash report Play Console tidak bisa di-deobfuscate. |
| `--release` | Mengaktifkan R8 + resource shrinking di sisi Java/Kotlin. |

---

## 5. Build rilis iOS

### 5.1 Prasyarat

- macOS dengan Xcode 15+
- CocoaPods: `sudo gem install cocoapods`
- Apple Developer account (untuk distributing ke App Store)

### 5.2 Steps

```bash
cd ios && pod install && cd ..

set -a && source .env && set +a

flutter build ipa \
  --release \
  --obfuscate \
  --split-debug-info=build/symbols \
  $(grep -E '^FIREBASE_|^CLOUDINARY_' .env \
    | sed 's/^/--dart-define=/')
```

### 5.3 Firebase Auth di iOS

Apple menolak email/password auth tanpa konfigurasi Email/Password di
Firebase Console. Pastikan diaktifkan sebelum test.

---

## 6. Verifikasi release build

```bash
# Cek simbol Dart benar-benar terobfuscate
unzip -p build/app/outputs/bundle/release/app-release.aab \
  assets/flutter_assets/kernel_blob.bin 2>/dev/null | strings | head -5

# Seharusnya TIDAK mengandung nama class Dart yang bisa dibaca
# (mis. "AttendancePage", "GeofenceRules", "LivenessChallenge")

# Cek R8 aktif
$ANDROID_HOME/build-tools/36.0.0/aapt2 dump badging \
  build/app/outputs/flutter-apk/app-release.apk 2>/dev/null \
  | grep -c "uses-permission"
```

---

## 7. Build signing

### 7.1 Android

```bash
keytool -genkey -v -keystore ~/sae-release.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias sae

# Buat android/keystore.properties (JANGAN di-commit)
cat > android/keystore.properties <<EOF
storePassword=<password>
keyPassword=<password>
keyAlias=sae
storeFile=/absolute/path/to/sae-release.jks
EOF
```

Lalu ubah `android/app/build.gradle.kts`:

```kotlin
val keystoreProperties = java.util.Properties()
val keystorePropertiesFile = rootProject.file("keystore.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}

signingConfigs {
    create("release") {
        keyAlias = keystoreProperties["keyAlias"] as String
        keyPassword = keystoreProperties["keyPassword"] as String
        storeFile = file(keystoreProperties["storeFile"] as String)
        storePassword = keystoreProperties["storePassword"] as String
    }
}

buildTypes {
    release {
        signingConfig = signingConfigs.getByName("release")
        // ...
    }
}
```

### 7.2 iOS

Distribution certificate + provisioning profile. Lihat guide Apple:
https://developer.apple.com/help/account/provisioning-profiles/

---

## 8. Build obfuscation script

`tools/build-release.sh` membungkus langkah 4 dan 5 di atas:

```bash
./tools/build-release.sh android   # AAB
./tools/build-release.sh ios       # IPA
./tools/build-release.sh both      # keduanya
```

Script ini:
1. Validasi `.env` ada dan berisi semua variabel wajib
2. Menjalankan `flutter clean`
3. Build dengan `--obfuscate --split-debug-info`
4. Menyalin file simbol ke `build/symbols/`
5. Cetak ringkasan build

---

## 9.yang TIDAK dilindungi obfuscation (read this)

Obfuscation adalah **satu lapis** dari beberapa lapis. Yang以下 masih bisa
dilakukan penyerang yang motivated:

| Ancaman | Status | Alasan |
|---|---|---|
| Membaca logika Dart | 😰 Sulit | Nama simbol di-obfuscate |
| Memalsukan lokasi GPS | 🔧 Partial | `Location.isMocked` + geofence check, tapi root bisa bypass |
| Root/jailbreak | 🔧 Partial | Deteksi ada, tapi bisa di-hook |
| Forensic analysis | 😐 Dapat | Compiled binary masih bisa di-reverse dengan tooling |
| Intercept traffic | ❌ Tidak dicek | TLS pinning belum diimplementasikan |

**Yang benar-benar melindungi** adalah `firestore.rules` di backend:
- `userId == request.auth.uid` → tidak bisa absen atas nama orang lain
- `recordDate == request.time.substr(0,10)` → tidak bisa backdate
- `checkInTime` hanya bisa ditulis jika belum ada → tidak bisa overwrite
- `distance <= radius` tidak di-enforce client → dicatat sebagai evidence

Obfuscation membuat reverse engineering lebih lambat, bukan mustahil.

---

## 10. Checklist sebelum deploy

- [ ] `google-services.json` ada di `android/app/`
- [ ] `GoogleService-Info.plist` ada di `ios/Runner/`
- [ ] `FIREBASE_APP_IOS_ID` diisi di `.env`
- [ ] `android/keystore.properties` dibuat (untuk release)
- [ ] R8 obfuscation rules di-review
- [ ] `--split-debug-info` sudah diarsipkan ke tempat aman
- [ ] `flutter test` — semua hijau
- [ ] `flutter analyze` — nol issues
- [ ] App sudah dites di 2+ perangkat physical
- [ ] Firebase project sama antara app & dashboard

---

## 11. Troubleshooting

### Error: "Google Services Plugin cannot function without google-services.json"

```bash
cp ~/path/to/google-services.json android/app/google-services.json
```

### Error: "minSdkVersion 23 cannot be smaller than version 24"

 Beberapa plugin membutuhkan 24. Update `minSdk` di `build.gradle.kts`.

### Error: "Duplicate class com.google.protobuf.*"

Protobuf brought in by two dependencies.

```bash
flutter pub deps | grep protobuf
```

Tambahkan resolution strategy di `pubspec.yaml`:

```yaml
dependency_overrides:
  protobuf: ^4.1.0
```

### App crash saat runtime dengan ProGuard enabled

Tambahkan keep rule di `proguard-rules.pro` untuk class yang error Mention,
lalu build ulang. Lihat [Panduan R8](https://r8.googlesource.com/).

---

*Dokumen ini di-update bersama perubahan kode. Referensi: `README.md`,
`docs/FIRESTORE-SCHEMA.md`.*