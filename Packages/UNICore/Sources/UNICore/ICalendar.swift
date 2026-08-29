import Foundation

/// O convite de agenda que veio dentro de uma mensagem.
///
/// **É o que o cartão do leitor desenha.** Antes disto, uma mensagem cujo corpo
/// é um `multipart` com `text/calendar` e HTML caía em "Esta mensagem não tem
/// texto" — o convite mais comum que existe (Google Agenda, Outlook, Zoom)
/// chegava ao leitor como uma frase dizendo que não havia nada ali.
///
/// Tudo é opcional menos o `summary`, e nem ele é obrigatório de verdade: um
/// convite mal formado ainda é um convite, e recusá-lo inteiro por causa de uma
/// data ilegível devolveria a pessoa exatamente ao vazio de antes.
public struct CalendarInvite: Sendable, Hashable {
    /// `SUMMARY` — o título. Vazio quando o convite não trouxe nenhum.
    public let summary: String
    /// `DTSTART`, já em instante absoluto. `nil` quando a data é ilegível.
    public let start: Date?
    /// `DTEND`. `nil` quando ausente ou ilegível.
    public let end: Date?
    /// `DTSTART;VALUE=DATE` — o compromisso de dia inteiro, sem hora.
    public let isAllDay: Bool
    public let location: String?

    /// `ORGANIZER` inteiro — nome **e** endereço.
    ///
    /// Era só o nome de exibição, e o compromisso criado a partir do convite
    /// não tinha como dizer quem organizava: a janela de detalhe caía no
    /// organizador de fixture ("Ricardo Gomes · ricardo@empresa.com") num
    /// evento que o Favini tinha convidado.
    public let organizerContact: Contact?

    /// `ATTENDEE`, cada um com nome e endereço, sem repetidos.
    public let attendeeContacts: [Contact]

    /// `DESCRIPTION` — o texto que o convite traz. É onde mora, muitas vezes,
    /// o link da reunião e a pauta.
    public let descricao: String?

    /// `URL` — quando o convite declara um endereço próprio.
    public let url: String?
    /// `METHOD` do `VCALENDAR`: `REQUEST`, `CANCEL`, `REPLY`.
    public let method: String?
    /// `STATUS` do `VEVENT`: `CONFIRMED`, `TENTATIVE`, `CANCELLED`.
    public let status: String?

    /// `UID` — **a identidade do compromisso**, a mesma em todas as cópias
    /// dele: o convite original, o "Convite atualizado", o encaminhamento que
    /// um colega mandou.
    ///
    /// Era o campo que faltava, e a falta tinha nome na tela do dono: dois
    /// blocos "DreamSquad" idênticos na agenda, porque o convite e a
    /// atualização do **mesmo** evento entraram como dois compromissos
    /// diferentes. Com encaminhamento, seriam cinquenta.
    ///
    /// `nil` num convite sem `UID` (existe, e é convite mesmo assim). Quem
    /// não tem UID cai na identidade de antes — a mensagem que o trouxe.
    public let uid: String?

    /// `SEQUENCE` — a versão deste convite. Sobe a cada alteração que o
    /// organizador manda; é assim que "Convite atualizado" se distingue de uma
    /// cópia do original.
    ///
    /// `nil` é ausente, que pelo RFC 5545 vale `0` — mas guardamos a ausência
    /// em vez de assumir zero para não confundir "não disse" com "primeira
    /// versão" na hora de comparar.
    public let sequence: Int?

    public init(
        summary: String, start: Date?, end: Date?, isAllDay: Bool = false,
        location: String? = nil, organizer: Contact? = nil, attendees: [Contact] = [],
        method: String? = nil, status: String? = nil,
        uid: String? = nil, sequence: Int? = nil,
        descricao: String? = nil, url: String? = nil
    ) {
        self.uid = uid
        self.sequence = sequence
        self.summary = summary
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.organizerContact = organizer
        self.attendeeContacts = attendees
        self.method = method
        self.status = status
        self.descricao = descricao
        self.url = url
    }

    /// Como o cartão do leitor escreve o organizador: o nome quando há, o
    /// endereço quando não. Continua sendo o que a M3-8 mostrava — mudou o que
    /// está guardado por baixo, não o que a pessoa lê.
    public var organizer: String? { organizerContact.map(Self.nomeVisivel) }

    /// Os participantes, no mesmo idioma.
    public var attendees: [String] { attendeeContacts.map(Self.nomeVisivel) }

    static func nomeVisivel(_ quem: Contact) -> String {
        quem.name.isEmpty ? quem.address : quem.name
    }

