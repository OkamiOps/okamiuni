# Criar o OAuth Client do Google (uma vez, pelo dono do projeto)

O OkamiUNI fala com a Gmail API em nome do usuário. Para isso o Google exige um
**OAuth Client ID de aplicativo desktop**, criado por quem é dono do projeto no
Google Cloud. Não há como o app criar isso sozinho, e não há como embutir um
client de terceiros: o consentimento cita o nome do projeto.

O app **não fica bloqueado** enquanto isto não existe. Sem client ID, a rota
Google da janela de Contas mostra "Falta o OAuth Client ID do Google — ver
docs/oauth-google.md" com o botão que abre este arquivo, e a rota IMAP funciona
normalmente. Nenhum teste depende deste roteiro.

Leva uns dez minutos.

## 1. Criar o projeto

1. Abra <https://console.cloud.google.com/>.
2. No seletor de projeto (barra do topo, à esquerda), clique em **Novo projeto**.
3. Nome: `OkamiUNI`. Organização: a sua, ou "Sem organização".
4. **Criar**. Espere a notificação e selecione o projeto novo no seletor.

## 2. Ativar a Gmail API

1. Menu ☰ ▸ **APIs e serviços** ▸ **Biblioteca**.
2. Busque `Gmail API`.
3. Abra o cartão **Gmail API** e clique em **Ativar**.

## 3. Configurar a tela de consentimento

1. Menu ☰ ▸ **APIs e serviços** ▸ **Tela de permissão OAuth**.
2. Tipo de usuário: **Externo**. **Criar**.
3. Preencha o mínimo obrigatório:
   - Nome do app: `OkamiUNI`
   - Email de suporte: o seu
   - Email do desenvolvedor: o seu
4. **Salvar e continuar**.
5. Na etapa **Escopos**, clique em **Adicionar ou remover escopos** e marque os
   três, colando cada um no filtro:
   - `https://www.googleapis.com/auth/gmail.modify`
   - `https://www.googleapis.com/auth/gmail.send`
   - `https://www.googleapis.com/auth/userinfo.email`

   Os três são pedidos **juntos**, de propósito: `gmail.send` só é usado no
   Marco 3, mas pedi-lo depois obrigaria o usuário a consentir duas vezes.
6. **Atualizar** ▸ **Salvar e continuar**.
7. Na etapa **Usuários de teste**, **Adicionar usuários** e coloque os endereços
   Gmail que você vai conectar. **Em modo de teste, só esses endereços
   conseguem autorizar o app** — se faltar um, o consentimento devolve
   `access_denied`, que o app mostra como "Autorização negada ou revogada".
8. **Salvar e continuar** ▸ **Voltar ao painel**.

Modo **Teste** serve. Publicar exige verificação do Google, que só faz sentido
quando o app for distribuído.

## 4. Criar o Client ID

1. Menu ☰ ▸ **APIs e serviços** ▸ **Credenciais**.
2. **Criar credenciais** ▸ **ID do cliente OAuth**.
3. Tipo de aplicativo: **App para computador** (*Desktop app*).
4. Nome: `OkamiUNI macOS`.
5. **Criar**. Copie o **ID do cliente** — algo como
   `123456789012-abcdefghijklmnop.apps.googleusercontent.com`.

Não existe "URI de redirecionamento" para escolher aqui: um client de desktop
aceita esquema próprio. O app usa `com.okamiops.okamiuni:/oauth`, registrado no
`Info.plist` em `CFBundleURLTypes`.

**Não há segredo do cliente a guardar.** Client de desktop é público por
definição, e é exatamente por isso que o fluxo usa PKCE (S256): a prova de
posse é o `code_verifier` gerado a cada autorização, não um segredo embutido no
binário — que qualquer pessoa extrairia do `.app`.

## 5. Entregar o client ID ao app

```bash
cp Config/Google.example.xcconfig Config/Google.xcconfig
```

Abra `Config/Google.xcconfig` e troque o valor:

```
OKAMIUNI_GOOGLE_CLIENT_ID = 123456789012-abcdefghijklmnop.apps.googleusercontent.com
```

`Config/Google.xcconfig` está no `.gitignore` — o client ID não vai para o
repositório. `Config/Google.example.xcconfig` vai, com o valor vazio, para
quem clonar saber que o arquivo existe.

Depois: `xcodegen generate`.

## Como saber que deu certo

Rode o ensaio da janela de Contas:

```bash
xcodegen generate
xcodebuild -project OkamiUNI.xcodeproj -scheme OkamiUNI -configuration Debug build
open -g --args --ensaiar-contas
```

Sem client ID, o stderr traz `contas: rota google sem client ID`. Com o client
ID configurado, traz `contas: rota google pronta`. O ensaio **não** abre o
navegador nem toca a rede: ele usa o apresentador de autorização falso.
