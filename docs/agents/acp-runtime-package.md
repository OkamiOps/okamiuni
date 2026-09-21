# Empacotar um runtime ACP Node

`Tools/package-acp-runtime.py` monta uma pasta portátil para usar como
runtime ACP externo. Ele não instala pacotes, não faz download e não executa o agente.
Use uma pasta dedicada que já contenha o adaptador ACP e suas dependências.

O pacote contém somente:

- `runtime/node`: uma cópia regular do binário Node selecionado;
- `agent/node_modules`: as dependências já instaladas;
- `agent/<entry>`: o entrypoint opcional;
- `okamiuni-acp-runtime.json`: manifesto relativo da versão 1.

O comando recusa symlinks que escapam de `node_modules`. Links internos, como
`node_modules/.bin`, viram cópias regulares no pacote. Arquivos `.npmrc`,
`.env`, `.env.*` e nomes comuns de credenciais não entram no resultado. O
empacotador também nunca lê `~/.codex`, `~/.claude`, `~/.config/opencode`, a
pasta pessoal, tokens, ou arquivos de login.

## Uso

Prepare uma pasta de adaptador sem estado de conta, por exemplo:

```text
/caminho/para/adaptador-acp/
├── agent.mjs
└── node_modules/
```

Empacote apontando para o Node e para as dependências que já estão nessa pasta:

```sh
python3 Tools/package-acp-runtime.py \
  --runtime-name "Meu adaptador ACP" \
  --node /caminho/para/node \
  --source-root /caminho/para/adaptador-acp \
  --node-modules /caminho/para/adaptador-acp/node_modules \
  --entry agent.mjs \
  --agent-argument=--acp \
  --output /caminho/para/Meu-adaptador.acp-runtime
```

O entrypoint é opcional. Sem `--entry`, o manifesto inicia só o Node; os
argumentos adicionais podem ser configurados depois na conexão ACP. Quando há
entrypoint, `--node-argument` fica antes dele e `--agent-argument` fica depois:

```sh
--node-argument=--no-warnings --entry agent.mjs --agent-argument=--acp
```

O destino precisa ser uma pasta nova. O manifesto gerado usa:

```json
{
  "schemaVersion": 1,
  "displayName": "Meu adaptador ACP",
  "executable": "runtime/node",
  "arguments": ["agent/agent.mjs", "--acp"],
  "environment": {}
}
```

Depois de criar o pacote, escolha `runtime/node` como Executável ACP no app.
Informe o caminho absoluto do entrypoint em `agent/` no campo de argumentos,
seguido dos argumentos próprios do adaptador. Não há importação automática
para o container do app.

## Exemplos de provedores

Os nomes abaixo são exemplos de identificação do runtime; eles não pressupõem
um layout nem um adaptador oficial. Troque todos os caminhos pelo adaptador ACP
Node que você já instalou e verificou para o respectivo provedor.

```sh
# Codex via o seu adaptador ACP Node dedicado.
python3 Tools/package-acp-runtime.py \
  --runtime-name "Codex ACP" \
  --node "$CODEX_ACP_NODE" \
  --source-root "$CODEX_ACP_ADAPTER" \
  --node-modules "$CODEX_ACP_ADAPTER/node_modules" \
  --entry "$CODEX_ACP_ENTRY" \
  --output "$CODEX_ACP_PACKAGE"

# Claude via o seu adaptador ACP Node dedicado.
python3 Tools/package-acp-runtime.py \
  --runtime-name "Claude ACP" \
  --node "$CLAUDE_ACP_NODE" \
  --source-root "$CLAUDE_ACP_ADAPTER" \
  --node-modules "$CLAUDE_ACP_ADAPTER/node_modules" \
  --entry "$CLAUDE_ACP_ENTRY" \
  --output "$CLAUDE_ACP_PACKAGE"

# OpenCode via o seu adaptador ACP Node dedicado.
python3 Tools/package-acp-runtime.py \
  --runtime-name "OpenCode ACP" \
  --node "$OPENCODE_ACP_NODE" \
  --source-root "$OPENCODE_ACP_ADAPTER" \
  --node-modules "$OPENCODE_ACP_ADAPTER/node_modules" \
  --entry "$OPENCODE_ACP_ENTRY" \
  --output "$OPENCODE_ACP_PACKAGE"
```

O login continua fora do pacote. Faça a autenticação pelo fluxo normal do
provedor. O serviço auxiliar usa a sessão própria do runtime, fora do sandbox
do aplicativo principal. Nunca coloque token, API key,
arquivo `.env`, `.npmrc` ou diretório de login no pacote.

## Verificação offline

Os testes usam somente arquivos temporários; não chamam `npm`, não baixam nada
e não iniciam o app:

```sh
python3 Tools/test-package-acp-runtime.py
```
