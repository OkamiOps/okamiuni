# Instruções para agentes

## Assinatura, notarização e release — já está tudo configurado

**Não pergunte ao dono por certificado, senha ou credencial da Apple.** Tudo
abaixo já existe no Keychain de login deste Mac e foi validado em 13/10/2026.
Use direto; se algo falhar, diagnostique primeiro (ver "Se falhar").

| O quê | Onde / nome |
|---|---|
| Certificado de distribuição fora da App Store | Keychain: `Developer ID Application: Marcos Santos (7U9S5DB9K9)` (G2, válido até 2031-09-17) |
| Time Apple | `7U9S5DB9K9` |
| Notarização | perfil do `notarytool`: `okamiuni-notary` (`xcrun notarytool submit … --keychain-profile okamiuni-notary --wait`) |
| Senha de app da Apple (origem do perfil acima) | Keychain, item genérico `okami_asc_pw`, conta `msant262@gmail.com` |
| Backup do certificado + chave privada | `~/Documents/okamiuni-devid/DeveloperID-OkamiUNI.p12` (fora do repositório) |
| Senha do `.p12` | Keychain, item genérico `okamiuni_devid_p12_pw` |
| Chave EdDSA do Sparkle (atualização OTA) | Keychain de login, gerada pelo `generate_keys` do Sparkle; a pública está em `SUPublicEDKey` no `App/Info.plist` |

Para publicar uma versão: `Tools/publicar-release.sh X.Y.Z` (ensaio:
`--dry-run`). O script assina com Developer ID, notariza, grampeia, assina o
zip para o Sparkle, cria a release no GitHub e atualiza o `appcast.xml` no
GitHub Pages.

**Nunca** commite `.p12`, `.key`, `.cer` ou senhas: este repositório é
público. Nunca imprima o valor de uma senha no terminal ou no chat.

### Se falhar

- `security find-identity -v -p codesigning` deve listar o Developer ID. Se
  sumiu, reimporte o backup:
  `security import ~/Documents/okamiuni-devid/DeveloperID-OkamiUNI.p12 -k ~/Library/Keychains/login.keychain-db -f pkcs12 -P "$(security find-generic-password -s okamiuni_devid_p12_pw -w)" -T /usr/bin/codesign`
- `xcrun notarytool history --keychain-profile okamiuni-notary` deve
  responder. Se o perfil sumiu, recrie a partir do Keychain:
  `xcrun notarytool store-credentials okamiuni-notary --apple-id msant262@gmail.com --team-id 7U9S5DB9K9 --password "$(security find-generic-password -s okami_asc_pw -a msant262@gmail.com -w)"`
- Só pergunte ao dono se a senha de app tiver sido revogada pela Apple (a
  validação do `store-credentials` falha com erro de autenticação).

## Como o dono trabalha

- Não peça para ele ler spec, plano ou qualquer `.md`. Design curto no chat,
  aprovação no chat, depois código.
- `Tools/rodar.sh` abre o app: é dele, não de agentes. Para ver interface, use
  o harness de renderização fora da tela (`UNIShellTests/RenderHarness.swift`).