    /// O link da reunião, procurado onde ele de fato vem.
    ///
    /// Três lugares, nesta ordem: o `URL:` do convite (quando é http), a
    /// `LOCATION` (o Google Meet escreve a sala ali) e a `DESCRIPTION` (Zoom e
    /// Teams enterram o link no meio do texto). Sem os três, não há link — e a
    /// janela de detalhe simplesmente não desenha o cartão dele.
    ///
    /// Só endereços de reunião conhecidos: um convite traz link de mapa, de
    /// cancelamento e de política de privacidade, e "a primeira URL do texto"
    /// poria qualquer um deles onde a pessoa espera o botão de entrar.
    public var meetingURL: String? {
        for texto in [url, location, descricao].compactMap({ $0 }) {
            if let achado = MeetingLink.first(in: texto) { return achado }
        }
        return nil
    }

    /// Quanto dura um convite que não disse quando termina.
    ///
    /// Uma hora é o que Google Agenda, Outlook e Calendar.app assumem para um
    /// compromisso sem `DTEND`. Não é adivinhação nossa: é a convenção que a
    /// pessoa já viu em todo lugar.
    public static let duracaoPadrao: TimeInterval = 3_600

    /// O convite virando o `DetectedEvent` que "Colocar na agenda" já sabe
    /// receber.
    ///
    /// **Ligado ao caminho que existe, e não a um segundo.** `MailStore.
    /// addToAgenda`, o id determinístico de `DetectedEventConversion` e o
    /// "Desfazer" do recibo continuam sendo os mesmos — o convite entra por
    /// onde o compromisso detectado já entrava. Uma segunda porta para a agenda
    /// divergiria da primeira no primeiro caso esquisito, e duplicaria o
    /// compromisso na trilha.
    ///
    /// `nil` sem `DTSTART`: um compromisso sem começo não tem onde ser
    /// desenhado, e o botão não pode existir para não fazer nada.
    public var detectedEvent: DetectedEvent? {
        guard let start else { return nil }
        let duracao = end.map { max(0, $0.timeIntervalSince(start)) } ?? Self.duracaoPadrao
        return DetectedEvent(
            label: summary.isEmpty ? "Compromisso" : summary,
            start: start,
            duration: duracao
        )
    }

    /// O convite foi cancelado? O cartão diz isso em vez de oferecer a agenda.
    public var isCancelled: Bool {
        method?.uppercased() == "CANCEL" || status?.uppercased() == "CANCELLED"
    }
}

