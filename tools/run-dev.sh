#!/usr/bin/env bash
# ============================================================
# SAE — Jalankan mode development
# Membaca .env lalu menyuntikkan semua variabel ke --dart-define
# sehingga tidak ada plaintext secret di source code.
#
# Penggunaan:
#   ./tools/run-dev.sh [device_id]
#
# Prasyarat: salin .env.example ke .env dan isi nilainya.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"
[[ ! -f "pubspec.yaml" ]] && { echo "Tidak menemukan pubspec.yaml"; exit 1; }

# Baca .env
if [[ ! -f ".env" ]]; then
  echo "ERROR: .env tidak ditemukan. Salin dari .env.example lalu isi nilainya."
  exit 1
fi
# shellcheck disable=SC2046
export $(grep -v '^#' .env | grep -E '^[A-Z_]+=.+' | sed 's/ *#.*//' | xargs)

DEVICE="${1:-}"
DEVICE_FLAG=""
[[ -n "$DEVICE" ]] && DEVICE_FLAG="-d $DEVICE"

flutter pub get

echo "▶ Menjalankan SAE di mode development..."
echo "  Firebase project : ${FIREBASE_PROJECT_ID:-tidak diisi}"
echo "  Cloudinary cloud : ${CLOUDINARY_CLOUD_NAME:-tidak diisi}"
echo "  App name         : ${APP_NAME:-SAE Absensi}"
echo ""

# shellcheck disable=SC2086
flutter run $DEVICE_FLAG \
  --dart-define="FIREBASE_API_KEY=${FIREBASE_API_KEY:-}" \
  --dart-define="FIREBASE_AUTH_DOMAIN=${FIREBASE_AUTH_DOMAIN:-}" \
  --dart-define="FIREBASE_PROJECT_ID=${FIREBASE_PROJECT_ID:-}" \
  --dart-define="FIREBASE_STORAGE_BUCKET=${FIREBASE_STORAGE_BUCKET:-}" \
  --dart-define="FIREBASE_MESSAGING_SENDER_ID=${FIREBASE_MESSAGING_SENDER_ID:-}" \
  --dart-define="FIREBASE_APP_ID=${FIREBASE_APP_ID:-}" \
  --dart-define="FIREBASE_MEASUREMENT_ID=${FIREBASE_MEASUREMENT_ID:-}" \
  --dart-define="FIREBASE_IOS_APP_ID=${FIREBASE_IOS_APP_ID:-}" \
  --dart-define="CLOUDINARY_CLOUD_NAME=${CLOUDINARY_CLOUD_NAME:-}" \
  --dart-define="CLOUDINARY_UPLOAD_PRESET=${CLOUDINARY_UPLOAD_PRESET:-}" \
  --dart-define="CLOUDINARY_LEAVE_PRESET=${CLOUDINARY_LEAVE_PRESET:-}"
