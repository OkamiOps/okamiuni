import Foundation
import UNICore

/// As decisões da lista de pastas do shell **Vidro**, sem `View` nenhuma.
///
/// Protótipo: `Sidebar.dc.html`, o conjunto `sets.caixa`.
enum GlassFolderList {

    /// As caixas, na ordem do protótipo.
    ///
    /// "Tudo" fica de fora de propósito: o protótipo desenha sete linhas, e a
    /// caixa unificada não é uma delas. Ela continua existindo e continua
    /// sendo alcançada pela busca ("Tudo" do campo), que é de onde ela é
    /// realmente usada.
    static let buckets: [TriageBucket] = [
        .today, .later, .sent, .drafts, .archived, .junk, .trash,
    ]

    /// O ícone de cada caixa. Todas têm um aqui — a lista do protótipo é uma
    /// coluna de ícones, e uma linha sem ícone no meio dela fica torta.
    static func symbol(for bucket: TriageBucket) -> String {
        switch bucket {
        case .today: "sun.max"
        case .later: "clock"
        case .sent: "paperplane"
        case .drafts: "square.and.pencil"
        case .archived: "archivebox"
        case .junk: "exclamationmark.triangle"
        case .trash: "trash"
        case .all: "tray"
        }
    }

    /// O Spam escreve em vermelho quando tem alguma coisa. É a única caixa
    /// cujo número é um aviso, e não um placar.
    static func countIsWarning(_ bucket: TriageBucket) -> Bool { bucket == .junk }

    // MARK: - A árvore das pastas

    /// Uma pasta do provedor com a profundidade dela e o nome que a linha
    /// escreve.
    struct Row: Hashable {
        let folder: MailFolder
        let depth: Int
        let label: String
    }

    /// As pastas numa árvore por segmentos de caminho.
    ///
    /// "Clientes/Faturas" vira **Faturas** recuada sob **Clientes** em vez de
    /// uma linha escrita por inteiro, que na coluna de 216pt era cortada no
    /// meio. A ordem recebida é preservada: ela já é a que o servidor dá, e
    /// reordenar aqui desalinharia a barra do shell clássico, que desenha a
    /// mesma lista.
    ///
    /// **Pai ausente não vira recuo.** Uma pasta "Clientes/Faturas" cuja
    /// "Clientes" o servidor não lista fica na raiz, com o caminho inteiro
    /// escrito: recuá-la sob um pai que não está na tela seria indentação sem
    /// referência.
    static func tree(_ folders: [MailFolder]) -> [Row] {
        let caminhos = Set(folders.map(\.displayName))
        return folders.map { folder in
            let segmentos = folder.displayName.split(separator: "/", omittingEmptySubsequences: true)
            guard segmentos.count > 1 else {
                return Row(folder: folder, depth: 0, label: folder.displayName)
            }
            let pai = segmentos.dropLast().joined(separator: "/")
            guard caminhos.contains(pai) else {
                return Row(folder: folder, depth: 0, label: folder.displayName)
            }
            return Row(
                folder: folder,
                depth: segmentos.count - 1,
                label: String(segmentos[segmentos.count - 1])
            )
        }
    }

    // MARK: - O recado da IA

    /// "3 e-mails importantes caíram em Promoções e Atualizações."
    struct Misplaced: Hashable {
        let messageIDs: [String]
        let folderNames: [String]

        var count: Int { messageIDs.count }

        var sentence: String {
            let pastas = ListFormatter.localizedString(byJoining: folderNames)
            return count == 1
                ? L10n.tr("1 e-mail importante caiu em \(pastas).")
                : L10n.tr("\(count) e-mails importantes caíram em \(pastas).")
        }

        static var cta: String { L10n.tr("Trazer") }
    }

    /// Quem pede resposta e está numa pasta que **não** é a entrada.
    ///
    /// É a conta que o recado do protótipo faz, e ela sai inteira do que já
    /// está em memória: a triagem guardada (por `InboxWaitingLine`) e as
    /// pastas que a mensagem declara. `nil` quando não há nada a dizer —
    /// inclusive sem conta conectada, onde não há pasta de provedor nenhuma.
    static func misplaced(messages: [Message], folders: [MailFolder]) -> Misplaced? {
        let foraDaEntrada = Dictionary(
            uniqueKeysWithValues: folders.filter { $0.role != .inbox }.map { ($0.id, $0) }
        )
        var ids: [String] = []
        var nomes: [String] = []
        for message in messages where InboxWaitingLine.waitsForYou(message) {
            // A mensagem que também está na entrada não está perdida.
            guard !message.folderIDs.contains(where: { id in
                folders.first { $0.id == id }?.role == .inbox
            }) else { continue }
            let pastas = message.folderIDs.compactMap { foraDaEntrada[$0] }
            guard !pastas.isEmpty else { continue }
            ids.append(message.id)
            for pasta in pastas where !nomes.contains(pasta.displayName) {
                nomes.append(pasta.displayName)
            }
        }
        guard !ids.isEmpty else { return nil }
        return Misplaced(messageIDs: ids, folderNames: nomes)
    }
}