/// O `text/calendar` de uma mensagem virando `CalendarInvite`.
///
/// **Mínimo de propósito.** O RFC 5545 tem recorrência, fuso embutido
/// (`VTIMEZONE`), alarme, anexo e uma gramática de datas com quatro formas.
/// Isto lê o que um cartão de convite mostra — título, quando, onde, quem — e
/// ignora o resto sem reclamar. Um parser completo é outro projeto; um cartão
/// vazio é o defeito de hoje.
///
/// Puro: nada aqui abre conexão nem lê banco. O relógio aparece só como
/// `TimeZone`, e ele entra pela porta (`timeZone:`) para o teste não depender
/// da máquina de quem o roda.
public enum ICalendar {
    /// O primeiro `VEVENT` do calendário. `nil` quando não há nenhum.
    ///
    /// O primeiro, e não todos: uma mensagem de convite carrega um evento —
    /// quando ela carrega uma série, é a mesma coisa repetida com regra de
    /// recorrência, que este parser não lê de propósito.
    public static func parse(_ texto: String, timeZone: TimeZone = .current) -> CalendarInvite? {
        let linhas = desdobra(texto)
        guard !linhas.isEmpty else { return nil }

        var method: String?
        var dentro = false
        var terminou = false
        var summary = ""
        var location: String?
        var organizer: Contact?
        var attendees: [Contact] = []
        var descricao: String?
        var url: String?
        var status: String?
        var uid: String?
        var sequence: Int?
        var start: Date?
        var end: Date?
        var diaInteiro = false
        var achouEvento = false

        for linha in linhas {
            guard let (nome, parametros, valor) = propriedade(linha) else { continue }
            switch nome {
            case "BEGIN" where valor.uppercased() == "VEVENT":
                // Só o primeiro: `terminou` impede o segundo de sobrescrever o
                // que o primeiro disse.
                if !terminou { dentro = true; achouEvento = true }
            case "END" where valor.uppercased() == "VEVENT":
                if dentro { dentro = false; terminou = true }
            case "METHOD" where !dentro:
                method = valor.uppercased()
            case "SUMMARY" where dentro:
                summary = desescapa(valor)
            case "LOCATION" where dentro:
                location = vazioVira(nil, desescapa(valor))
            case "STATUS" where dentro:
                status = valor.uppercased()
            case "UID" where dentro:
                // Sem `desescapa`: o UID é opaco e comparado byte a byte com o
                // de outra cópia do mesmo convite. Interpretar barras invertidas
                // faria duas cópias iguais deixarem de casar.
                uid = vazioVira(nil, valor)
            case "DESCRIPTION" where dentro:
                descricao = vazioVira(nil, desescapa(valor))
            case "URL" where dentro:
                url = vazioVira(nil, valor)
            case "SEQUENCE" where dentro:
                sequence = Int(valor.trimmingCharacters(in: .whitespaces))
            case "ORGANIZER" where dentro:
                organizer = pessoa(parametros: parametros, valor: valor)
            case "ATTENDEE" where dentro:
                if let quem = pessoa(parametros: parametros, valor: valor) {
                    // Sem repetidos: um convite grande lista o mesmo endereço
                    // como participante e como organizador, e o cartão mostraria
                    // o nome duas vezes. A comparação é pelo endereço — o mesmo
                    // `id` de `Contact` —, porque o mesmo participante pode vir
                    // com `CN` numa linha e sem `CN` noutra.
                    if !attendees.contains(where: { $0.id == quem.id }) { attendees.append(quem) }
                }
            case "DTSTART" where dentro:
                let lido = data(valor, parametros: parametros, timeZone: timeZone)
                start = lido.data
                diaInteiro = lido.diaInteiro
            case "DTEND" where dentro:
                end = data(valor, parametros: parametros, timeZone: timeZone).data
            default:
                continue
            }
        }
        guard achouEvento else { return nil }
        return CalendarInvite(
            summary: summary, start: start, end: end, isAllDay: diaInteiro,
            location: location, organizer: organizer, attendees: attendees,
            method: method, status: status,
            uid: uid, sequence: sequence,
            descricao: descricao, url: url
        )
    }

    // MARK: - As linhas

    /// As continuações do RFC 5545 remontadas.
    ///
    /// Uma propriedade longa é quebrada em 75 octetos e continuada com **um
    /// espaço ou tabulação** na frente da linha seguinte. Ler cada linha por si
    /// partiria todo `SUMMARY` de convite de verdade no meio de uma palavra — e
    /// pior, deixaria o resto do título parecendo uma propriedade sem nome.
    static func desdobra(_ texto: String) -> [String] {
        let cru = texto
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var linhas: [String] = []
        for linha in cru.split(separator: "\n", omittingEmptySubsequences: false) {
            if (linha.hasPrefix(" ") || linha.hasPrefix("\t")), !linhas.isEmpty {
                linhas[linhas.count - 1] += String(linha.dropFirst())
            } else if !linha.trimmingCharacters(in: .whitespaces).isEmpty {
                linhas.append(String(linha))
            }
        }
        return linhas
    }

    /// `DTSTART;TZID=America/Sao_Paulo:20260827T150000` → nome, parâmetros e
    /// valor.
    ///
    /// O corte é no primeiro `:` **fora de aspas**: um `CN="Duarte, Marina"`
    /// pode conter dois-pontos, e cortar no primeiro que aparece jogaria metade
    /// do nome para dentro do valor.
    static func propriedade(_ linha: String) -> (String, [String: String], String)? {
        var emAspas = false
        var corte: String.Index?
        var i = linha.startIndex
        while i < linha.endIndex {
            let c = linha[i]
            if c == "\"" { emAspas.toggle() }
            if c == ":", !emAspas { corte = i; break }
            i = linha.index(after: i)
        }
        guard let corte else { return nil }
        let cabeca = String(linha[linha.startIndex..<corte])
        let valor = String(linha[linha.index(after: corte)...])

        let pedacos = separaPorPontoEVirgula(cabeca)
        guard let nome = pedacos.first, !nome.isEmpty else { return nil }
        var parametros: [String: String] = [:]
        for pedaco in pedacos.dropFirst() {
            guard let igual = pedaco.firstIndex(of: "=") else { continue }
            let chave = String(pedaco[pedaco.startIndex..<igual]).uppercased()
            var conteudo = String(pedaco[pedaco.index(after: igual)...])
            if conteudo.hasPrefix("\""), conteudo.hasSuffix("\""), conteudo.count >= 2 {
                conteudo = String(conteudo.dropFirst().dropLast())
            }
            parametros[chave] = conteudo
        }
        return (nome.uppercased(), parametros, valor)
    }

