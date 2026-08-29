# Senha de app: o que é, e por que o IMAP pede uma

Existe porque a janela de Contas tem um botão "O que é uma senha de app?" e
botão que não leva a lugar nenhum é botão mudo. É o texto que ele abre.

## O que é

Uma senha extra, gerada pelo provedor, que vale **só** para um programa que
fala IMAP/SMTP — e que pode ser revogada sozinha, sem trocar a senha da conta.

## Por que a sua senha normal não serve

Em qualquer conta com verificação em duas etapas ligada, o servidor recusa a
senha da conta no `LOGIN` do IMAP: o segundo fator não tem como ser pedido
dentro do protocolo. O erro que volta é o mesmo de senha errada — e é por isso
que a janela de Contas escreve, na frase do erro de autenticação, que em
provedores com verificação em duas etapas a senha certa é a de app.

## Onde gerar

| Provedor | Onde |
|---|---|
| iCloud | appleid.apple.com ▸ Iniciar sessão e segurança ▸ Senhas específicas de apps |
| Google (por IMAP) | myaccount.google.com ▸ Segurança ▸ Senhas de app |
| Yahoo | Segurança da conta ▸ Gerar senha de app |
| Zoho | Segurança ▸ Senhas específicas de aplicativos |
| Outlook / Hotmail | Segurança avançada ▸ Senhas de aplicativo |

Provedores fora da lista chamam a mesma coisa por nomes parecidos — "senha de
aplicativo", "app password", "senha específica".

## O que o OkamiUNI faz com ela

Ela vai para o **Keychain**, na entrada da conta, e nunca para o banco nem para
arquivo de configuração. Remover a conta apaga a entrada junto — é o que a
confirmação de "Remover" avisa antes de fazer.

Para conta do Google, o caminho recomendado não é este: é o OAuth, em
[`oauth-google.md`](oauth-google.md).
