#!/bin/bash
# Подставляет адрес репозитория GitHub во все места проекта: README, установщик, шаблоны отзывов и project.yml
# (кнопки «Сообщить об ошибке» в приложении). Запускается один раз после создания репозитория.
#
#   scripts/set-repo.sh имя/visor
set -euo pipefail
cd "$(dirname "$0")/.."

NEW="${1:-}"
if ! printf '%s' "$NEW" | grep -Eq '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$'; then
    echo "Укажите репозиторий в виде имя/репозиторий, например: scripts/set-repo.sh myname/visor"
    exit 1
fi
OLD=$(sed -n 's/^ *VisorRepository: "\(.*\)"$/\1/p' project.yml)
if [ -z "$OLD" ]; then echo "В project.yml нет ключа VisorRepository."; exit 1; fi

for file in README.md scripts/install.sh .github/ISSUE_TEMPLATE/config.yml project.yml; do
    sed -i '' "s#${OLD}#${NEW}#g" "$file"
done
echo "Готово: $OLD → $NEW. Пересоберите приложение (scripts/release.sh), чтобы кнопки отзыва появились."