    private static func separaPorPontoEVirgula(_ texto: String) -> [String] {
        var pedacos: [String] = []
        var atual = ""
        var emAspas = false
        for c in texto {
            if c == "\"" { emAspas.toggle() }
            if c == ";", !emAspas {
                pedacos.append(atual)
                atual = ""
                continue
            }
            atual.append(c)
        }
        pedacos.append(atual)
        return pedacos
    }

    // MARK: - Os valores

    /// O escape do RFC 5545: `\n`, `\,`, `\;` e `\\`.
    static func desescapa(_ valor: String) -> String {
        var saida = ""
        var escapando = false
        for c in valor {
            if escapando {
                switch c {
                case "n", "N": saida.append("\n")
                case "\\": saida.append("\\")
                default: saida.append(c)
                }
                escapando = false
                continue
            }
            if c == "\\" { escapando = true; continue }
            saida.append(c)
        }
        return saida
    }

    /// O nome de quem está no `ORGANIZER`/`ATTENDEE`.
    ///
    /// O `CN=` primeiro, porque é o nome que a pessoa reconhece; o endereço
    /// quando não há `CN` — e sem o `mailto:`, que é protocolo, não gente.
    static func pessoa(parametros: [String: String], valor: String) -> Contact? {
        let cn = desescapa(parametros["CN"]?.trimmingCharacters(in: .whitespaces) ?? "")
        let cru = valor.trimmingCharacters(in: .whitespaces)
        let semEsquema = cru.lowercased().hasPrefix("mailto:") ? String(cru.dropFirst(7)) : cru
        // Sem nome e sem endereço não há pessoa. Com um dos dois, há: o
        // convite que só diz `CN` (existe) continua nomeando quem convidou.
        guard !cn.isEmpty || !semEsquema.isEmpty else { return nil }
        return Contact(name: cn, address: semEsquema)
    }

    /// `20260827T150000Z`, `20260827T150000` e `20260827`.
    ///
    /// **Data ilegível devolve `nil` e não derruba nada.** Um convite com
    /// `DTSTART:amanhã` (existe) tem de continuar mostrando título, local e
    /// participantes — o cartão perde a linha do quando, e só ela.
    static func data(
        _ valor: String, parametros: [String: String], timeZone: TimeZone
    ) -> (data: Date?, diaInteiro: Bool) {
        let cru = valor.trimmingCharacters(in: .whitespaces)
        let fuso = parametros["TZID"].flatMap { TimeZone(identifier: $0) } ?? timeZone
        var calendario = Calendar(identifier: .gregorian)
        calendario.timeZone = fuso

        func numero(_ inicio: Int, _ tamanho: Int) -> Int? {
            let caracteres = Array(cru)
            guard caracteres.count >= inicio + tamanho else { return nil }
            return Int(String(caracteres[inicio..<(inicio + tamanho)]))
        }
        guard let ano = numero(0, 4), let mes = numero(4, 2), let dia = numero(6, 2),
              (1...12).contains(mes), (1...31).contains(dia) else {
            return (nil, false)
        }

        var partes = DateComponents(year: ano, month: mes, day: dia)
        let temHora = cru.count >= 15 && (Array(cru)[8] == "T" || Array(cru)[8] == "t")
        if temHora {
            guard let hora = numero(9, 2), let minuto = numero(11, 2),
                  let segundo = numero(13, 2),
                  (0...23).contains(hora), (0...59).contains(minuto), (0...60).contains(segundo)
            else { return (nil, false) }
            partes.hour = hora
            partes.minute = minuto
            partes.second = segundo
            // O `Z` do fim é UTC, e ele manda: um `TZID` ao lado de um valor em
            // UTC é contradição, e o RFC diz que o `Z` vence.
            if cru.uppercased().hasSuffix("Z") {
                calendario.timeZone = TimeZone(identifier: "UTC") ?? fuso
            }
        } else {
            // `VALUE=DATE`: dia inteiro, começando à meia-noite do fuso do
            // convite. Assumir meio-dia ou UTC jogaria o compromisso para o dia
            // anterior de metade do planeta.
            partes.hour = 0
            partes.minute = 0
            partes.second = 0
        }
        return (calendario.date(from: partes), !temHora)
    }

    private static func vazioVira(_ substituto: String?, _ valor: String) -> String? {
        let podado = valor.trimmingCharacters(in: .whitespacesAndNewlines)
        return podado.isEmpty ? substituto : podado
    }
}
