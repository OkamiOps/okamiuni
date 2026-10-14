#!/bin/zsh
# Empacota, assina, notariza e publica uma release do OkamiUNI: build Release
# assinado com Developer ID, notarização, instalador .dmg (Tools/dmg),
# appcast.xml (Sparkle 2) e release no GitHub.
#
# Uso:
#   Tools/publicar-release.sh X.Y.Z [--dry-run] [--instalar] [--assinatura SIG]
#
# --dry-run        faz tudo que não depende do certificado "Developer ID
#                   Application", do perfil de notarização ou de publicar de
#                   fato: xcodegen, archive, (export quando possível), zip,
#                   assinatura Sparkle (real ou provisória) e appcast.xml —
#                   tudo em /tmp/okamiuni-release-dryrun. Não toca em git além
#                   de ler o estado, não cria tag/release, não dá push.
# --instalar        depois do build, troca /Applications/OkamiUNI.app pela
#                   build recém-gerada (fecha o app antes; guarda a versão
#                   antiga em /tmp).
# --assinatura SIG  usa SIG como sparkle:edSignature em vez de chamar o
#                   sign_update do Sparkle. Útil em dry-run antes de o
#                   Sparkle estar resolvido no projeto.
#
# Variável de ambiente SPARKLE_BIN pode apontar direto para o binário
# sign_update, pulando a busca em DerivedData/SourcePackages.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

REPO="OkamiOps/okamiuni"
TEAM_ID="7U9S5DB9K9"
NOTARY_PROFILE="okamiuni-notary"
SCHEME="OkamiUNI"
PROJECT="OkamiUNI.xcodeproj"
APP_NAME="OkamiUNI.app"

log() { echo "▸ $*"; }
err() { echo "▸ ERRO: $*" >&2; }

# ---------------------------------------------------------------------------
# Argumentos
# ---------------------------------------------------------------------------

VERSION=""
DRY_RUN=0
INSTALL=0
SIGNATURE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --instalar) INSTALL=1; shift ;;
    --assinatura)
      [[ $# -ge 2 ]] || { err "--assinatura precisa de um valor"; exit 1; }
      SIGNATURE_OVERRIDE="$2"; shift 2 ;;
    -*) err "opção desconhecida: $1"; exit 1 ;;
    *) VERSION="$1"; shift ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  err "uso: Tools/publicar-release.sh X.Y.Z [--dry-run] [--instalar] [--assinatura SIG]"
  exit 1
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  err "a versão precisa ser X.Y.Z (recebi '$VERSION')"
  exit 1
fi

if [[ $DRY_RUN -eq 1 ]]; then
  WORK_DIR="/tmp/okamiuni-release-dryrun"
else
  WORK_DIR="/tmp/okamiuni-release-$VERSION"
fi
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

log "preparando release $VERSION em $WORK_DIR$( [[ $DRY_RUN -eq 1 ]] && echo ' (dry-run)' )"

# ---------------------------------------------------------------------------
# Instalação local (usada tanto no fim do dry-run quanto da publicação real)
# ---------------------------------------------------------------------------

instalar_localmente() {
  local origem="$1"
  log "--instalar: trocando /Applications/$APP_NAME"
  osascript -e "tell application \"OkamiUNI\" to quit" >/dev/null 2>&1 || true
  sleep 1
  if [[ -d "/Applications/$APP_NAME" ]]; then
    local backup="/tmp/${APP_NAME}.bak-$(date +%Y%m%d%H%M%S)"
    log "backup da versão atual em $backup"
    mv "/Applications/$APP_NAME" "$backup"
  fi
  cp -R "$origem" "/Applications/$APP_NAME"
  log "instalado em /Applications/$APP_NAME"
}

# ---------------------------------------------------------------------------
# 1. Pré-condições
# ---------------------------------------------------------------------------

if [[ $DRY_RUN -eq 0 ]]; then
  BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  if [[ "$BRANCH" != "main" ]]; then
    err "publicação precisa rodar a partir de 'main' (está em '$BRANCH')"
    exit 1
  fi
fi

