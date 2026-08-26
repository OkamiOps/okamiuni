#!/usr/bin/env bash
# Baixa as famílias OFL que o design usa para App/Resources/Fonts/.
# Rode de novo quando quiser atualizar as faces.
set -euo pipefail

DEST="$(cd "$(dirname "$0")/.." && pwd)/App/Resources/Fonts"
mkdir -p "$DEST"
BASE="https://raw.githubusercontent.com/google/fonts/main"

# caminho-no-repo -> nome-do-arquivo-local
FILES=(
  "ofl/newsreader/Newsreader%5Bopsz,wght%5D.ttf|Newsreader.ttf"
  "ofl/newsreader/Newsreader-Italic%5Bopsz,wght%5D.ttf|Newsreader-Italic.ttf"
  "ofl/spacegrotesk/SpaceGrotesk%5Bwght%5D.ttf|SpaceGrotesk.ttf"
  "ofl/inter/Inter%5Bopsz,wght%5D.ttf|Inter.ttf"
  "ofl/intertight/InterTight%5Bwght%5D.ttf|InterTight.ttf"
  "ofl/ibmplexmono/IBMPlexMono-Regular.ttf|IBMPlexMono-Regular.ttf"
  "ofl/ibmplexmono/IBMPlexMono-Medium.ttf|IBMPlexMono-Medium.ttf"
  "ofl/jetbrainsmono/JetBrainsMono%5Bwght%5D.ttf|JetBrainsMono.ttf"
)

for entry in "${FILES[@]}"; do
  path="${entry%%|*}"
  name="${entry##*|}"
  echo "baixando $name"
  curl -fsSL "$BASE/$path" -o "$DEST/$name"
done

echo
echo "arquivos em $DEST:"
ls -la "$DEST"
