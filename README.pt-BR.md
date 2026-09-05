<div align="center">

# 🐺 OkamiUNI

**Email e agenda, juntos, nativos no macOS.**

**Português (Brasil)** · [English](README.md)

![Swift](https://img.shields.io/badge/Swift-6.3-F05138?logo=swift&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-26-000000?logo=apple&logoColor=white)
![SwiftUI](https://img.shields.io/badge/SwiftUI-nativo-0071e3)
![Idiomas](https://img.shields.io/badge/idiomas-PT%20%7C%20EN%20%7C%20DE%20%7C%20FR-blue)
![Release](https://img.shields.io/badge/release-0.5.4-success)

<img src="docs/capturas/janela-principal.png" width="860" alt="OkamiUNI em português: barra lateral de contas, lista de mensagens, leitor e agenda do dia." />

</div>

O OkamiUNI reúne caixa unificada, agenda e painel de planejamento diário em um aplicativo nativo SwiftUI/AppKit. Contas e emails ficam armazenados localmente, ações enfileiradas sobrevivem à falta de conexão e os recursos de IA usam o provedor escolhido. A interface segue o [design original e seus tokens](design/README.md), com 26 temas.

**Versão atual: [v0.5.4 — Quatro idiomas e documentação bilíngue](https://github.com/OkamiOps/okamiuni/releases/tag/v0.5.4).** Veja o [changelog](CHANGELOG.pt-BR.md) e o [índice da documentação](docs/README.pt-BR.md). Esta release oferece o código-fonte; não inclui instalador para download.

## O que o aplicativo faz

| Área | Comportamento atual |
|---|---|
| Painel do dia | Plano de hoje em linha do tempo com rolagem, pessoas esperando resposta, compromissos, dinheiro e prazos, filtro por conta e barra de atividade fixa no rodapé. |
| Email | Caixa unificada, pastas do provedor, busca, conversas em pilha, arraste com Desfazer, atalhos e menus de contexto próprios. |
| Leitor | HTML sanitizado, texto legível, histórico citado e assinaturas recolhíveis, anexos sob demanda e confirmação com destino real antes de abrir links. Imagens remotas ficam bloqueadas até autorização. |
| Envio | Gmail API ou SMTP com TLS, aliases do Gmail/Workspace, texto rico, anexos, rascunhos e fila offline com estados de erro e nova tentativa. |
| Contas | OAuth do Google e IMAP/SMTP para provedores compatíveis com a autenticação por senha implementada. Credenciais no Keychain; dados locais em SQLite/GRDB. Não há limite fixo de contas. |
| Sincronização | IMAP IDLE, histórico incremental do Gmail e recuperação de rede; reconectar preserva a identidade local e os dados da conta. |
| Agenda | Leitura e gravação nos calendários do macOS via EventKit, incluindo os configurados no sistema; convites e RSVP pela fila de envio. |
| IA | Resumos, triagem, respostas sugeridas, ferramentas de escrita e assistente em gaveta (`⌘J`) ou janela. Suporta Foundation Models neste Mac e provedores remotos/CLI configurados. |
| Aparência | 26 temas, fontes embarcadas, painéis redimensionáveis e controles nativos de janela. |

Conectar um provedor de IA remoto ou CLI de propósito habilita análise automática e respostas prontas por esse provedor. O interruptor nas configurações de IA restringe o trabalho automático a este Mac. A interface identifica o destino; a escrita gerada aparece como prévia para aceitação. O idioma da interface e o das respostas da IA são preferências separadas.

## Idiomas

A interface oferece **Português (Brasil), English, Deutsch e Français**. O português continua sendo o padrão. Em **Configurações → Geral → Idioma do aplicativo**, escolha um idioma ou siga o sistema. Feche e reabra o app para aplicar a escolha em todas as janelas. Se nenhum idioma preferido do sistema for suportado, o app usa português.

Datas e números acompanham o idioma da interface. Mensagens, nomes de pastas do provedor e outros conteúdos da conta permanecem no idioma original. As preferências de resposta da IA também incluem francês. A ajuda de contas é embarcada para uso offline em português e inglês; interfaces em inglês, alemão e francês usam os guias em inglês.

Toda a documentação Markdown mantida tem versões em português e inglês. O [índice da documentação](docs/README.pt-BR.md) reúne os pares. Planos históricos mantêm suas datas e exemplos de código originais; capturas e protótipos podem conter conteúdo de exemplo em português.

## Compilar e executar

Requisitos: **macOS 26**, **Xcode 26.6 / Swift 6.3** (ferramentas validadas) e [XcodeGen](https://github.com/yonaskolb/XcodeGen). A IA local também depende da disponibilidade de Foundation Models no Mac.

```bash
git clone https://github.com/OkamiOps/okamiuni.git
cd okamiuni
# Crie a configuração local somente se ela ainda não existir.
test -e Config/Google.xcconfig || cp Config/Google.example.xcconfig Config/Google.xcconfig
xcodegen generate
xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI \
  -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/OkamiUNI.app
```

O projeto especifica o time de assinatura do mantenedor. Para seu próprio build, selecione seu time e certificado Apple Development no Xcode ou informe seu `DEVELOPMENT_TEAM` ao `xcodebuild`. Uma assinatura estável importa para o acesso ao Keychain entre builds. O `.xcodeproj` gerado não é versionado; mudanças permanentes no projeto pertencem a [`project.yml`](project.yml).

Para contas Google, configure o client ID de aplicativo desktop e, quando fornecido pelo Google, seu client secret no arquivo ignorado `Config/Google.xcconfig`. Siga o [guia de OAuth do Google](docs/oauth-google.md). Configuração vazia é válida: a conexão Google explica o que falta e o formulário IMAP continua disponível. Leia sobre [senhas de app e compatibilidade de provedores](docs/senha-de-app.md) antes de conectar uma conta IMAP.

Para mantenedores, `Tools/rodar.sh` recompila e abre o app. Ele também encerra a instância anterior e limpa o estado salvo das janelas; use-o deliberadamente.

## Arquitetura

Quatro pacotes Swift separam a lógica de domínio das views:

| Pacote | Responsabilidade |
|---|---|
| [`UNICore`](Packages/UNICore) | Modelos, lógica pura, comportamento de email/conversas/agenda e localização. |
| [`UNIDesign`](Packages/UNIDesign) | Tokens de tema, tipografia e fontes embarcadas. |
| [`UNIShell`](Packages/UNIShell) | Telas, janelas, controles e integração SwiftUI/AppKit. |
| [`UNISync`](Packages/UNISync) | Contas, OAuth/API do Google, IMAP/SMTP, Keychain, banco e fila de envio. |

```text
App → UNIShell → UNIDesign
              → UNICore ← UNISync → Keychain · GRDB · Gmail API · IMAP · SMTP
```

A checagem estrita de concorrência do Swift está habilitada. Datas civis e minutos do dia são modelados explicitamente; instantes são convertidos nas bordas. O [registro de decisões de engenharia](docs/decisoes-de-engenharia.md) documenta os motivos e as evidências históricas de validação.

## Validação e contribuição

Os testes usam Swift Testing. Testes de rede usam servidores locais ou transportes simulados; testes de renderização hospedam views reais de SwiftUI/AppKit fora da tela, sem dirigir teclado ou mouse do usuário.

```bash
python3 Tools/audit_localizations.py
swift test --package-path Packages/UNICore
swift test --package-path Packages/UNIDesign
swift test --package-path Packages/UNISync
swift test --package-path Packages/UNIShell
```

Para verificação focada de localização e capturas:

```bash
swift test --package-path Packages/UNICore --filter 'L10nTests|BundledTranslationTests'
UNI_RENDER_DIR=/tmp/okamiuni-localization \
  swift test --package-path Packages/UNIShell --filter LocalizationRenderTests
swift test --package-path Packages/UNIShell --filter AccountsDocsTests
```

As traduções ficam em `Packages/UNICore/Sources/UNICore/Resources/*/Localizable.strings`. Novos textos de interface usam `L10n.tr("Texto \(valor)")`; a interpolação no catálogo usa `{0}`, `{1}` e assim por diante. Mantenha os quatro catálogos alinhados. Não traduza identificadores persistidos, valores de protocolo, conteúdo das contas ou identificadores internos de prompts. Atualize os dois idiomas da documentação quando o comportamento mudar e preserve exemplos históricos de código nos planos.

A auditoria de localização verifica cobertura, paridade de catálogos e marcadores de interpolação. A validação específica da release está nas [notas da v0.5.4](docs/releases/v0.5.4.pt-BR.md); totais históricos de testes não representam uma nova execução da suíte completa.

## Roteiro e limitações

O shell nativo, a persistência de contas, a sincronização contínua, o envio, a integração de agenda via EventKit, o assistente de IA e o painel do dia estão implementados. A versão 0.5.4 adiciona quatro idiomas de interface e documentação bilíngue.

O próximo trabalho inclui valores a receber e acompanhamento derivados das mensagens enviadas. Lacunas existentes incluem fluxos de recorrência de eventos, configuração CalDAV direta no app, árvore de pastas do provedor totalmente indentada e encaminhamento de convite com seu `.ics`. Calendários CalDAV já configurados no macOS continuam disponíveis via EventKit. OAuth da Microsoft ainda não está implementado; uma senha de app não torna um provedor que exige OAuth compatível com a rota IMAP atual.

Todo controle visível deve executar sua ação ou explicar por que está indisponível. Mudanças de interação devem ser verificadas pelo caminho real da view/evento; mudanças visuais devem ser conferidas contra [`design/tokens.json`](design/tokens.json) e a [referência atual do painel do dia](design/11-painel-do-dia.dc.html).
