import Foundation
import UNICore

/// Os tipos e os comandos do IMAP, na parte que é nossa.
///
/// **Montar comando é nosso e é puro; interpretar resposta é da biblioteca.**
/// Essa divisão não é arbitrária: o que a gente manda é um punhado de linhas
/// ASCII com regras simples de citação, e é onde erram os escapes e o formato
/// de data — dois defeitos que um teste puro pega em milissegundos. O que o
/// servidor manda de volta é gramática de verdade, com literais de tamanho
/// declarado e continuação, e é para isso que o `swift-nio-imap` existe.
public enum ImapWire {
    // MARK: Tipos

    public struct Folder: Sendable, Hashable {
        public let name: String
        public let specialUse: String?
        public let role: FolderRole

        public init(name: String, specialUse: String?) {
            self.name = name
            self.specialUse = specialUse
            role = FolderRoles.role(specialUse: specialUse, name: name)
        }
    }

    // MARK: Comandos

    /// Tag de largura fixa: `A0001`. Largura fixa porque os logs do servidor e
    /// os nossos ficam alinháveis, e porque o servidor falso casa por prefixo.
    public static func tag(_ n: Int) -> String { String(format: "A%04d", n) }

    /// Uma string entre aspas, com `\` e `"` escapados — a regra do RFC 3501.
    ///
    /// Sem isto, uma senha de app com aspas dentro quebra o comando e o
    /// servidor responde `BAD`, que a pessoa lê como "senha errada" e passa a
    /// tarde trocando a senha certa.
    public static func quoted(_ s: String) -> String {
        let escapado = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escapado)\""
    }

    public static func login(tag: String, user: String, password: String) -> String {
        "\(tag) LOGIN \(quoted(user)) \(quoted(password))"
    }

    /// O comando que sobe a conexão em claro para TLS, antes de qualquer
    /// credencial. Só existe no caminho `.startTLS`; em `.tls` o TLS já começou
    /// no primeiro byte e este comando seria um erro de protocolo.
    public static func startTLS(tag: String) -> String { "\(tag) STARTTLS" }

    public static func list(tag: String) -> String { "\(tag) LIST \"\" \"*\"" }

    public static func select(tag: String, mailbox: String) -> String {
        "\(tag) SELECT \(quoted(mailbox))"
    }

    /// `dd-MMM-yyyy` com meses em **inglês**, sempre.
    ///
    /// Um `DateFormatter` com o locale da máquina manda `25-ago-2026`, e o
    /// servidor responde `BAD`. É a mesma família do bug de fuso registrado em
    /// `docs/decisoes-de-engenharia.md`: formato de protocolo não pode nascer
    /// de uma conversão que a máquina do usuário decide.
    public static func imapDate(_ date: Date, calendar: Calendar) -> String {
        let meses = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let partes = calendar.dateComponents([.day, .month, .year], from: date)
        let dia = partes.day ?? 1
        let mes = meses[max(0, min(11, (partes.month ?? 1) - 1))]
        return String(format: "%02d-%@-%04d", dia, mes, partes.year ?? 1970)
    }

    public static func uidSearchSince(tag: String, date: Date, calendar: Calendar) -> String {
        "\(tag) UID SEARCH SINCE \(imapDate(date, calendar: calendar))"
    }

    /// Envelopes em lote. Um `FETCH` por mensagem seria uma ida e volta por
    /// mensagem; a conta de 90 dias tem milhares.
    public static func uidFetchEnvelopes(tag: String, uids: [Int64]) -> String {
        let conjunto = uids.map(String.init).joined(separator: ",")
        return "\(tag) UID FETCH \(conjunto) (UID FLAGS INTERNALDATE ENVELOPE)"
    }

    /// Os dois cabeçalhos que dizem **como ler** o corpo.
    ///
    /// Fora do comando, com nome, porque a resposta vem rotulada com o texto
    /// exato que foi pedido — o adaptador procura por esta mesma chave, e as
    /// duas pontas não podem divergir por uma vírgula.
    static let camposDeConteudo = "CONTENT-TYPE CONTENT-TRANSFER-ENCODING"

    /// O corpo em texto de uma mensagem, **com os cabeçalhos que o decifram**.
    ///
    /// `BODY.PEEK` e não `BODY`: `BODY` marca a mensagem como lida no servidor,
    /// e baixar o corpo para o cache não é a pessoa ter lido nada.
    ///
    /// O `HEADER.FIELDS` entrou junto nesta tarefa, e é o conserto do defeito
    /// que o dono via: `BODY[TEXT]` sozinho entrega a **fonte** da mensagem —
    /// `--fronteira`, `Content-Type:` de cada parte, `=E7` no lugar de `ç` — e
    /// quem sabe que aquilo é um `multipart/alternative` com carga em
    /// quoted-printable é justamente o cabeçalho da mensagem, que ficava para
    /// trás. Pedir os dois na mesma ida e volta custa nada e é o que dá ao
    /// `MimeBody` o ponto de partida certo.
    ///
    /// Sem eles o decodificador ainda fareja a fronteira do próprio texto (é o
    /// que a re-decodificação dos corpos velhos faz), mas farejar é a saída de
    /// emergência: aqui a informação existe, e é de graça.
    public static func uidFetchBody(tag: String, uid: Int64) -> String {
        "\(tag) UID FETCH \(uid) (BODY.PEEK[HEADER.FIELDS (\(camposDeConteudo))] BODY.PEEK[TEXT])"
    }

    public static func logout(tag: String) -> String { "\(tag) LOGOUT" }

    // MARK: Os comandos da sincronização contínua

    /// `CAPABILITY` — a lista do que o servidor sabe fazer.
    ///
    /// Perguntada, e não deduzida da saudação: a saudação **pode** trazer
    /// `[CAPABILITY …]` e muitos servidores trazem, mas depois do `LOGIN` a
    /// lista muda (é o que o RFC 3501 manda relê-la), e um servidor que anuncia
    /// `IDLE` só para sessão autenticada ficaria de fora do caminho vivo por
    /// causa de uma leitura feita cedo demais.
    public static func capability(tag: String) -> String { "\(tag) CAPABILITY" }

    /// `UID SEARCH UID 42:*` — "o que chegou depois do último que eu conheço?".
    ///
    /// **O resultado precisa ser filtrado**, e isso não é preciosismo: o RFC
    /// 3501 manda o servidor tratar `*` como o maior UID existente, e um
    /// intervalo `n:*` com `n` maior que todos devolve mesmo assim o maior —
    /// uma caixa parada responderia "esta aqui é nova" para a mesma mensagem em
    /// todo ciclo. Quem filtra é `ImapSession.uids(from:)`.
    public static func uidSearchFrom(tag: String, uid: Int64) -> String {
        "\(tag) UID SEARCH UID \(max(1, uid)):*"
    }

    /// `UID FETCH 1,2,3 (UID FLAGS)` — só as bandeiras, sem envelope nem corpo.
    ///
    /// É a metade barata do delta: reler o envelope de duzentas mensagens para
    /// descobrir que uma foi marcada como lida custaria o que a carga inicial
    /// custa, a cada ciclo. E é também como o expurgo é detectado — o UID que
    /// não volta na resposta não está mais na pasta.
    public static func uidFetchFlags(tag: String, uids: [Int64]) -> String {
        "\(tag) UID FETCH \(uidSet(uids)) (UID FLAGS)"
    }

    /// `IDLE` (RFC 2177). O par dele é `done`, e os dois **sempre** andam
    /// juntos: um IDLE sem DONE deixa a conexão presa num estado em que nenhum
    /// outro comando é aceito.
    public static func idle(tag: String) -> String { "\(tag) IDLE" }

    /// `DONE` — sem tag, de propósito: é a única linha do protocolo que
    /// responde a um comando em vez de abrir outro.
    public static func done() -> String { "DONE" }

    /// As capacidades anunciadas, em **maiúsculas** — `IMAP4rev1`, `IDLE`,
    /// `STARTTLS`… A dobra é o ponto: o RFC não obriga caixa nenhuma, e
    /// `contains("IDLE")` sobre o texto cru deixaria de fora todo servidor que
    /// responde `Idle`.
    public static func capabilities(from respostas: [Untagged]) -> Set<String> {
        var todas: Set<String> = []
        for resposta in respostas {
            switch resposta {
            case .capability(let lista): todas.formUnion(lista.map { $0.uppercased() })
            // O `SELECT` e o `LOGIN` costumam devolver a lista dentro de um
            // `* OK [CAPABILITY …]`, e é a mesma informação.
            case .ok(let codigo, let valor) where codigo.uppercased() == "CAPABILITY":
                todas.formUnion(valor.split(separator: " ").map { $0.uppercased() })
            default: continue
            }
        }
        return todas
    }

    /// As bandeiras de cada UID de uma resposta de `UID FETCH … (UID FLAGS)`.
    ///
    /// Dicionário, e não lista: quem chama precisa saber **quais UIDs não
    /// voltaram** — são os expurgados —, e uma lista obrigaria cada chamador a
    /// refazer o cruzamento.
    public static func flags(from respostas: [Untagged]) -> [Int64: [String]] {
        var mapa: [Int64: [String]] = [:]
        for resposta in respostas {
            guard case .fetch(let linha) = resposta else { continue }
            mapa[linha.uid] = linha.flags
        }
        return mapa
    }

    // MARK: Os comandos de escrita — o espelho da triagem

    /// Um conjunto de UIDs como o IMAP o escreve: `1,2,5`.
    public static func uidSet(_ uids: [Int64]) -> String {
        uids.map(String.init).joined(separator: ",")
    }

    /// `UID STORE 1,2 +FLAGS (\Seen)` — ou `-FLAGS`, para tirar.
    ///
    /// **Naturalmente idempotente**, e é isso que faz o retry depois de um
    /// timeout ambíguo ser seguro: `+FLAGS` põe a bandeira que já está lá sem
    /// mudar nada. É por isso que a operação é sempre "ponha" ou "tire", nunca
    /// "inverta" — inverter aplicado duas vezes desfaz o que a pessoa pediu.
    ///
    /// `.SILENT` porque a resposta `FETCH` de confirmação não é lida por
    /// ninguém aqui, e pedi-la é uma linha por mensagem à toa.
    public static func uidStore(tag: String, uids: [Int64], flags: [String], add: Bool) -> String {
        "\(tag) UID STORE \(uidSet(uids)) \(add ? "+" : "-")FLAGS.SILENT (\(flags.joined(separator: " ")))"
    }

    /// O mesmo, para a caixa **inteira**: é o que "esvaziar a lixeira" pede no
    /// IMAP, onde não existe um "apague tudo" e sim marcar tudo e expurgar.
    public static func storeAllDeleted(tag: String) -> String {
        "\(tag) STORE 1:* +FLAGS.SILENT (\\Deleted)"
    }

    public static func uidCopy(tag: String, uids: [Int64], mailbox: String) -> String {
        "\(tag) UID COPY \(uidSet(uids)) \(quoted(mailbox))"
    }

    public static func expunge(tag: String) -> String { "\(tag) EXPUNGE" }

    public static func create(tag: String, mailbox: String) -> String {
        "\(tag) CREATE \(quoted(mailbox))"
    }

    /// `APPEND` com literal **não sincronizado** (`{n+}`), a mensagem inteira
    /// numa escrita só.
    ///
    /// O `+` é o que dispensa a resposta `+ ready` do servidor no meio do
    /// comando — e é ele que deixa este `APPEND` caber no mesmo caminho de
    /// todos os outros comandos daqui, que é "mandar uma linha e esperar a
    /// resposta tagueada". Sem `LITERAL+`, o `APPEND` precisaria de uma espera
    /// no meio que nenhum outro comando tem; quem chama confere a capacidade
    /// antes e deixa de gravar a cópia se ela não estiver lá, em vez de
    /// arrastar essa espera para dentro do handler por causa de uma cópia que
    /// é conveniência.
    ///
    /// O tamanho é em **bytes**, não em caracteres: um assunto com acento tem
    /// mais bytes que letras, e um número curto demais faria o servidor ler o
    /// resto da mensagem como comandos.
    public static func append(tag: String, mailbox: String, flags: [String], raw: String) -> String {
        let bandeiras = flags.isEmpty ? "" : " (\(flags.joined(separator: " ")))"
        return "\(tag) APPEND \(quoted(mailbox))\(bandeiras) {\(raw.utf8.count)+}\r\n\(raw)"
    }

    /// `UID SEARCH UID 42` — "este UID ainda está nesta pasta?".
    public static func uidSearchUID(tag: String, uids: [Int64]) -> String {
        "\(tag) UID SEARCH UID \(uidSet(uids))"
    }

    /// `UID SEARCH HEADER Message-ID "<…>"` — "esta mensagem já está aqui?".
    ///
    /// É a pergunta que torna o mover do IMAP idempotente: `COPY` **não** é
    /// idempotente (copiar duas vezes deixa duas cópias na pasta de destino), e
    /// um retry depois de um timeout ambíguo não sabe se a primeira cópia
    /// passou. O `Message-ID` é a identidade que atravessa a cópia — o mesmo
    /// cabeçalho, na origem e no destino.
    public static func uidSearchMessageID(tag: String, messageID: String) -> String {
        "\(tag) UID SEARCH HEADER Message-ID \(quoted(messageID))"
    }

    /// Só o cabeçalho `Message-ID`, sem baixar o corpo. `PEEK` pela mesma razão
    /// de sempre: ler para espelhar não é a pessoa ter lido a mensagem.
    public static func uidFetchMessageID(tag: String, uid: Int64) -> String {
        "\(tag) UID FETCH \(uid) (BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])"
    }

    /// O `<…>` de dentro de um cabeçalho `Message-ID: <…>`.
    ///
    /// Puro, e testado como tal: o que chega é o cabeçalho cru, com o nome, os
    /// dois pontos e o CRLF final que o `BODY[HEADER.FIELDS]` sempre manda.
    public static func messageID(fromHeader cabecalho: String) -> String? {
        guard let abre = cabecalho.firstIndex(of: "<"),
              let fecha = cabecalho[abre...].firstIndex(of: ">"), abre < fecha
        else { return nil }
        return String(cabecalho[abre...fecha])
    }

    // MARK: Respostas, do nosso lado

    /// Uma linha untagged, já traduzida para os nossos termos.
    ///
    /// **Este é o contrato entre a biblioteca e o resto do app.** Tudo daqui
    /// para dentro é puro e testado sem NIO; tudo daqui para fora é
    /// `ImapResponseAdapter`, que é um arquivo só. Se o `swift-nio-imap` mudar
    /// de forma, quebra um arquivo.
    public enum Untagged: Sendable, Hashable {
        case list(name: String, attributes: [String])
        case search([Int64])
        case exists(Int)
        /// `* 3 EXPUNGE` — a mensagem de número de sequência 3 saiu da pasta.
        ///
        /// O número **não** é um UID e é inútil para casar a linha do banco (o
        /// IMAP renumera as sequências a cada expurgo). Ele existe aqui como
        /// **sinal**: quem está em IDLE acorda com ele, e quem acorda descobre
        /// o que sumiu pelo `UID FETCH … (UID FLAGS)` do delta, que é a única
        /// pergunta cuja resposta é confiável.
        case expunge(Int)
        /// `* CAPABILITY IMAP4rev1 IDLE …`
        case capability([String])
        /// `* OK [UIDVALIDITY 1755000000] …` → `code: "UIDVALIDITY"`, `value: "1755000000"`.
        case ok(code: String, value: String)
        case fetch(FetchLine)
        /// O que não interessa a esta versão. Guardado como texto para o log
        /// poder mostrar, em vez de sumir.
        case outra(String)
    }

    /// Uma resposta de `FETCH`, com os campos que a gente pediu.
    ///
    /// Os endereços chegam como texto de cabeçalho porque é assim que eles
    /// saem do `ENVELOPE`, e porque o parser deles já existe e é um só:
    /// `MailAddress`. Uma segunda implementação para IMAP divergiria da do
    /// Gmail no primeiro caso esquisito.
    public struct FetchLine: Sendable, Hashable {
        public let uid: Int64
        public let flags: [String]
        public let internalDate: Date?
        public let from: String?
        public let to: String?
        public let cc: String?
        public let subject: String?
        public let text: String?
        /// O cabeçalho `Message-ID` cru, quando o `FETCH` o pediu. Campo
        /// próprio, e não `text`: os dois vêm em literal e caem na mesma linha,
        /// e misturá-los faria um `BODY.PEEK[HEADER.FIELDS …]` ser lido como
        /// corpo da mensagem — texto de cabeçalho gravado como parágrafo.
        public let messageIDHeader: String?
        /// O bloco `Content-Type` + `Content-Transfer-Encoding` da mensagem,
        /// cru, quando o `FETCH` os pediu. Campo próprio pela mesma razão que
        /// `messageIDHeader` é: os dois viajam em literal ao lado do corpo, e
        /// misturá-los faria o cabeçalho ser gravado como parágrafo.
        ///
        /// Nulo é caso normal e não é falha: servidor que devolve o rótulo com
        /// outra grafia, ou um `FETCH` que não os pediu, caem no farejamento do
        /// `MimeBody`.
        public let contentHeader: String?

        public init(
            uid: Int64, flags: [String], internalDate: Date?,
            from: String?, to: String?, cc: String?, subject: String?, text: String?,
            messageIDHeader: String? = nil,
            contentHeader: String? = nil
        ) {
            self.contentHeader = contentHeader
            self.uid = uid
            self.flags = flags
            self.internalDate = internalDate
            self.from = from
            self.to = to
            self.cc = cc
            self.subject = subject
            self.text = text
            self.messageIDHeader = messageIDHeader
        }
    }

    /// Duzentos envelopes por ida e volta.
    ///
    /// Não é chute: um `FETCH` por mensagem custaria uma viagem por mensagem
    /// numa caixa de milhares, e um `FETCH 1:*` traria a caixa inteira numa
    /// resposta que não cabe em memória nem dá para interromper. Duzentos é
    /// grande o bastante para a viagem valer e pequeno o bastante para o lote
    /// caber numa transação e o "parar no meio" custar pouco.
    public static let fetchBatchSize = 200

    public static func folders(from respostas: [Untagged]) -> [Folder] {
        respostas.compactMap { resposta in
            guard case .list(let nome, let atributos) = resposta else { return nil }
            // `\Noselect` é nó da árvore, não pasta. `SELECT` nele devolve NO,
            // e um NO no meio da carga derrubaria tudo por causa de um
            // separador de hierarquia.
            let dobrados = atributos.map { $0.lowercased() }
            guard !dobrados.contains("\\noselect") else { return nil }
            let especial = atributos.first { atributo in
                ["\\inbox", "\\archive", "\\all", "\\trash", "\\sent", "\\drafts", "\\junk"]
                    .contains(atributo.lowercased())
            }
            return Folder(name: nome, specialUse: especial)
        }
    }

    public static func status(from respostas: [Untagged]) -> ImapMailboxStatus? {
        var uidValidity: Int64?
        var uidNext: Int64 = 0
        var exists = 0
        for resposta in respostas {
            switch resposta {
            case .exists(let quantas): exists = quantas
            case .ok(let codigo, let valor) where codigo.uppercased() == "UIDVALIDITY":
                uidValidity = Int64(valor)
            case .ok(let codigo, let valor) where codigo.uppercased() == "UIDNEXT":
                uidNext = Int64(valor) ?? 0
            default: continue
            }
        }
        // Sem UIDVALIDITY não há identidade estável para UID nenhum. Inventar
        // zero faria o Marco 3 casar UID reciclado com mensagem errada.
        guard let uidValidity else { return nil }
        return ImapMailboxStatus(uidValidity: uidValidity, uidNext: uidNext, exists: exists)
    }

    public static func uids(from respostas: [Untagged]) -> [Int64] {
        var todos: Set<Int64> = []
        for resposta in respostas {
            if case .search(let lista) = resposta { todos.formUnion(lista) }
        }
        return todos.sorted()
    }

    public static func envelopes(from respostas: [Untagged]) -> [ImapEnvelope] {
        respostas.compactMap { resposta in
            guard case .fetch(let linha) = resposta else { return nil }
            // Sem data não entra: datar com `agora` jogaria toda mensagem
            // quebrada para o topo da lista, acima do que chegou hoje.
            guard let data = linha.internalDate else { return nil }
            return ImapEnvelope(
                uid: linha.uid,
                from: MailAddress.parse(linha.from ?? "")
                    ?? Contact(name: "Remetente desconhecido", address: ""),
                to: MailAddress.parseList(linha.to ?? ""),
                cc: MailAddress.parseList(linha.cc ?? ""),
                subject: MailAddress.decodeRFC2047(linha.subject ?? ""),
                date: data,
                // As bandeiras são projeção, e a regra mora em
                // `TriageProjection` junto da variante do Gmail — não escrita
                // à mão aqui, onde ela viraria a segunda resposta para a
                // mesma pergunta e divergiria da primeira.
                isRead: TriageProjection.isRead(imapFlags: linha.flags),
                isFlagged: TriageProjection.isFlagged(imapFlags: linha.flags)
            )
        }
    }

    /// O corpo de uma mensagem, **decodificado**.
    ///
    /// Era `GmailMessageParser.paragraphs(from: texto)` direto sobre o
    /// `BODY[TEXT]`, e é aí que nasceu o defeito do dono: `BODY[TEXT]` não é o
    /// texto da mensagem, é a fonte dela depois dos cabeçalhos. Numa mensagem
    /// moderna isso é multipart com carga codificada, e cortá-la em parágrafos
    /// grava fronteira e sub-cabeçalho como leitura.
    ///
    /// Quem decide agora é o `MimeBody` — o mesmo, e único, que a carga do
    /// Gmail e a busca por demanda usam.
    public static func bodyText(from respostas: [Untagged], uid: Int64) -> [String] {
        for resposta in respostas {
            guard case .fetch(let linha) = resposta, linha.uid == uid, let texto = linha.text else { continue }
            let (tipo, codificacao) = conteudo(de: linha.contentHeader)
            return MimeBody.paragraphs(
                raw: texto, contentType: tipo, contentTransferEncoding: codificacao
            )
        }
        return []
    }

    /// O bloco de cabeçalho cru virando o par que o decodificador pede.
    ///
    /// Lido pelo mesmo separador de cabeçalhos das partes MIME: um
    /// `Content-Type` longo chega quebrado em duas linhas aqui do mesmo jeito
    /// que lá dentro, e é sempre a segunda linha que carrega o `boundary=`.
    static func conteudo(de cabecalho: String?) -> (String?, String?) {
        guard let cabecalho, !cabecalho.isEmpty else { return (nil, nil) }
        let (campos, _) = MimeBody.separaCabecalhos(cabecalho)
        return (campos["content-type"], campos["content-transfer-encoding"])
    }
}

