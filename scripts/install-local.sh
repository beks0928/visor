#!/bin/bash
# Ставит Visor в «Программы» для себя: Release со своей подписью ad-hoc, без нотаризации.
# Собранное на этом же Mac приложение запускается без предупреждений Gatekeeper.
# Запущенный Visor закрывается и открывается заново из «Программ».
set -euo pipefail
cd "$(dirname "$0")/.."

# Подпись для себя. Если в связке ключей есть сертификат Apple Development, подписываем им: тогда «личность» приложения
# одна и та же при каждой пересборке, и macOS не спрашивает заново пароль к связке ключей и разрешения (Автоматизация,
# Календари). Без сертификата остаётся ad-hoc: каждая сборка для macOS новое приложение, и все запросы повторяются.
IDENTITY="${VISOR_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
fi
IDENTITY="${IDENTITY:--}"
if [ "$IDENTITY" != "-" ]; then
    export VISOR_LOCAL=1
    echo "==> Подпись: $IDENTITY"
else
    echo "==> Подпись ad-hoc: при каждой установке macOS спросит пароль к связке ключей заново"
fi
VISOR_SIGN_IDENTITY="$IDENTITY" scripts/release.sh

DEST="/Applications/Visor.app"
pkill -x Visor 2>/dev/null || true
sleep 1
rm -rf "$DEST"
ditto build/local/Visor.app "$DEST"
open "$DEST"
echo "==> Visor установлен в $DEST и запущен"
