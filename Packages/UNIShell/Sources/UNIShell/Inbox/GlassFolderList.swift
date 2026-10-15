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
        .today, .later, .all, .sent, .drafts, .archived, .junk, .trash,
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

    /// "3 e-mails importantes caíram em Spam e Promoções"
    struct Misplaced: Hashable {
        let messageIDs: [String]
        /// Já legíveis e já desduplicados — nunca `INBOX.Junk`.
        let folderNames: [String]

        var count: Int { messageIDs.count }

        /// No máximo **duas** pastas escritas, e o resto contado.
        ///
        /// A frase do dono listava nove pastas e dobrava em três linhas dentro
        /// de uma coluna de 216pt. Uma frase de barra lateral é uma linha: o
        /// nome das duas primeiras e "e mais N" é o que cabe e é o que basta
        /// para decidir se vale clicar.
        var sentence: String {
            let pastas = Self.enumerar(folderNames)
            return count == 1
                ? L10n.tr("1 e-mail importante caiu em \(pastas)")
                : L10n.tr("\(count) e-mails importantes caíram em \(pastas)")
        }

        /// A junção é do `L10n`, e não do `ListFormatter`: o conector tem de
        /// seguir o **idioma do app** (a preferência `appLanguage`), e o
        /// formatador do sistema segue o do macOS — numa máquina em inglês a
        /// frase em português saía com "and" no meio.
        static func enumerar(_ nomes: [String]) -> String {
            switch nomes.count {
            case 0: return ""
            case 1: return nomes[0]
            case 2: return L10n.tr("\(nomes[0]) e \(nomes[1])")
            default:
                let dois = L10n.tr("\(nomes[0]) e \(nomes[1])")
                return L10n.tr("\(dois) e mais \(nomes.count - 2)")
            }
        }

        static var cta: String { L10n.tr("Trazer") }
    }

    /// A janela do "novo": sete dias. Mais velho que isso é arquivo, e arquivo
    /// não é recado de barra lateral.
    static let janelaDoNovo: TimeInterval = 7 * 24 * 60 * 60

    /// Esta pasta é **destino automático do provedor**?
    ///
    /// Só duas coisas são: o Spam (papel declarado pelo servidor, via
    /// `\Junk`/`SPAM`) e as abas de categoria do Gmail, que chegam como
    /// rótulos `CATEGORY_*` ou debaixo de `[Gmail]`. Todo o resto — lixeira,
    /// enviados, rascunhos, arquivo, "todos os e-mails" e qualquer pasta que a
    /// pessoa criou — é **arrumação dela**, e o app não a corrige.
    ///
    /// Foi esta a confusão de 15/10/2026: o recado contava 252 mensagens
    /// antigas em `00_Novos/Compras_Recibos`, `INBOX.Trash` e `INBOX.Sent`, e
    /// as chamava de e-mails que "caíram" lá. Não caíram: o dono as pôs lá.
    static func destinoAutomatico(_ folder: MailFolder) -> Bool {
        if folder.role == .junk { return true }
        guard folder.role == .other else { return false }
        return categoriaDoGmail(folder) != nil
    }

    /// `CATEGORY_PROMOTIONS` → "Promoções". `nil` quando a pasta não é uma aba
    /// de categoria do Gmail.
    ///
    /// O reconhecimento é **pela forma do nome no provedor**, nunca pelo nome
    /// escrito: uma pasta que o dono chamou de "Promocao" é dele, e só o
    /// prefixo `CATEGORY_` (da API do Gmail) ou o caminho `[Gmail]/…` provam
    /// que quem pôs a mensagem ali foi o Google.
    static func categoriaDoGmail(_ folder: MailFolder) -> String? {
        let bruto = folder.serverName
        let maiusculo = bruto.uppercased()
        let sufixo: String
        if maiusculo.hasPrefix("CATEGORY_") {
            sufixo = String(maiusculo.dropFirst("CATEGORY_".count))
        } else if maiusculo.hasPrefix("[GMAIL]/") || maiusculo.hasPrefix("[GOOGLE MAIL]/") {
            sufixo = String(maiusculo[maiusculo.range(of: "/")!.upperBound...])
        } else {
            return nil
        }
        switch sufixo {
        case "PROMOTIONS", "PROMOÇÕES", "PROMOCOES": return L10n.tr("Promoções")
        case "UPDATES", "ATUALIZAÇÕES", "ATUALIZACOES": return L10n.tr("Atualizações")
        case "SOCIAL", "REDES SOCIAIS": return L10n.tr("Social")
        case "FORUMS", "FÓRUNS", "FORUNS": return L10n.tr("Fóruns")
        default: return nil
        }
    }

    /// O nome que a frase escreve. Caminho cru nunca sai daqui.
    ///
    /// `INBOX.Junk`, `INBOX/Spam` e `[Gmail]/Spam` são a mesma caixa com três
    /// grafias de servidor; na frase todas são **Spam**.
    static func nomeLegivel(_ folder: MailFolder) -> String {
        if folder.role == .junk { return L10n.tr("Spam") }
        if let categoria = categoriaDoGmail(folder) { return categoria }
        let ultimo = folder.displayName
            .split(whereSeparator: { $0 == "/" || $0 == "." })
            .last
            .map(String.init) ?? folder.displayName
        return ultimo.isEmpty ? folder.displayName : ultimo
    }

    /// Quem **pede resposta** e o provedor jogou sozinho num canto automático.
    ///
    /// Três portões, e os três existem por causa da tela do dono:
    ///
    /// 1. **Só destino automático** (`destinoAutomatico`): Spam e as abas do
    ///    Gmail. Lixeira, enviados, rascunhos, arquivo e pasta criada pela
    ///    pessoa jamais entram — estar lá é decisão dela.
    /// 2. **Só e-mail novo**: recebido nos últimos sete dias e **ainda não
    ///    lido**. Mensagem antiga num canto é histórico, não um acidente de
    ///    hoje; mensagem já lida foi vista e deixada onde está.
    /// 3. **Não arrumada pela pessoa**: se a mensagem também carrega uma pasta
    ///    que não é automática, alguém a arquivou ali — e esse alguém é o dono.
    ///    Este é o sinal de "movida por mim" que o modelo guarda.
    ///
    /// A importância continua sendo a da IA (`InboxWaitingLine.waitsForYou`:
    /// `triage.needsReply`, ou a etiqueta herdada), e não "não lida" — "não
    /// lida" é só o portão 2, somado a ela.
    ///
    /// `nil` quando não há nada a dizer — inclusive sem conta conectada, onde
    /// não há pasta de provedor nenhuma.
    static func misplaced(
        messages: [Message], folders: [MailFolder], now: Date = Date()
    ) -> Misplaced? {
        let porID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        let limite = now.addingTimeInterval(-janelaDoNovo)
        var ids: [String] = []
        var nomes: [String] = []
        for message in messages where InboxWaitingLine.waitsForYou(message) {
            guard !message.isRead, message.receivedAt >= limite else { continue }
            let pastas = message.folderIDs.compactMap { porID[$0] }
            // A mensagem que também está na entrada não está perdida.
            guard !pastas.contains(where: { $0.role == .inbox }) else { continue }
            let automaticas = pastas.filter(destinoAutomatico)
            guard !automaticas.isEmpty else { continue }
            // Arrumada pela pessoa em algum lugar: não é acidente do provedor.
            guard automaticas.count == pastas.count else { continue }
            ids.append(message.id)
            for pasta in automaticas {
                let nome = nomeLegivel(pasta)
                if !nomes.contains(nome) { nomes.append(nome) }
            }
        }
        guard !ids.isEmpty else { return nil }
        return Misplaced(messageIDs: ids, folderNames: nomes)
    }
}
