import Foundation

/// Para onde `MailStore` manda uma mutação, quando há para onde mandar.
///
/// Mora aqui, no `UNICore`, e não no `UNISync` — é o `MailStore` quem chama, e
/// o `MailStore` não pode depender de GRDB só para falar com o banco. O
/// `UNISync` conforma a este protocolo do lado de fora (`DatabaseCommandPort`),
/// como já faz com `MailSource`.
///
/// Cada método recebe a conta e os ids, nunca a `Message` inteira: quem
/// implementa (o banco) só precisa escrever colunas, não reconstruir o
/// modelo. Todos são síncronos e lançam — a escrita é uma transação SQLite
/// local, nunca rede, e `MailStore` já é síncrono em toda a superfície que
/// estas seis mutações tocam.
///
/// **Sem porta, comportamento idêntico ao de hoje.** `MailStore` guarda um
/// `MailCommandPort?` opcional; `nil` (o caso das fixtures, e de todo teste
/// que não passa uma) significa "só memória", exatamente o Marco 1. É essa a
/// "implementação em memória" do modo fixtures: não uma segunda conformação a
/// preservar em paralelo, e sim a ausência de porta — o mesmo caminho que os
/// 1088 testes anteriores já exercitam sem mudança nenhuma.
public protocol MailCommandPort: Sendable {
    func setRead(_ isRead: Bool, accountID: String, messageIDs: [String]) throws
    func setFlagged(_ isFlagged: Bool, accountID: String, messageIDs: [String]) throws
    /// Move para qualquer caixa **exceto** a Lixeira — mover para a Lixeira é
    /// `delete(accountID:messageIDs:)`, porque no espelho do servidor as duas
    /// coisas são operações diferentes (label/pasta comum vs. TRASH).
    func move(to bucket: TriageBucket, accountID: String, messageIDs: [String]) throws
    /// Move para uma pasta IMAP ou aplica um marcador Gmail.
    func place(
        in folder: MailFolder,
        mode: FolderPlacement,
        accountID: String,
        messageIDs: [String]
    ) throws
    /// Gmail “Mover para”: adiciona o destino e remove apenas o marcador de
    /// origem. É separado de `place` para a fila nunca confundir mover com
    /// aplicar cumulativamente.
    func moveGmailLabel(
        from source: MailFolder,
        to destination: MailFolder,
        accountID: String,
        messageIDs: [String]
    ) throws
    /// Preferência local: muda a cor da conta, sem operação de servidor.
    func setAccountTint(lightHex: String, darkHex: String, accountID: String) throws
    /// Move para a Lixeira — o "apagar" reversível, que ainda aparece na
    /// caixa Lixeira até `deletePermanently` ou `emptyTrash`.
    func delete(accountID: String, messageIDs: [String]) throws
    /// Apagamento definitivo de mensagens específicas — "apagar
    /// definitivamente" na Lixeira.
    func deletePermanently(accountID: String, messageIDs: [String]) throws
    /// Esvazia a Lixeira inteira de uma conta.
    func emptyTrash(accountID: String) throws
}
