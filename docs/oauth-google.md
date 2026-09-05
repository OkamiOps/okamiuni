# Configurar o OAuth do Google para o OkamiUNI

**Português (Brasil)** · [English](oauth-google.en.md)

Este guia é para quem compila ou distribui o app. Usuários de um build já configurado entram pela janela de Contas; não precisam criar um projeto no Cloud.

O OkamiUNI usa um cliente OAuth desktop do Google, PKCE (S256) e a `ASWebAuthenticationSession` do sistema. Sem client ID configurado, a conexão Google explica o que falta e abre este guia. O formulário IMAP continua disponível.

## 1. Criar um projeto e ativar APIs

No [console do Google Cloud](https://console.cloud.google.com/), crie ou selecione o projeto responsável pela identidade OAuth do app. Ative **Gmail API**, **Google Calendar API** e **Google Meet API** para os recursos de email e reuniões implementados no app.

## 2. Configurar consentimento e acesso

Configure nome do app, email de suporte, público e contato do desenvolvedor no Google Auth Platform. Para um app externo em teste, adicione como usuários de teste as contas Google que serão conectadas. Teste é uma configuração de desenvolvimento; revise os requisitos de publicação e verificação do Google antes da distribuição pública. Veja a [documentação de OAuth para apps nativos do Google](https://developers.google.com/identity/protocols/oauth2/native-app).

O `GoogleAuthConfig.defaultScopes` atual solicita:

| Escopo | Uso no OkamiUNI |
|---|---|
| `https://mail.google.com/` | Ler, organizar, enviar e apagar emails permanentemente. |
| `https://www.googleapis.com/auth/userinfo.email` | Identificar o endereço conectado. |
| `https://www.googleapis.com/auth/calendar.events` | Eventos de calendário usados na criação de reuniões. |
| `https://www.googleapis.com/auth/meetings.space.created` | Criar espaços do Google Meet. |

O par anterior `gmail.modify` + `gmail.send` não cobre a operação de apagamento permanente do app. Contas autorizadas com escopos antigos podem precisar de uma reconexão ao usar recursos que exigem os novos escopos. Conceda acesso somente ao projeto que pretende usar.

## 3. Criar um cliente desktop

Crie um cliente OAuth do tipo **App para computador / Desktop app**. Copie o client ID e o `client_secret` da configuração baixada quando o Google fornecer esse campo.

A implementação Google atual deriva o esquema de callback do client ID:

```text
Client ID: 123-example.apps.googleusercontent.com
Callback:  com.googleusercontent.apps.123-example:/oauth
```

Não substitua pelo callback obsoleto `com.okamiops.okamiuni:/oauth` dos primeiros planos. O `GoogleAuthConfig` deriva o esquema e a `ASWebAuthenticationSession` o recebe. O fluxo OAuth separado do LiteLLM usa callback em loopback; ele não é o fluxo Google descrito aqui.

Clientes desktop não conseguem manter confidencial um valor embarcado. Mesmo assim, o Google pode exigir o `client_secret` fornecido na troca de tokens e na renovação, e o OkamiUNI o envia quando configurado. O PKCE continua habilitado. Essa configuração é separada dos tokens de acesso/renovação do usuário, que o app armazena no Keychain.

## 4. Configurar o build local

Na raiz do repositório, crie a configuração local somente se ela ainda não existir:

```bash
test -e Config/Google.xcconfig || cp Config/Google.example.xcconfig Config/Google.xcconfig
```

Edite os dois valores conforme necessário em `Config/Google.xcconfig`:

```text
OKAMIUNI_GOOGLE_CLIENT_ID = YOUR_DESKTOP_CLIENT_ID.apps.googleusercontent.com
OKAMIUNI_GOOGLE_CLIENT_SECRET = YOUR_DESKTOP_CLIENT_SECRET
```

`Config/Google.xcconfig` é ignorado pelo Git. Não substitua um arquivo já configurado pelo exemplo vazio. O Xcode passa esses valores ao `Info.plist` do app; eles fazem parte do build local, não de um cofre confidencial no servidor.

```bash
xcodegen generate
xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI \
  -configuration Debug -derivedDataPath build/DerivedData build
```

Use seu próprio time de assinatura de desenvolvimento se estiver fora do ambiente do mantenedor. O [README do repositório](https://github.com/OkamiOps/okamiuni/blob/v0.5.4/README.pt-BR.md) descreve os requisitos de compilação.

## 5. Conferir o resultado

Abra o app compilado, vá a Contas e inicie a conexão Google. A mensagem de client ID ausente indica um build sem essa configuração. `client_secret is missing` indica que é preciso configurar o valor fornecido para o cliente desktop. Um callback incompatível exige conferir o tipo do cliente e o ID; não acrescente redirects arbitrários ao código. Uma recusa de acesso também pode refletir restrições de público, usuário de teste ou administrador.

Para verificações offline de desenvolvimento, `swift test --package-path Packages/UNISync --filter GoogleAuthTests` exercita a lógica OAuth com transporte simulado. Isso não prova o consentimento Google ao vivo. O ensaio interno `--ensaiar-contas` também usa apresentador de autorização falso e dados locais de teste; um ensaio aprovado não demonstra que uma conta real consegue entrar.
