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

echo "▸ garantindo o xcconfig do Google (vazio é legítimo — ver docs/oauth-google.md)"
test -f Config/Google.xcconfig || cp Config/Google.example.xcconfig Config/Google.xcconfig

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
if [[ "$1" == "--capturar" ]]; then
  ALVO="${2:-/tmp/uni-real.png}"
  # O app é sandboxed: ele só consegue escrever dentro do próprio contêiner.
  # A foto sai de lá e é copiada para onde o usuário pediu.
  DIR=~/Library/Containers/com.okamiops.okamiuni/Data/tmp
  DEST=$(dirname "$ALVO")
  rm -f "$DIR"/uni-real-*.png 2>/dev/null || true

  echo "▸ abrindo para fotografar os estados (o app fecha sozinho)"
  open -W "$APP" --args --capturar

  N=0
  for F in "$DIR"/uni-real-*.png(N); do
    cp "$F" "$DEST/$(basename $F)"
    echo "▸ $DEST/$(basename $F)  ($(sips -g pixelWidth -g pixelHeight "$F" | tail -2 | tr -d ' \n'))"
    N=$((N+1))
  done

  if [[ $N -eq 0 ]]; then
    echo "▸ FALHOU: nenhuma imagem em $DIR"
    echo "  log do app:  log show --last 2m --predicate 'process == \"OkamiUNI\"' | grep captura"
    exit 1
  fi
  exit 0
fi

if [[ "$1" == --ensaiar-* ]]; then
  # O ensaio fala pelo stderr (ver `RehearsalStage`), e `open` entrega o stderr
  # do app ao log do sistema em vez do terminal. Rodar o binário de dentro do
  # bundle dá as mesmas entitlements (elas vêm da assinatura) e devolve as
  # linhas aqui, que é o ponto de um instrumento de medida.
  echo "▸ ensaiando $* (o app se encerra sozinho)"
  "$APP/Contents/MacOS/OkamiUNI" "$@" 2>&1
  exit 0
fi

echo "▸ abrindo"
open "$APP"
