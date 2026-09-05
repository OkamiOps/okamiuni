# Marco 3 — Sincronização viva: incremental, fila de saída, envio e o espelho da triagem

> **Registro histórico de design e implementação.** Este documento preserva as decisões da data indicada e não comprova o comportamento atual. [Read the English companion](2026-08-28-marco-3-sincronizacao-design.en.md).

Aprovado em 2026-08-28, junto com a spec do Marco 2
(`2026-08-28-marco-2-contas-design.md`), que é pré-requisito integral: este
marco assume o banco GRDB como fonte da verdade, `UNISync` com
`AccountDirector`, `GmailClient`, `ImapSession` e a carga inicial prontos.

Decisões do dono do projeto que governam: **o ciclo fecha inteiro neste
marco** — ler, triar E enviar; **a triagem espelha no servidor** (Hoje/Depois
te seguem em qualquer cliente); OAuth só Google, resto IMAP.

## Objetivo

O que acontece no servidor aparece no app em segundos; o que você faz no app
acontece no servidor mesmo que a rede caia no meio; e o composer despacha de
verdade. Ao fim, o OkamiUNI é usável como cliente único de email.

## Restrições herdadas

As mesmas da spec do Marco 2, verbatim — em especial: banco é a verdade, UI
nunca espera rede, erro nunca engolido, nenhuma dependência nova além de
GRDB + swift-nio-imap, teste provado por mutação, interação provada por
ensaio no app real, e **nada limita provedor/domínio/número de contas**.

## Os três motores novos

### 1 · Sincronização incremental (servidor → banco)

Um **ator por conta** (`AccountSyncWorker`), dono do calendário de sync dela:

- **Gmail**: `history.list` a partir do `historyId` guardado — mensagens
  novas, apagadas, mudanças de label/flags viram escritas no banco.
  Disparo: ao ativar a janela, após qualquer operação nossa, e polling de
  60s com a janela ativa / 5min sem foco. `historyId` expirado (404) →
  ressincronização da carga inicial, sem apagar o que o usuário fez local.
- **IMAP**: **IDLE** na inbox (chegada em segundos); demais pastas por
  varredura nas mesmas janelas de disparo. `UIDVALIDITY` trocada → a pasta
  ressincroniza do zero. `CONDSTORE`/`HIGHESTMODSEQ` quando o servidor
  oferece; senão, comparação de flags por lote de UIDs.
- Reconexão com recuo exponencial + jitter; rede voltando (NWPathMonitor)
  acorda todos os workers.
- **Conflito**: servidor ganha em estado de mensagem (flags, pasta), exceto
  quando há operação nossa ainda na fila para aquela mensagem — a fila
  reaplica e o estado local prevalece até ela esvaziar (last-writer-wins com
  a nossa escrita pendente por último).

### 2 · Fila de saída (banco → servidor)

Tabela `outbox` (criada na v2 do banco): operação tipada, conta, alvo,
payload, tentativas, próximo instante de tentativa, estado
(`pendente`, `executando`, `falhou`, `feita`).

- Operações: `setRead`, `setFlagged`, `move(bucket)`, `delete`,
  `deletePermanently`, `emptyTrash`, `send`, `appendSent`,
  `createDepoisFolder`, `addToAgenda`/`removeFromAgenda` ficam locais (não
  têm servidor até o Marco 4).
- Toda ação da UI: escreve a projeção no banco **na mesma transação** em que
  enfileira a operação — otimista, atômico, e o Desfazer do Marco 1
  enfileira a operação inversa.
- Executor por conta consome em ordem, **coalescendo** (ler+não-ler+ler da
  mesma mensagem vira uma operação; N `setRead` da mesma pasta viram um
  `STORE` em lote no IMAP / um `batchModify` no Gmail).
- Idempotência: cada operação carrega uma chave; reexecutar depois de um
  timeout ambíguo não duplica efeito (Gmail: `batchModify` é naturalmente
  idempotente; envio: ver abaixo).
- Falha permanente (4xx que retry não cura) para a fila daquela conta,
  marca a conta com o erro e a UI mostra o quê e por quê, com "tentar de
  novo" e "descartar operação" — nunca descarte silencioso.

### 3 · Envio

- Composer/faixa "Enviar" → `outbox.send` com a mensagem montada (MIME para
  IMAP/SMTP; RFC 822 raw para o Gmail API `messages.send`).
- **Idempotência do envio** (o único caso onde duplicar é imperdoável):
  cada envio ganha um `Message-ID` gerado por nós ANTES da primeira
  tentativa; retry após timeout primeiro procura esse `Message-ID` em
  Enviadas — achou, considera enviado.
