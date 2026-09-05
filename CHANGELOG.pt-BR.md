# Changelog

**Português (Brasil)** · [English](CHANGELOG.md)

Todas as versões seguem o [release no GitHub](https://github.com/OkamiOps/okamiuni/releases). Datas em 2026.

## 0.5.4 — 5 de setembro
- Interface em português, inglês, alemão e francês, com seleção persistida nas configurações e opção de seguir o sistema.
- Datas e números acompanham o idioma da interface. As preferências de resposta da IA também oferecem francês.
- Catálogos compartilhados com verificação de cobertura e interpolação; mensagens e valores internos permanecem preservados.
- Ajuda de contas offline em português e inglês; inglês nas interfaces em inglês, alemão e francês.
- README, changelog, guias, referência de design, decisões de engenharia, planos e specs com versões completas em inglês e português e índice de navegação.
- Guias de OAuth e senhas de app corrigidos para a implementação e compatibilidade atuais.
- Correções de leitura de emails IMAP com quoted-printable duplo ou residual, publicadas desde a v0.5.3.
- Versão do aplicativo 0.5.4, build 9. [Notas da release](docs/releases/v0.5.4.pt-BR.md).

## 0.5.3 — 3 de setembro
- Conectar um provedor remoto de propósito é o consentimento: análise automática e respostas prontas seguem o provedor por padrão; o interruptor em Ajustes → IA restringe a este Mac. Migração liga quem nunca tocou no interruptor, cobrindo os últimos 7 dias.

## 0.5.2 — 3 de setembro
- Plano de hoje com densidade fixa de 138 pt/h e o dia inteiro em rolagem horizontal aberta no agora; todo bloco escreve o nome; sobreposição desce uma sub-linha. Evento espelhado por duas contas coalescido na fonte.

## 0.5.1 — 3 de setembro
- A área dos painéis rola; a barra de estado fica sempre no pé. Azulejos com duas linhas. Filtro pelo nome da conta. Etiqueta do azulejo determinística antes do modelo. O cabeçalho diz por que não há prontas; "Gerar · Codex" como ação explícita.

## 0.5.0 — 3 de setembro
- O painel do dia (design 11): plano de hoje em duas trilhas, Esperando você em azulejos, Compromissos, Dinheiro e prazos, negócios como filtro, barra de estado. Remetente de máquina nunca entra em Esperando você.

## 0.4.0 — 3 de setembro
- A IA trabalhando (design 08): resposta pronta antes de abrir, uma proposta por linha com o porquê, "Arquivar e aprender" com regra por remetente, agente com ações (spec §4) com validador e parser, gaveta do assistente (⌘J) e janela destacável; o Desfazer de um cartão desfaz exatamente a leva do cartão.

## 0.3.0 — 3 de setembro
- Dashboard em tríptico; corpo do email legível (citação, assinatura e rodapé colapsam; listas e chave-valor estruturados; HTML lido como estrutura); confirmação antes de abrir link com o host real destacado; menu do link com tema; barra fina de trabalho unificada; reconectar conta sem removê-la; barreira de disparo em massa por cabeçalho; RFC 2047 sem mojibake; timeout de IA 120 s.

## 0.2.0 — 1 de setembro
- Dashboard, aliases de envio do Gmail/Workspace, Spam na triagem, busca Tudo, leitor HTML com paleta do tema, RSVP nos botões do convite Google.
