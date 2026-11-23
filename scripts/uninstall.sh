#!/bin/bash
# Удаляет Visor и то, что он оставил: данные, агента страховки «не засыпать» и правило sudoers (последнее спросит пароль).
# Настройки агентов (~/.claude/settings.json и другие) не трогаются: хуки Visor убираются кнопкой в «Настройки → Агенты».
set -uo pipefail

pkill -x Visor 2>/dev/null || true
# Если был включён режим «не засыпать», возвращаем сон.
sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null || true

launchctl bootout "gui/$(id -u)/com.beksultan.visor.lidguard" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.beksultan.visor.lidguard.plist"
rm -rf /Applications/Visor.app
rm -rf "$HOME/Library/Application Support/Visor"
defaults delete com.beksultan.visor 2>/dev/null || true

if [ -f /etc/sudoers.d/visor-lid ]; then
    echo "Удаляю правило /etc/sudoers.d/visor-lid (нужен пароль)"
    sudo rm -f /etc/sudoers.d/visor-lid
fi
echo "Visor удалён. Ключи в связке ключей (служба com.beksultan.visor) можно убрать в программе «Связка ключей»."