- **SMTP**: cliente de submissão próprio sobre SwiftNIO (o protocolo de
  submissão é pequeno: EHLO, STARTTLS/TLS implícito, AUTH PLAIN/LOGIN,
  MAIL/RCPT/DATA), com os presets de host/porta por provedor ao lado dos de
  IMAP. Depois do 250, `APPEND` da cópia em Enviadas (exceto provedores que
  gravam sozinhos — preset diz).
- **Gmail**: `messages.send`; o Gmail grava em Enviadas sozinho.
- Estado visível: "Enviando…" na mensagem, falha com causa e "Tentar de
  novo" — o idioma de recibo do Marco 1.
- A caixa **Enviadas** entra na lateral (papel `sent`), fora da triagem.
- Rich text do composer → MIME `multipart/alternative` (texto simples +
  HTML gerado do `NSAttributedString`); anexos do seed viram partes MIME.

## O espelho da triagem

| Bucket | Gmail | IMAP |
|---|---|---|
| Hoje | na INBOX, sem label `OkamiUNI/Depois` | na INBOX |
| Depois | label **`OkamiUNI/Depois`** (criada no primeiro uso; INBOX sai junto para não duplicar no webmail) | pasta **`OkamiUNI/Depois`** (criada no primeiro uso) |
| Arquivado | remove INBOX (All Mail) | pasta Archive (papel `archive`) |
| Lixeira | label TRASH | pasta Trash |
| Sinalizada | STARRED | `\Flagged` |
| Lida | remove UNREAD | `\Seen` |

- A projeção inversa (servidor → bucket) é a mesma função pura do Marco 2,
  estendida — mudou lá, muda cá, **um lugar só**.
- Mover para Depois em outro cliente (arrastando para a pasta no webmail)
  aparece aqui como Depois: o espelho é bidirecional de graça, porque a
  leitura incremental já projeta.
- "Esvaziar lixeira" → Gmail `messages.delete` em lote (permanente); IMAP
  `STORE \Deleted` + `EXPUNGE` na Trash. Continua atrás da confirmação do
  Marco 1.

## Mudanças no banco (migração v2)

`outbox`; `folder` ganha `depois` como papel materializado; `message` ganha
`pendingOps` (contagem denormalizada para o conflito acima); índices para as
consultas do executor. Nada destrutivo — v1 → v2 preserva tudo.

## O que muda nos pacotes existentes

- `UNIShell`: caixa Enviadas na lateral; estados "Enviando…"/falha; selo de
  fila pendente na linha da conta (n operações aguardando rede). O resto do
  shell **não muda** — as ações do Marco 1 já chamam `MailStore`, que agora
  enfileira.
- `UNICore`: `MailStore` delega mutações à porta de escrita de `UNISync`
  (protocolo `MailCommandPort`); em modo fixtures, a porta é em memória e o
  comportamento atual fica intacto (todos os testes do Marco 1 continuam
  valendo sem mudança).

## Erros e observabilidade

`SyncError` do Marco 2 cobre; soma-se o estado da fila por conta. Painel na
janela de Contas: última sincronização, operações pendentes, última falha
com causa. Logs estruturados por conta/componente.

## Testes

- Executor da fila: ordem, coalescência, retry com recuo, idempotência
  (timeout ambíguo → sem efeito duplo), falha permanente parando a fila —
  tudo contra portas falsas, sem rede.
- Conflito: matriz local-pendente × mudança-do-servidor, fronteira a
  fronteira.
- SMTP: contra servidor falso NIO (scripts EHLO/AUTH/DATA, incluindo queda
  no meio do DATA e resposta ambígua pós-DATA).
- Gmail incremental: `history.list` gravado, incluindo o 404 de história
  expirada.
- IMAP: IDLE acordando, UIDVALIDITY trocando no meio, CONDSTORE presente e
  ausente.
- MIME: geração e leitura ida-e-volta (texto+HTML+anexo), com acento e
  quoted-printable.
- Espelho: bucket → operações → estado do servidor falso → releitura →
  mesmo bucket (o ciclo fecha).
- Ensaio no app real: enviar do composer com SMTP falso local e ver o estado
  andar; arquivar offline e ver a fila esvaziar quando o "servidor" volta.

## Fora de escopo (registrado)

Microsoft Graph; push real do Gmail (Pub/Sub — polling + IDLE bastam por
ora); threads/conversas; undo-send com atraso; agenda no servidor (Marco 4,
EventKit); regras/filtros; múltiplas identidades por conta.

## Critério de aceite do marco

Com as mesmas duas contas do Marco 2: um email novo chega sozinho em
segundos; arquivar/apagar/sinalizar/Depois refletem no webmail (e Depois
feito no webmail reflete aqui); enviar do composer chega ao destinatário com
cópia em Enviadas; derrubar a rede no meio de tudo isso não perde nenhuma
ação — a fila esvazia quando a rede volta, com o estado visível o tempo todo.