if [[ -n "$(git status --porcelain)" ]]; then
  err "árvore git não está limpa — faça commit ou descarte as mudanças antes de publicar"
  git status --porcelain >&2
  exit 1
fi

log "verificando as seções do changelog para $VERSION"
if ! python3 -I - "$VERSION" <<'PY'
import sys
sys.path.insert(0, "tools")
import appcast

version = sys.argv[1]
for path in ("CHANGELOG.md", "CHANGELOG.pt-BR.md"):
    with open(path, encoding="utf-8") as fh:
        appcast.extract_changelog_bullets(fh.read(), version)
PY
then
  err "changelog sem a seção '## $VERSION — ...' em CHANGELOG.md e/ou CHANGELOG.pt-BR.md"
  exit 1
fi

NOTES_EN="docs/releases/v$VERSION.md"
NOTES_PT="docs/releases/v$VERSION.pt-BR.md"
for f in "$NOTES_EN" "$NOTES_PT"; do
  if [[ ! -f "$f" ]]; then
    err "faltam as notas de release: $f"
    exit 1
  fi
done

HAVE_DEVID=0
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
  HAVE_DEVID=1
fi

# Credencial do notarytool. O perfil mora no Keychain protegido do macOS, que
# fica inacessível com a tela bloqueada — e uma notarização pode levar horas.
# Sem ele, usa a senha de app guardada no Keychain de login (`okami_asc_pw`),
# que continua legível. Ver AGENTS.md.
NOTARY_ARGS=()
HAVE_NOTARY=0
if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
  HAVE_NOTARY=1
else
  NOTARY_PW="$(security find-generic-password -s okami_asc_pw -a msant262@gmail.com -w 2>/dev/null || true)"
  if [[ -n "$NOTARY_PW" ]]; then
    NOTARY_ARGS=(--apple-id msant262@gmail.com --team-id 7U9S5DB9K9 --password "$NOTARY_PW")
    if xcrun notarytool history "${NOTARY_ARGS[@]}" >/dev/null 2>&1; then
      log "perfil '$NOTARY_PROFILE' inacessível; usando a senha de app do Keychain de login"
      HAVE_NOTARY=1
    fi
  fi
  unset NOTARY_PW
fi

# O sign_update vem nos artefatos do pacote do Sparkle. Procura primeiro no
# cache próprio do script e no DerivedData do Xcode; sem achar, resolve os
# pacotes no cache — assim a release não depende de onde o Xcode baixou.
# `old_dsa_scripts/sign_update` é o assinador DSA antigo: nunca serve aqui.
SPARKLE_PKG_CACHE="$HOME/Library/Caches/okamiuni-release/SourcePackages"
acha_sign_update() {
  find "$SPARKLE_PKG_CACHE" "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 7 \
    -path '*/artifacts/*/Sparkle/bin/sign_update' -perm +111 2>/dev/null | head -1 || true
}
SPARKLE_BIN="${SPARKLE_BIN:-}"
if [[ -z "$SPARKLE_BIN" ]]; then
  SPARKLE_BIN="$(acha_sign_update)"
fi
if [[ -z "$SPARKLE_BIN" && -z "$SIGNATURE_OVERRIDE" ]]; then
  log "resolvendo os pacotes Swift para achar o sign_update do Sparkle"
  test -f Config/Google.xcconfig || cp Config/Google.example.xcconfig Config/Google.xcconfig
  xcodegen generate >/dev/null
  mkdir -p "$SPARKLE_PKG_CACHE"
  xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI \
    -resolvePackageDependencies -clonedSourcePackagesDirPath "$SPARKLE_PKG_CACHE" >/dev/null \
    || log "AVISO: xcodebuild -resolvePackageDependencies falhou"
  SPARKLE_BIN="$(acha_sign_update)"
fi
HAVE_SPARKLE=0
[[ -n "$SPARKLE_BIN" && -x "$SPARKLE_BIN" ]] && HAVE_SPARKLE=1

