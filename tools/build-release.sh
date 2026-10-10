#!/usr/bin/env bash
# ============================================================
# SAE — Build Script Release
# Menghasilkan APK / AAB ter-obfuskasi & siap distribusi.
#
# Penggunaan:
#   ./tools/build-release.sh [apk|aab|both]
#
# Env vars wajib (bisa dari .env atau di-export langsung):
#   FIREBASE_API_KEY, FIREBASE_AUTH_DOMAIN, FIREBASE_PROJECT_ID,
#   FIREBASE_STORAGE_BUCKET, FIREBASE_MESSAGING_SENDER_ID,
#   FIREBASE_APP_ID, FIREBASE_MEASUREMENT_ID,
#   CLOUDINARY_CLOUD_NAME, CLOUDINARY_UPLOAD_PRESET,
#   KEY_STORE, KEY_STORE_PASSWORD, KEY_ALIAS, KEY_PASSWORD
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; BLU='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLU}[INFO]${NC} $*"; }
success() { echo -e "${GRN}[OK]${NC}   $*"; }
warn()    { echo -e "${YLW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"
[[ ! -f "pubspec.yaml" ]] && error "Jalankan dari root project SAE."

# Baca .env jika ada (CI biasanya sudah export langsung)
if [[ -f ".env" ]]; then
  # shellcheck disable=SC2046
  export $(grep -v '^#' .env | grep -E '^[A-Z_]+=.+' | sed 's/ *#.*//' | xargs) 2>/dev/null || true
fi

# ── Validasi env vars wajib ───────────────────────────────────────────────────
REQUIRED=(
  FIREBASE_API_KEY FIREBASE_AUTH_DOMAIN FIREBASE_PROJECT_ID
  FIREBASE_APP_ID
  CLOUDINARY_CLOUD_NAME CLOUDINARY_UPLOAD_PRESET
  KEY_STORE KEY_STORE_PASSWORD KEY_ALIAS KEY_PASSWORD
)
MISSING=()
for v in "${REQUIRED[@]}"; do [[ -z "${!v:-}" ]] && MISSING+=("$v"); done
[[ ${#MISSING[@]} -gt 0 ]] && error "Env vars belum diisi: ${MISSING[*]}"
[[ ! -f "$KEY_STORE" ]] && error "Keystore tidak ditemukan: $KEY_STORE"

TARGET="${1:-both}"
info "Flutter: $(flutter --version | head -1)"
info "Firebase project : ${FIREBASE_PROJECT_ID}"
info "Cloudinary cloud : ${CLOUDINARY_CLOUD_NAME}"

info "flutter clean..."
flutter clean
info "flutter pub get..."
flutter pub get

DEBUG_INFO="build/debug-info"
mkdir -p "$DEBUG_INFO"

# --obfuscate + --split-debug-info : obfuskasi nama Dart class/method
# --dart-define : semua secret di-inject saat compile, tidak ada di source code
# --obfuscate : renames Dart symbols (classes, methods) in libapp.so
# --split-debug-info : keeps the symbol map outside the APK, so a crash report
#               from a shipped build can still be deobfuscated.
#
# There is deliberately no --strip flag here. The toolchain emits "The generated
# ELF library contains unobfuscated DWARF debugging information. To avoid this,
# use --strip" during an obfuscated release build, but `flutter build apk` has no
# such option in Flutter 3.47.6 — passing it aborts the build immediately with
# "Could not find an option named --strip". Verify with:
#   flutter build apk --help | grep -- --strip
# before adding any flag to this array.
FLAGS=(
  "--obfuscate"
  "--split-debug-info=$DEBUG_INFO"
  "--dart-define=FIREBASE_API_KEY=${FIREBASE_API_KEY}"
  "--dart-define=FIREBASE_AUTH_DOMAIN=${FIREBASE_AUTH_DOMAIN}"
  "--dart-define=FIREBASE_PROJECT_ID=${FIREBASE_PROJECT_ID}"
  "--dart-define=FIREBASE_STORAGE_BUCKET=${FIREBASE_STORAGE_BUCKET:-}"
  "--dart-define=FIREBASE_MESSAGING_SENDER_ID=${FIREBASE_MESSAGING_SENDER_ID:-}"
  "--dart-define=FIREBASE_APP_ID=${FIREBASE_APP_ID}"
  "--dart-define=FIREBASE_MEASUREMENT_ID=${FIREBASE_MEASUREMENT_ID:-}"
  "--dart-define=FIREBASE_IOS_APP_ID=${FIREBASE_IOS_APP_ID:-}"
  "--dart-define=CLOUDINARY_CLOUD_NAME=${CLOUDINARY_CLOUD_NAME}"
  "--dart-define=CLOUDINARY_UPLOAD_PRESET=${CLOUDINARY_UPLOAD_PRESET}"
  "--dart-define=CLOUDINARY_LEAVE_PRESET=${CLOUDINARY_LEAVE_PRESET:-$CLOUDINARY_UPLOAD_PRESET}"
)

build_apk() {
  info "Build APK release (split-per-abi, obfuscated)..."
  flutter build apk --release "${FLAGS[@]}" --split-per-abi
  APK_DIR="build/app/outputs/flutter-apk"
  success "APK:"
  ls -lh "$APK_DIR"/*.apk 2>/dev/null | awk '{print "    " $5 "  " $NF}' || warn "APK tidak ditemukan"
}

build_aab() {
  info "Build AAB release (obfuscated)..."
  flutter build appbundle --release "${FLAGS[@]}"
  AAB="build/app/outputs/bundle/release/app-release.aab"
  [[ -f "$AAB" ]] \
    && success "AAB: $(du -h "$AAB" | cut -f1) — $AAB" \
    || warn "AAB tidak ditemukan"
}

case "$TARGET" in
  apk)  build_apk ;;
  aab)  build_aab ;;
  both) build_apk; build_aab ;;
  *)    error "Target tidak valid: $TARGET. Gunakan: apk | aab | both" ;;
esac

echo ""
echo -e "${GRN}═══════════════════════════════════════════════${NC}"
echo -e "${GRN} Build selesai${NC}"
echo -e "${GRN}═══════════════════════════════════════════════${NC}"
echo -e "  Debug symbols : ${BLU}$DEBUG_INFO/${NC}"
echo -e "  ${YLW}Simpan debug symbols${NC} untuk deobfuscate stack trace produksi."
echo ""
warn "Jangan commit .env, keystore, atau API key ke git."