/// A troca de `UIDVALIDITY` — o sinal de que os UIDs da pasta foram reciclados.
///
/// Aqui ela só é **detectada**; refazer a pasta é do Marco 3. Detectar já vale
/// porque é o que faz a carga inicial gravar o par certo em `sync_state`, e é
/// o que o Marco 3 vai comparar.
public enum ImapUidValidity {
    /// Primeira vez **não** é troca: `nil` significa "nunca vimos esta pasta".
    public static func changed(previous: Int64?, current: Int64) -> Bool {
        guard let previous else { return false }
        return previous != current
    }
}

public typealias ImapFolder = ImapWire.Folder

public struct ImapMailboxStatus: Sendable, Hashable {
    public let uidValidity: Int64
    public let uidNext: Int64
    public let exists: Int

    public init(uidValidity: Int64, uidNext: Int64, exists: Int) {
        self.uidValidity = uidValidity
        self.uidNext = uidNext
        self.exists = exists
    }
}

public struct ImapEnvelope: Sendable, Hashable {
    public let uid: Int64
    public let from: Contact
    public let to: [Contact]
    public let cc: [Contact]
    public let subject: String
    public let date: Date
    public let isRead: Bool
    public let isFlagged: Bool

    public init(
        uid: Int64, from: Contact, to: [Contact], cc: [Contact],
        subject: String, date: Date, isRead: Bool, isFlagged: Bool
    ) {
        self.uid = uid
        self.from = from
        self.to = to
        self.cc = cc
        self.subject = subject
        self.date = date
        self.isRead = isRead
        self.isFlagged = isFlagged
    }
}
