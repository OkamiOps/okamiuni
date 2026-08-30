import Foundation

/// De onde vem o catálogo **real** de contatos, quando há banco.
///
/// A queixa que esta porta resolve: o autocomplete de destinatário mostrava
/// "Marina Duarte", "Suporte Hostinger" — o caderno de exemplo do protótipo —
/// em vez das pessoas com quem a conta conectada de fato troca email.
///
/// Mora aqui, no `UNICore`, e não no `UNISync` — como `BodyFetching` e
/// `MailCommandPort`: quem chama é o `MailStore`, e o `MailStore` não pode
/// depender de GRDB. O `UNISync` conforma do lado de fora
/// (`DatabaseContactDirectory`).
///
/// **Assíncrona, como `BodyFetching` e ao contrário de `MailCommandPort`.** É
/// leitura do banco — disco, não rede, mas ainda assim I/O que a tela não
/// pode esperar de forma síncrona.
///
/// **Sem conta conectada, o `MailStore` continua com `Fixtures.contacts`** —
/// é a mesma regra do app inteiro (`AppComposition`): sem conta, fixtures;
/// com conta, o banco. A porta em si pode existir mesmo com o banco sem conta
/// nenhuma (é o caso do app assim que o banco abre, antes de qualquer conta
/// entrar) — por isso quem decide "há conta?" é ela, igual
/// `DatabaseMailSource.bodyMatches` já decide para o corpo, e não quem chama.
public protocol ContactDirectoryPort: Sendable {
    /// Para quem a pessoa já escreveu, lido dos destinatários e cópias da
    /// caixa Enviadas. Remetente de mensagem recebida não vira contato só por
    /// ter entrado na caixa. `accountID` nulo abrange todas as contas: o campo
    /// de destinatário do composer não filtra por conta, só a linha "De"
    /// escolhe quem envia.
    ///
    /// `nil` significa "o banco não tem conta nenhuma" — e não "procurei e
    /// não achei". A diferença é o que faz o `MailStore` saber quando voltar
    /// para `Fixtures.contacts` em vez de mostrar uma lista vazia sobre uma
    /// conta que nunca existiu.
    func contacts(accountID: String?) async throws -> [DirectoryContact]?
}