# O instalador (.dmg) é montado pelo dmgbuild, que escreve o layout da janela
# direto no .DS_Store — sem AppleScript no Finder, então funciona com a tela
# bloqueada. Mora num venv próprio no cache, com a versão fixada.
DMG_VENV="$HOME/Library/Caches/okamiuni-release/venv"
DMGBUILD_VERSION="1.6.5"
if ! "$DMG_VENV/bin/dmgbuild" --help >/dev/null 2>&1 \
    || [[ "$("$DMG_VENV/bin/pip" show dmgbuild 2>/dev/null | awk '/^Version:/{print $2}')" != "$DMGBUILD_VERSION" ]]; then
  log "instalando dmgbuild $DMGBUILD_VERSION em $DMG_VENV"
  python3 -m venv "$DMG_VENV"
  "$DMG_VENV/bin/pip" install -q "dmgbuild==$DMGBUILD_VERSION"
fi

if [[ $DRY_RUN -eq 0 ]]; then
  if [[ $HAVE_DEVID -eq 0 ]]; then
    err "identidade 'Developer ID Application' não encontrada (security find-identity -v -p codesigning)"
    exit 1
  fi
  if [[ $HAVE_NOTARY -eq 0 ]]; then
    err "perfil de notarização '$NOTARY_PROFILE' não encontrado (xcrun notarytool store-credentials $NOTARY_PROFILE)"
    exit 1
  fi
  if [[ $HAVE_SPARKLE -eq 0 && -z "$SIGNATURE_OVERRIDE" ]]; then
    err "binário sign_update do Sparkle não encontrado; defina SPARKLE_BIN ou rode xcodebuild -resolvePackageDependencies"
    exit 1
  fi
else
  [[ $HAVE_DEVID -eq 1 ]] || log "AVISO (dry-run): sem identidade 'Developer ID Application' — pulando exportArchive/notarização/staple; o .app fica assinado como Apple Development"
  [[ $HAVE_NOTARY -eq 1 ]] || log "AVISO (dry-run): perfil de notarização '$NOTARY_PROFILE' não encontrado — pulando notarização/staple"
  if [[ $HAVE_SPARKLE -eq 0 && -z "$SIGNATURE_OVERRIDE" ]]; then
    log "AVISO (dry-run): sign_update do Sparkle não encontrado (o Sparkle pode ainda não estar resolvido no projeto) — usando uma assinatura PROVISÓRIA, que NÃO é uma assinatura EdDSA real"
  fi
fi

# ---------------------------------------------------------------------------
# 2. Versão em project.yml
# ---------------------------------------------------------------------------

CURRENT_MARKETING="$(awk -F': ' '/MARKETING_VERSION:/{gsub(/"/,"",$2); print $2; exit}' project.yml)"
CURRENT_BUILD="$(awk -F': ' '/CURRENT_PROJECT_VERSION:/{gsub(/"/,"",$2); print $2; exit}' project.yml)"

PROJECT_YML_BACKUP=""
if [[ "$CURRENT_MARKETING" == "$VERSION" ]]; then
  log "project.yml já está em $VERSION (build $CURRENT_BUILD) — não faço bump"
  BUILD_NUMBER="$CURRENT_BUILD"
else
  BUILD_NUMBER=$(( CURRENT_BUILD + 1 ))
  log "bumping project.yml: $CURRENT_MARKETING (build $CURRENT_BUILD) → $VERSION (build $BUILD_NUMBER)"
  PROJECT_YML_BACKUP="$(mktemp /tmp/okamiuni-project-yml-backup.XXXXXX)"
  cp project.yml "$PROJECT_YML_BACKUP"
  sed -i '' "s/MARKETING_VERSION: \"$CURRENT_MARKETING\"/MARKETING_VERSION: \"$VERSION\"/" project.yml
  sed -i '' "s/CURRENT_PROJECT_VERSION: \"$CURRENT_BUILD\"/CURRENT_PROJECT_VERSION: \"$BUILD_NUMBER\"/" project.yml
fi

