#!/bin/zsh
# Compila do zero e abre o app — a única forma de ter certeza de que a janela na
# tela é do código que está no disco.
#
# ATENÇÃO, AGENTES: este script LANÇA O APP. Ele é para o dono do projeto rodar,
# nunca para verificação automatizada. Agente que precisa ver a interface usa o
# harness de renderização fora da tela (UNIShellTests/RenderHarness.swift).

set -e
cd "$(dirname "$0")/.."

echo "▸ fechando qualquer instância aberta"
pkill -f OkamiUNI.app 2>/dev/null || true
sleep 1

echo "▸ descartando janelas que o macOS guardou da sessão anterior"
rm -rf ~/Library/"Saved Application State/com.okamiops.okamiuni.savedState" 2>/dev/null || true

echo "▸ regerando o projeto"
xcodegen generate >/dev/null

echo "▸ compilando"
xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI -configuration Debug build 2>&1 \
  | grep -E "error:|warning:|BUILD" | grep -v AppIntents || true

APP=$(xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI -configuration Debug \
      -showBuildSettings 2>/dev/null \
      | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{d=$2} / FULL_PRODUCT_NAME/{n=$2} END{print d"/"n}')

echo "▸ binário: $(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$APP/Contents/MacOS/OkamiUNI")"
echo "▸ commit:  $(git log -1 --format='%h %s')"
echo "▸ abrindo"
open "$APP"
