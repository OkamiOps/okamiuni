# Senhas de app e compatibilidade IMAP

**Português (Brasil)** · [English](senha-de-app.en.md)

Uma senha de app é uma credencial separada, gerada pelo provedor de email para um aplicativo. Em geral, pode ser revogada sem trocar a senha principal da conta. A disponibilidade e os protocolos que a aceitam dependem do provedor e da política do administrador da conta.

## Qual método de entrada usar

Para contas Google, use a entrada Google do OkamiUNI. O [guia de OAuth](oauth-google.md) serve para configurar um build de desenvolvimento se faltar o client ID.

Na rota IMAP, confirme que o provedor permite autenticação por senha em IMAP/SMTP. Com autenticação de dois fatores, alguns provedores exigem senha de app; outros exigem OAuth e não aceitam senhas de app nesses protocolos. Portanto, um erro de senha pode significar método de autenticação incompatível, além de senha digitada incorretamente.

| Provedor | Orientação |
|---|---|
| iCloud | Gere uma senha específica de app em Conta Apple → Início de Sessão e Segurança. A autenticação de dois fatores é obrigatória. [Instruções da Apple](https://support.apple.com/en-us/102654). |
| Google por IMAP | Prefira a entrada Google. Se usar IMAP, confira se sua conta oferece senhas de app; a disponibilidade depende da conta e da política de segurança. [Instruções do Google](https://support.google.com/accounts/answer/185833). |
| Yahoo / Zoho / outros provedores | Siga as instruções atuais do provedor para senhas de app e IMAP/SMTP. A disponibilidade não é garantida para toda conta. |
| Outlook.com / Hotmail / Microsoft 365 | Não presuma que uma senha de app funcionará. O Outlook.com exige autenticação moderna, e o Exchange Online desabilitou autenticação Basic para IMAP. O OkamiUNI 0.5.4 não implementa OAuth da Microsoft; essas contas não são suportadas pela rota IMAP por senha. [Orientação do Outlook.com](https://support.microsoft.com/en-us/office/modern-authentication-methods-now-needed-to-continue-syncing-outlook-email-in-non-microsoft-email-apps-c5d65390-9676-4763-b41f-d7986499a90d), [orientação do Exchange Online](https://learn.microsoft.com/en-us/lifecycle/announcements/basic-auth-deprecation-exchange-online). |

## Onde o OkamiUNI guarda a senha

Senhas das contas ficam no **Keychain**, não no banco de emails nem em arquivo de configuração. Remover uma conta apaga sua credencial local. Para invalidar uma senha de app no provedor, revogue-a também nas configurações de segurança da conta desse provedor.

Cole a senha gerada no formulário da conta IMAP. Se a autenticação continuar falhando, confira servidor, porta, TLS e política do provedor antes de gerar mais senhas. Este guia é embarcado e pode ser lido offline; os links dos provedores exigem internet.