restaurar_project_yml() {
  if [[ -n "$PROJECT_YML_BACKUP" && $DRY_RUN -eq 1 ]]; then
    log "restaurando project.yml original (dry-run)"
    cp "$PROJECT_YML_BACKUP" project.yml
    rm -f "$PROJECT_YML_BACKUP"
    xcodegen generate >/dev/null 2>&1 || true
  fi
}
trap restaurar_project_yml EXIT

# ---------------------------------------------------------------------------
# 3. xcodegen + archive
# ---------------------------------------------------------------------------

log "garantindo o xcconfig do Google (vazio é legítimo — ver docs/oauth-google.md)"
test -f Config/Google.xcconfig || cp Config/Google.example.xcconfig Config/Google.xcconfig

log "xcodegen generate"
if ! xcodegen generate > "$WORK_DIR/xcodegen.log" 2>&1; then
  err "xcodegen generate falhou — log em $WORK_DIR/xcodegen.log"
  cat "$WORK_DIR/xcodegen.log" >&2
  exit 1
fi

ARCHIVE_PATH="$WORK_DIR/OkamiUNI.xcarchive"
log "xcodebuild archive (Release) → $ARCHIVE_PATH"
if ! xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    > "$WORK_DIR/archive.log" 2>&1; then
  err "xcodebuild archive falhou — log em $WORK_DIR/archive.log"
  tail -60 "$WORK_DIR/archive.log" >&2
  exit 1
fi
grep -E "error:|warning:|BUILD " "$WORK_DIR/archive.log" | grep -v AppIntents || true

if [[ ! -d "$ARCHIVE_PATH" ]]; then
  err "archive não foi criado em $ARCHIVE_PATH"
  exit 1
fi

# ---------------------------------------------------------------------------
# 4. Export (re-assina com Developer ID) + verificação
# ---------------------------------------------------------------------------

if [[ $HAVE_DEVID -eq 1 ]]; then
  EXPORT_OPTIONS="$WORK_DIR/ExportOptions.plist"
  cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>signingCertificate</key>
  <string>Developer ID Application</string>
  <key>teamID</key>
  <string>$TEAM_ID</string>
</dict>
</plist>
PLIST

  EXPORT_PATH="$WORK_DIR/export"
  log "xcodebuild -exportArchive (developer-id) → $EXPORT_PATH"
  if ! xcodebuild -exportArchive \
      -archivePath "$ARCHIVE_PATH" \
      -exportPath "$EXPORT_PATH" \
      -exportOptionsPlist "$EXPORT_OPTIONS" \
      > "$WORK_DIR/export.log" 2>&1; then
    err "xcodebuild -exportArchive falhou — log em $WORK_DIR/export.log"
    tail -60 "$WORK_DIR/export.log" >&2
    exit 1
  fi
  APP_PATH="$EXPORT_PATH/$APP_NAME"
else
  APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME"
fi

if [[ ! -d "$APP_PATH" ]]; then
  err "não encontrei o app em $APP_PATH"
  exit 1
fi

log "verificando assinatura: codesign --verify --deep --strict"
codesign --verify --deep --strict "$APP_PATH"

# ---------------------------------------------------------------------------
# 5. Notarização + staple
# ---------------------------------------------------------------------------

# Envia ARQUIVO ao notarytool e espera; falha a release se não for aceito.
notarizar() {
  local arquivo="$1" nome="$2"
  local registro="$WORK_DIR/notarytool-$nome.log"
  log "enviando $nome para o notarytool (--wait)"
  if ! xcrun notarytool submit "$arquivo" "${NOTARY_ARGS[@]}" --wait > "$registro" 2>&1; then
    err "notarytool submit falhou — log em $registro"
    cat "$registro" >&2
    exit 1
  fi
  cat "$registro"
  if ! grep -q "status: Accepted" "$registro"; then
    local submissao
    submissao="$(awk -F': ' '/^[ ]*id:/{print $2; exit}' "$registro")"
    err "notarização de $nome não foi aceita"
    if [[ -n "$submissao" ]]; then
      xcrun notarytool log "$submissao" "${NOTARY_ARGS[@]}" || true
    fi
    exit 1
  fi
}

