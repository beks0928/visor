#!/bin/bash
# Ставит последнюю версию Visor из релиза на GitHub в «Программы» и запускает.
#
#   curl -fsSL https://raw.githubusercontent.com/beks0928/visor/main/scripts/install.sh | bash
#
# Архив качается командой curl, а не браузером, поэтому macOS не ставит на него метку карантина
# и приложение открывается без предупреждения «нельзя проверить разработчика».
# Перед установкой проверяется контрольная сумма из релиза.
set -euo pipefail

REPO="${VISOR_REPO:-beks0928/visor}"
# VISOR_BASE_URL, VISOR_DEST и VISOR_NO_OPEN нужны для проверки установщика на локальном релизе.
BASE="${VISOR_BASE_URL:-https://github.com/$REPO/releases/latest/download}"
DEST="${VISOR_DEST:-/Applications/Visor.app}"

if [ "$(uname -s)" != "Darwin" ]; then echo "Visor работает только на macOS."; exit 1; fi
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if [ "$MAJOR" -lt 15 ]; then echo "Нужна macOS 15 или новее (у вас $(sw_vers -productVersion))."; exit 1; fi
case "$REPO$BASE" in *OWNER/*) echo "Не задан репозиторий: VISOR_REPO=имя/репозиторий bash scripts/install.sh"; exit 1 ;; esac

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "==> Скачиваю Visor"
curl -fL --progress-bar -o "$WORK/Visor.zip" "$BASE/Visor.zip"
curl -fsSL -o "$WORK/SHA256SUMS" "$BASE/SHA256SUMS"

echo "==> Проверяю контрольную сумму"
EXPECTED=$(grep " Visor.zip\$" "$WORK/SHA256SUMS" | awk '{print $1}')
ACTUAL=$(shasum -a 256 "$WORK/Visor.zip" | awk '{print $1}')
if [ -z "$EXPECTED" ] || [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "Контрольная сумма не совпала: архив повреждён или подменён. Установка отменена."
    exit 1
fi

echo "==> Устанавливаю в $DEST"
ditto -x -k "$WORK/Visor.zip" "$WORK/out"
if [ -z "${VISOR_NO_OPEN:-}" ]; then pkill -x Visor 2>/dev/null || true; sleep 1; fi
rm -rf "$DEST"
ditto "$WORK/out/Visor.app" "$DEST"
# На случай, если архив всё же скачали браузером.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
if [ -z "${VISOR_NO_OPEN:-}" ]; then
    open "$DEST"
    echo "==> Готово. Visor запущен: остров появится у выреза."
else
    echo "==> Готово: $DEST"
fi
