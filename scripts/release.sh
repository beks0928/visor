#!/bin/bash
# Сборка Visor для раздачи: Release, подпись Developer ID, нотаризация, печать (staple), zip и dmg.
#
# Нужно один раз:
#   1. Аккаунт Apple Developer Program и сертификат «Developer ID Application» (Xcode → Settings → Accounts → Manage Certificates).
#   2. Пароль приложения на appleid.apple.com и профиль нотаризации (пароль вводите сами, он попадёт в связку ключей):
#        xcrun notarytool store-credentials visor --apple-id "вы@почта" --team-id "TEAMID"
#
# Запуск:
#   VISOR_SIGN_IDENTITY="Developer ID Application: Имя (TEAMID)" scripts/release.sh
#
# Без платного аккаунта: VISOR_SIGN_IDENTITY=- scripts/release.sh
# (подпись ad-hoc, нотаризация пропускается, но Visor.zip, Visor.dmg и SHA256SUMS собираются).
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${VISOR_SIGN_IDENTITY:-}"
PROFILE="${VISOR_NOTARY_PROFILE:-visor}"
# Своя установка (VISOR_LOCAL=1) собирается в отдельную папку, чтобы не стереть файлы релиза для GitHub.
if [ "${VISOR_LOCAL:-0}" = "1" ]; then OUT="build/local"; else OUT="build/release"; fi
APP="build/Build/Products/Release/Visor.app"

if [ -z "$IDENTITY" ]; then
    echo "Задайте VISOR_SIGN_IDENTITY, например:"
    echo "  VISOR_SIGN_IDENTITY=\"Developer ID Application: Имя (TEAMID)\" scripts/release.sh"
    echo "Доступные сертификаты:"
    security find-identity -v -p codesigning || true
    exit 1
fi

ADHOC=0
SIGN_FLAGS="--timestamp"
if [ "$IDENTITY" = "-" ]; then
    ADHOC=1
    SIGN_FLAGS=""
elif [ "${VISOR_LOCAL:-0}" = "1" ]; then
    # Своя подпись (например Apple Development) для установки на этот Mac: личность приложения не меняется между сборками,
    # а нотаризация пропускается.
    ADHOC=1
    SIGN_FLAGS=""
fi

echo "==> Сборка Release"
xcodegen generate >/dev/null
rm -rf "$OUT" "$APP"
mkdir -p "$OUT"
xcodebuild -project Visor.xcodeproj -scheme Visor -configuration Release -derivedDataPath build \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" OTHER_CODE_SIGN_FLAGS="$SIGN_FLAGS" build \
    | grep -E "error|warning: |BUILD" || true

echo "==> Проверка подписи"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -E "audio-input|apple-events|calendars" || {
    echo "В подписи нет нужных прав: проверьте Visor.entitlements"
    exit 1
}
FLAGS=$(codesign -d --verbose=2 "$APP" 2>&1 | grep -o "flags=[^ ]*" || true)
echo "Флаги подписи: $FLAGS"
case "$FLAGS" in
    *runtime*) ;;
    *) echo "Усиленный режим выполнения (runtime) не включён: нотаризация откажет"; exit 1 ;;
esac

# Образ для раздачи: dmg с ярлыком «Программы». Имя одно и то же с подписью и без неё, на него ссылается scripts/install.sh.
make_dmg() {
    local staging="$OUT/dmg"
    rm -rf "$staging"
    mkdir -p "$staging"
    ditto "$APP" "$staging/Visor.app"
    ln -s /Applications "$staging/Applications"
    hdiutil create -volname Visor -srcfolder "$staging" -ov -format UDZO "$OUT/Visor.dmg" >/dev/null
    rm -rf "$staging"
}

# Контрольные суммы для проверки скачанного: их читает scripts/install.sh.
write_sums() {
    (cd "$OUT" && shasum -a 256 Visor.zip Visor.dmg > SHA256SUMS)
}

if [ "$ADHOC" = 1 ]; then
    ditto "$APP" "$OUT/Visor.app"
    if [ "${VISOR_LOCAL:-0}" = "1" ]; then
        echo "==> Подпись «$IDENTITY»: нотаризация пропущена. Приложение: $OUT/Visor.app"
        exit 0
    fi
    ditto -c -k --keepParent "$APP" "$OUT/Visor.zip"
    make_dmg
    write_sums
    echo "==> Подпись «$IDENTITY»: нотаризация пропущена. Для GitHub: $OUT/Visor.zip, $OUT/Visor.dmg, $OUT/SHA256SUMS"
    echo "    Браузер ставит скачанному метку карантина, поэтому такой образ macOS покажет с предупреждением."
    echo "    Установка командой из README (scripts/install.sh) качает через curl и предупреждения не вызывает."
    exit 0
fi

echo "==> Нотаризация приложения (занимает несколько минут)"
ditto -c -k --keepParent "$APP" "$OUT/Visor-notarize.zip"
xcrun notarytool submit "$OUT/Visor-notarize.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vv -t exec "$APP"
rm "$OUT/Visor-notarize.zip"

echo "==> Zip и dmg"
ditto -c -k --keepParent "$APP" "$OUT/Visor.zip"
make_dmg
codesign --sign "$IDENTITY" --timestamp "$OUT/Visor.dmg"
xcrun notarytool submit "$OUT/Visor.dmg" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$OUT/Visor.dmg"
write_sums

echo "==> Готово: $OUT/Visor.zip, $OUT/Visor.dmg и $OUT/SHA256SUMS"