if [[ $HAVE_DEVID -eq 1 && $HAVE_NOTARY -eq 1 ]]; then
  NOTARIZE_ZIP="$WORK_DIR/OkamiUNI-notarize.zip"
  log "empacotando para notarização"
  ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"
  notarizar "$NOTARIZE_ZIP" app

  log "stapler staple"
  xcrun stapler staple "$APP_PATH"

  log "spctl -a -vv"
  spctl -a -vv "$APP_PATH"
else
  log "AVISO: pulando notarização/staple (Developer ID e/ou perfil de notarização ausentes)"
fi

FINAL_ZIP="$WORK_DIR/OkamiUNI-$VERSION.zip"
log "empacotando zip final → $FINAL_ZIP"
ditto -c -k --keepParent "$APP_PATH" "$FINAL_ZIP"

# ---------------------------------------------------------------------------
# 5b. Instalador (.dmg) para quem baixa pela primeira vez
# ---------------------------------------------------------------------------
# O zip acima é o que o Sparkle baixa; o .dmg é o que uma pessoa baixa. Nome
# sem versão de propósito: é ele que o link fixo
# releases/latest/download/OkamiUNI.dmg alcança.

FINAL_DMG="$WORK_DIR/OkamiUNI.dmg"
log "desenhando o fundo do instalador"
swift Tools/dmg/fundo.swift "$WORK_DIR/dmg" >/dev/null
log "montando o instalador → $FINAL_DMG"
"$DMG_VENV/bin/dmgbuild" -s Tools/dmg/settings.py \
  -D app="$APP_PATH" -D fundo="$WORK_DIR/dmg/fundo.png" \
  "OkamiUNI" "$FINAL_DMG" 2>&1 | grep -v "is deprecated" || true
[[ -f "$FINAL_DMG" ]] || { err "dmgbuild não gerou $FINAL_DMG"; exit 1; }

if [[ $HAVE_DEVID -eq 1 ]]; then
  log "assinando o instalador com Developer ID"
  codesign --sign "Developer ID Application" --timestamp "$FINAL_DMG"
fi
if [[ $HAVE_DEVID -eq 1 && $HAVE_NOTARY -eq 1 ]]; then
  notarizar "$FINAL_DMG" dmg
  log "stapler staple (dmg)"
  xcrun stapler staple "$FINAL_DMG"
  log "spctl (dmg)"
  spctl -a -t open --context context:primary-signature -vv "$FINAL_DMG"
fi

# ---------------------------------------------------------------------------
# 6. Assinatura Sparkle (sign_update)
# ---------------------------------------------------------------------------

if [[ -n "$SIGNATURE_OVERRIDE" ]]; then
  SIGNATURE="$SIGNATURE_OVERRIDE"
  log "usando a assinatura passada em --assinatura (não rodei o sign_update)"
elif [[ $HAVE_SPARKLE -eq 1 ]]; then
  log "assinando com sign_update: $SPARKLE_BIN"
  SIGN_OUTPUT="$("$SPARKLE_BIN" "$FINAL_ZIP")"
  echo "$SIGN_OUTPUT"
  SIGNATURE="$(echo "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
  if [[ -z "$SIGNATURE" ]]; then
    err "não consegui extrair sparkle:edSignature da saída do sign_update"
    exit 1
  fi
else
  SIGNATURE="DRYRUN-SEM-SIGN_UPDATE-NAO-E-UMA-ASSINATURA-REAL"
  log "AVISO: usando assinatura provisória (NÃO é uma assinatura EdDSA real): $SIGNATURE"
fi

# ---------------------------------------------------------------------------
# 7. appcast.xml
# ---------------------------------------------------------------------------

RELEASE_PAGE_URL="https://github.com/$REPO/releases/tag/v$VERSION"

if [[ $DRY_RUN -eq 1 ]]; then
  APPCAST_OUT="$WORK_DIR/appcast.xml"
  APPCAST_ARGS=(--output "$APPCAST_OUT")
  if [[ -f "appcast.xml" ]]; then
    APPCAST_ARGS+=(--appcast "appcast.xml")
  fi

  log "gerando appcast.xml de teste em $APPCAST_OUT"
  python3 -I Tools/appcast.py \
    --version "$VERSION" --build "$BUILD_NUMBER" \
    --zip "$FINAL_ZIP" --signature "$SIGNATURE" \
    --release-page-url "$RELEASE_PAGE_URL" \
    "${APPCAST_ARGS[@]}"

  if [[ $INSTALL -eq 1 ]]; then
    instalar_localmente "$APP_PATH"
  fi

  log "dry-run concluído, nada foi publicado."
  log "  app:      $APP_PATH"
  log "  zip:      $FINAL_ZIP"
  log "  dmg:      $FINAL_DMG"
  log "  appcast:  $APPCAST_OUT"
  exit 0
fi

# ---------------------------------------------------------------------------
# 8. Publicação (main + tag, release no GitHub, appcast em gh-pages)
# ---------------------------------------------------------------------------
# Ordem importa: o zip tem que estar no release do GitHub ANTES de o
# appcast.xml ser publicado em gh-pages — senão um cliente Sparkle pode ver
# o item novo no appcast e tentar baixar um zip que ainda não existe.

log "commitando o bump de versão em main"
git add project.yml
git commit -m "release: v$VERSION"
git tag "v$VERSION"

log "git push origin main e a tag v$VERSION"
git push origin main
git push origin "v$VERSION"

log "gh release create v$VERSION (sobe $FINAL_DMG e $FINAL_ZIP)"
gh release create "v$VERSION" "$FINAL_DMG" "$FINAL_ZIP" \
  --repo "$REPO" \
  --title "v$VERSION" \
  --notes-file "$NOTES_EN" \
  --verify-tag

GHPAGES_WORKTREE="$WORK_DIR/gh-pages"
log "preparando worktree de gh-pages em $GHPAGES_WORKTREE"
git worktree add --detach "$GHPAGES_WORKTREE" HEAD >/dev/null
(
  cd "$GHPAGES_WORKTREE"
  if git ls-remote --exit-code --heads origin gh-pages >/dev/null 2>&1; then
    git fetch origin gh-pages >/dev/null
    git checkout -B gh-pages origin/gh-pages
  else
    git checkout --orphan gh-pages
    git rm -rf . >/dev/null 2>&1 || true
  fi
)

log "gerando appcast.xml em gh-pages"
APPCAST_ARGS=(--output "$GHPAGES_WORKTREE/appcast.xml")
if [[ -f "$GHPAGES_WORKTREE/appcast.xml" ]]; then
  APPCAST_ARGS+=(--appcast "$GHPAGES_WORKTREE/appcast.xml")
fi
python3 -I Tools/appcast.py \
  --version "$VERSION" --build "$BUILD_NUMBER" \
  --zip "$FINAL_ZIP" --signature "$SIGNATURE" \
  --release-page-url "$RELEASE_PAGE_URL" \
  "${APPCAST_ARGS[@]}"

cat > "$GHPAGES_WORKTREE/index.html" <<HTML
<!doctype html>
<meta charset="utf-8">
<title>OkamiUNI</title>
<meta http-equiv="refresh" content="0; url=https://github.com/$REPO/releases">
<p>Redirecionando para as <a href="https://github.com/$REPO/releases">releases do OkamiUNI no GitHub</a>…</p>
HTML

log "commitando e publicando gh-pages"
(
  cd "$GHPAGES_WORKTREE"
  git add appcast.xml index.html
  git commit -m "appcast: v$VERSION"
  git push origin gh-pages
)

git worktree remove "$GHPAGES_WORKTREE" --force

if [[ $INSTALL -eq 1 ]]; then
  instalar_localmente "$APP_PATH"
fi

log "release v$VERSION publicada."
log "  zip:      $FINAL_ZIP"
log "  dmg:      https://github.com/$REPO/releases/latest/download/OkamiUNI.dmg"
log "  release:  https://github.com/$REPO/releases/tag/v$VERSION"
log "  appcast:  https://okamiops.github.io/okamiuni/appcast.xml"
