import Foundation

/// Dados do protótipo, para desenvolver e testar a UI antes dos backends.
///
/// As contas aqui são **exemplos** que o designer usou — não o escopo do
/// produto, que aceita quantas contas o usuário quiser, de qualquer provedor
/// e qualquer domínio. Nenhum teste deve afirmar a quantidade destas contas.
public enum Fixtures {

    /// Protótipo: `const ACC` (linha 1539), na ordem de `ORDER`.
    ///
    /// Repare em `id: "host"` com `host: "hostinger"`. O `id` é a chave que
    /// casa mensagem com conta e nasceu abreviada no protótipo; o `host` é o
    /// nome do provedor que a tela mostra. Eram a mesma coisa aqui, e por isso
    /// o chip escrevia HOST onde o design escreve HOSTINGER.
    public static let accounts: [Account] = [
        Account(id: "zoho", address: "ricardo@empresa.com",
                displayName: "Empresa", provider: .imap, host: "zoho",
                tintLightHex: "#3F6AA1", tintDarkHex: "#8CBAF7"),
        Account(id: "gmail", address: "ricardo@gmail.com",
                displayName: "Pessoal", provider: .gmail, host: "gmail",
                tintLightHex: "#725B9A", tintDarkHex: "#C2A7F4"),
        Account(id: "host", address: "contato@meusite.com",
                displayName: "Site", provider: .imap, host: "hostinger",
                tintLightHex: "#397852", tintDarkHex: "#88D1A2"),
        Account(id: "icloud", address: "ricardo@icloud.com",
                displayName: "iCloud", provider: .imap, host: "icloud",
                tintLightHex: "#298084", tintDarkHex: "#71D0D5"),
    ]

    /// Âncora fixa para os testes não dependerem do relógio.
    /// Terça, 25 de agosto de 2026, meio-dia — o "hoje" do protótipo.
    ///
    /// Sem fuso explícito, de propósito: tudo que lê esta data (o cabeçalho da
    /// agenda, os horários das mensagens) formata com `Calendar.current`. Fixá-la
    /// num fuso faria o dia e a hora renderizados variarem conforme a máquina —
    /// era esse o bug que trocava o meio-dia por 17:00 em Berlim.
    public static let today: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 8; c.day = 25
        c.hour = 12; c.minute = 0
        return Calendar(identifier: .gregorian).date(from: c)!
    }()

    /// Meio-dia em minutos desde a meia-noite, como `AgendaItem` modela horário.
    /// Literal em vez de derivado de `today`: horário de parede não deveria
    /// precisar de uma conversão que pode errar.
    public static let nowMinute: Int = 720

    private static func at(_ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(
            bySettingHour: hour, minute: minute, second: 0, of: today
        ) ?? today
    }

    /// Ontem — segunda, 24 de agosto — na mesma hora de parede.
    ///
    /// Só o `receivedAt`, que a linha usa para escrever o horário. Quem decide
    /// sob qual cabeçalho a mensagem cai é o `dayOffset`, que é `-1` e não
    /// depende de calendário nenhum.
    private static func yesterdayAt(_ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -1, to: at(hour, minute)) ?? at(hour, minute)
    }

    /// As sete mensagens do design, na ordem em que ele as escreve.
    /// Protótipo: `const MSGS` (linha 1547).
    ///
    /// Eram quatro, e nenhuma das três que faltavam era decorativa: sem elas a
    /// lista tinha um grupo só ("Hoje"), a caixa "Depois" tinha uma mensagem, e
    /// as contas `gmail` e `icloud` não apareciam com o que as justifica.
    ///
    /// Repare que `bucket` e `dayOffset` são independentes: `m6` chegou ontem e
    /// está na caixa "Hoje". A caixa é triagem, o dia é quando chegou.
    public static let messages: [Message] = [
        Message(
            id: "m1", accountID: "zoho",
            from: Contact(name: "Marina Duarte", address: "marina@clientepremium.com"),
            receivedAt: at(9, 42),
            subject: "Revisão do contrato — podemos fechar quinta?",
            snippet: "Revisei as cláusulas 4 e 7. Consigo assinar se conseguirmos uma call quinta às 15h para alinhar o escopo de suporte.",
            body: [
                "Ricardo, tudo bem?",
                "Revisei as cláusulas 4 e 7 com o jurídico. A única pendência real é o escopo de suporte — queremos deixar claro o SLA de resposta em horário comercial.",
                "Consigo assinar ainda esta semana se conseguirmos uma call na quinta às 15h para alinhar isso. Sexta já entro em viagem.",
                "Abraço, Marina",
            ],
            tags: [
                Tag(name: "Precisa resposta", tintHex: "#A8722B"),
                Tag(name: "Compromisso", tintHex: "#3F6AA1"),
            ],
            bucket: .today, isRead: false,
            summary: "Marina fecha o contrato com dois ajustes no escopo de suporte e pede uma call na quinta às 15h. Assinatura precisa sair até sexta — ela viaja depois.",
            detectedEvent: DetectedEvent(
                label: "Call de contrato · qui 27, 15:00",
                start: Calendar.current.date(byAdding: .day, value: 2, to: at(15, 0))!,
                duration: 3600
            ),
            dayOffset: 0,
            replyHints: ["Confirmar quinta 15h", "Pedir mais um dia"]
        ),
        Message(
            id: "m4", accountID: "zoho",
            from: Contact(name: "Equipe Produto", address: "produto@empresa.com"),
            receivedAt: at(8, 40),
            subject: "Notas do standup + bloqueio no deploy",
            snippet: "Deploy travado no certificado SSL do ambiente novo. Precisamos de uma decisão sua hoje.",
            body: [
                "Resumo do standup:",
                "O deploy está parado no certificado SSL do ambiente novo. Temos duas saídas: renovar o certificado atual por um ano ou migrar para o provedor gerenciado agora.",
                "A segunda custa mais, mas resolve de vez. Precisamos da sua decisão para desbloquear a release.",
            ],
            tags: [
                Tag(name: "Precisa resposta", tintHex: "#A8722B"),
                Tag(name: "Equipe", tintHex: "#3F6AA1"),
            ],
            bucket: .today, isRead: false,
            summary: "O deploy está bloqueado por um certificado SSL. Duas saídas: renovar o atual por um ano ou migrar para o provedor gerenciado. A equipe espera sua decisão hoje.",
            detectedEvent: nil,
            dayOffset: 0,
            replyHints: ["Aprovar migração", "Renovar 1 ano"]
        ),
        Message(
            id: "m6", accountID: "host",
            from: Contact(name: "Formulário do site", address: "form@meusite.com"),
            receivedAt: yesterdayAt(11, 7),
            subject: "Novo lead: consultoria para 40 pessoas",
            snippet: "Empresa de logística, 40 funcionários, quer proposta de consultoria até o fim do mês. Orçamento aprovado.",
            body: [
                "Nome: Cláudia Rocha",
                "Empresa: TransRota Logística — 40 funcionários.",
                "Mensagem: precisamos de uma proposta de consultoria em processos internos até o fim do mês. Orçamento já aprovado internamente.",
            ],
            tags: [
                Tag(name: "Lead", tintHex: "#397852"),
                Tag(name: "Prazo", tintHex: "#A8722B"),
            ],
            bucket: .today, isRead: false,
            summary: "Lead qualificado: logística, 40 pessoas, proposta pedida até o fim do mês com orçamento já aprovado. Vale reservar um bloco de foco antes de responder.",
            detectedEvent: DetectedEvent(
                label: "Bloco de foco · qua 26, 09:00",
                // Quarta 26, 09:00–11:00 — o `Bloco: proposta` de `TIMES`
                // ([540, 660]), que é o mesmo bloco que a grade da semana mostra.
                start: Calendar.current.date(byAdding: .day, value: 1, to: at(9, 0))!,
                duration: 7200
            ),
            dayOffset: -1,
            replyHints: ["Agendar diagnóstico", "Enviar proposta padrão"]
        ),
        Message(
            id: "m2", accountID: "host",
            from: Contact(name: "Hostinger", address: "billing@hostinger.com"),
            receivedAt: at(8, 15),
            subject: "Renovação do domínio meusite.com em 12 dias",
            snippet: "Seu domínio expira em 06/09/2026. A renovação automática está desativada para este item.",
            body: [
                "Olá,",
                "O domínio meusite.com está registrado até 06 de setembro de 2026. A renovação automática está desativada para este item.",
                "Renove pelo painel para evitar a suspensão do DNS.",
            ],
            tags: [Tag(name: "Prazo", tintHex: "#A8722B")],
            bucket: .later, isRead: false,
            summary: "meusite.com expira em 06/09 e a renovação automática está desligada. Ação de dois minutos, mas com data dura.",
            detectedEvent: DetectedEvent(
                label: "Renovar domínio · 04 set, 10:00",
                // 10 dias depois de 25/08 é 04/09; 10:00–10:30 vem de
                // `TIMES['Renovar domínio'] = [600, 630]`.
                start: Calendar.current.date(byAdding: .day, value: 10, to: at(10, 0))!,
                duration: 1800
            ),
            dayOffset: 0,
            replyHints: ["Criar lembrete"]
        ),
        Message(
            id: "m3", accountID: "gmail",
            from: Contact(name: "Bruno Sato", address: "bruno.sato@gmail.com"),
            receivedAt: yesterdayAt(19, 22),
            subject: "Fotos da viagem + aquele orçamento",
            snippet: "Mandei as fotos no link. E o orçamento do freela que te falei — sem pressa, olha quando der.",
            body: [
                "Fala Ricardo!",
                "Subi as fotos da viagem naquele link do drive, dá uma olhada quando puder.",
                "E o orçamento do freela que comentei está anexo — sem pressa, só queria sua opinião sobre o valor.",
            ],
            tags: [Tag(name: "Pessoal", tintHex: "#725B9A")],
            bucket: .later, isRead: false,
            summary: "Duas coisas soltas: link de fotos (nenhuma ação) e um orçamento de freela sem prazo.",
            detectedEvent: nil,
            dayOffset: -1,
            replyHints: ["Responder depois"]
        ),
        Message(
            id: "m7", accountID: "gmail",
            from: Contact(name: "Newsletter Ofício", address: "oficio@substack.com"),
            receivedAt: yesterdayAt(6, 0),
            subject: "Edição 118 — o custo real de uma reunião",
            snippet: "Três leituras da semana e um cálculo simples de quanto custa a agenda cheia.",
            body: [
                "Boletim da semana com três leituras e um cálculo sobre o custo de reuniões recorrentes.",
            ],
            // `BADGE['Leitura'] = var(--ink3)`: sem cor própria, cai no ink3 do tema.
            tags: [Tag(name: "Leitura", tintHex: nil)],
            bucket: .later, isRead: false,
            summary: "Newsletter. Agrupada em Leitura, sem ação — cai no digest das 18h.",
            detectedEvent: nil,
            dayOffset: -1,
            replyHints: []
        ),
        Message(
            id: "m5", accountID: "icloud",
            from: Contact(name: "Apple", address: "no-reply@apple.com"),
            receivedAt: yesterdayAt(14, 20),
            subject: "Seu recibo — assinatura anual",
            snippet: "Recibo de compra disponível. Nenhuma ação necessária.",
            body: ["Recibo da sua assinatura anual. Nenhuma ação necessária."],
            tags: [Tag(name: "Recibo", tintHex: nil)],  // `BADGE['Recibo'] = var(--ink3)`
            bucket: .archived, isRead: false,
            summary: "Recibo sem ação, arquivado automaticamente como registro financeiro.",
            detectedEvent: nil,
            dayOffset: -1,
            replyHints: []
        ),
    ]

    /// A trilha de "Terça, 25 de agosto" do protótipo, em minutos desde a
    /// meia-noite. Todos com `dayOffset` 0: é o dia de `today`.
    ///
    /// Esta é a **única** definição da terça. A grade da semana não tem uma
    /// segunda cópia dela: `week` inclui estes mesmos itens.
    public static let agenda: [AgendaItem] = [
        AgendaItem(id: "e1", title: "Standup produto",
                   startMinute: 570, endMinute: 600, accountID: "zoho"),
        AgendaItem(id: "e2", title: "1:1 Marina Duarte",
                   startMinute: 660, endMinute: 705, accountID: "zoho"),
        AgendaItem(id: "e3", title: "Almoço — bloqueado",
                   startMinute: 750, endMinute: 810, accountID: "icloud"),
        AgendaItem(id: "e4", title: "Revisão do contrato",
                   startMinute: 840, endMinute: 900, accountID: "zoho"),
        AgendaItem(id: "e5", title: "Foco: proposta TransRota",
                   startMinute: 990, endMinute: 1080, accountID: "host"),
    ]

    /// A semana de segunda 24 a domingo 30 de agosto, ancorada em `today`.
    /// Protótipo: `WEEK` (linha 1625), com uma correção deliberada.
    ///
    /// **A terça sai de `agenda`, não do `WEEK`.** O protótipo se contradiz no
    /// dia 25: `RAIL` lista cinco blocos e `WEEK` lista três, com títulos
    /// encurtados. Onde ele tem duas respostas, "o protótipo vence" não decide,
    /// e o critério passa a ser o produto: a mesma terça não pode mostrar
    /// coisas diferentes na trilha e na grade, no mesmo app, na mesma sessão.
    /// Os títulos curtos do `WEEK` não são outro dado — são o mesmo
    /// compromisso com rótulo menor, porque a coluna é estreita. Isso se
    /// resolve ao desenhar (uma linha, com reticências), não guardando dois
    /// títulos. Os outros seis dias vêm do `WEEK` sem alteração.
    ///
    /// Sábado não tem compromisso, como no protótipo — a coluna vazia é parte
    /// do desenho, não um dado faltando.
    public static let week: [AgendaItem] = (agenda + [
        // segunda, 24
        AgendaItem(id: "w1", title: "Standup",
                   startMinute: 570, endMinute: 600, accountID: "zoho", dayOffset: -1),
        AgendaItem(id: "w2", title: "Retro do sprint",
                   startMinute: 900, endMinute: 960, accountID: "zoho", dayOffset: -1),
        // quarta, 26
        AgendaItem(id: "w3", title: "Bloco: proposta",
                   startMinute: 540, endMinute: 660, accountID: "host", dayOffset: 1),
        AgendaItem(id: "w4", title: "Standup",
                   startMinute: 660, endMinute: 690, accountID: "zoho", dayOffset: 1),
        // quinta, 27
        AgendaItem(id: "w5", title: "Standup",
                   startMinute: 570, endMinute: 600, accountID: "zoho", dayOffset: 2),
        AgendaItem(id: "w6", title: "Call do contrato",
                   startMinute: 900, endMinute: 960, accountID: "zoho", dayOffset: 2),
        // sexta, 28
        AgendaItem(id: "w7", title: "Revisão semanal",
                   startMinute: 960, endMinute: 1020, accountID: "icloud", dayOffset: 3),
        // sábado, 29 — sem compromisso
        // domingo, 30
        //
        // O protótipo escreve "Planejar a semana" no `WEEK` e "Planejar semana"
        // em `TIMES`/`EV_META`. Vale a segunda: é a que tem metadados, e é ela
        // que faz a janela 04 abrir com conteúdo em vez do padrão genérico.
        AgendaItem(id: "w8", title: "Planejar semana",
                   startMinute: 1140, endMinute: 1200, accountID: "icloud", dayOffset: 5),
    ]).sorted { ($0.startMinute, $0.dayOffset, $0.id) < ($1.startMinute, $1.dayOffset, $1.id) }

    // MARK: - O mês

    /// Os horários de cada título recorrente. Protótipo: `TIMES` (linha 1766).
    ///
    /// O `MONTH` do protótipo guarda só título e conta em cada célula, e o
    /// horário vem daqui — é isso que faz "Standup" ser 09:30 nos vinte e tantos
    /// dias em que ele aparece sem repetir o par em cada um.
    private static let recurringTimes: [String: (start: Int, end: Int, account: String)] = [
        "Standup": (570, 600, "zoho"),
        "Kickoff cliente": (840, 900, "zoho"),
        "Auditoria LGPD": (600, 720, "host"),
        "Proposta TransRota": (840, 960, "host"),
        "Revisão semanal": (960, 1020, "icloud"),
        "Planejar semana": (1140, 1200, "icloud"),
        "Renovar domínio": (600, 630, "host"),
    ]

    /// Os dias do mês **fora** da semana de `week`, em deslocamento a partir de
    /// `today`. Protótipo: `MONTH` (linha 1637), sem a linha da semana atual.
    ///
    /// A linha 4 do `MONTH` — segunda 24 a domingo 30 — não está aqui de
    /// propósito: ela é `week`, e `week` já resolveu a contradição documentada
    /// entre `RAIL` e `WEEK` na terça. Repeti-la aqui criaria a **terceira**
    /// versão do dia 25, que é exatamente o defeito que aquela decisão evitou.
    private static let outsideWeek: [(dayOffset: Int, titles: [String])] = [
        // Julho: as pontas cinzas da primeira linha.
        (-29, ["Standup"]), (-28, ["Standup"]), (-27, ["Standup"]), (-26, ["Standup"]),
        (-25, []), (-24, []), (-23, []),
        // Semana de 3 a 9 de agosto.
        (-22, ["Standup"]), (-21, ["Standup"]),
        (-20, ["Standup", "Kickoff cliente"]), (-19, ["Standup"]),
        (-18, ["Revisão semanal"]), (-17, []), (-16, []),
        // 10 a 16.
        (-15, ["Standup"]), (-14, ["Standup", "Auditoria LGPD"]),
        (-13, ["Standup"]), (-12, ["Standup"]),
        (-11, ["Revisão semanal"]), (-10, []), (-9, []),
        // 17 a 23.
        (-8, ["Standup"]), (-7, ["Standup"]),
        (-6, ["Standup", "Proposta TransRota"]), (-5, ["Standup"]),
        (-4, ["Revisão semanal"]), (-3, []), (-2, ["Planejar semana"]),
        // 31 de agosto e a ponta de setembro.
        (6, ["Standup"]), (7, []), (8, []), (9, []),
        (10, ["Renovar domínio"]), (11, []), (12, []),
    ]

    /// Agosto inteiro, das seis linhas da grade: `week` mais os outros 35 dias.
    ///
    /// É esta lista que a `InMemoryMailSource` serve, e não `week`, porque a
    /// visão Mês e o seletor de data de 244pt precisam de mês inteiro para
    /// terem o que mostrar. As outras visões não notam a diferença: a trilha
    /// diária pede `dayOffset == 0` e a grade da semana pede sete
    /// deslocamentos — o que sobra simplesmente não é consultado.
    public static let month: [AgendaItem] = (week + outsideWeek.flatMap { day in
        day.titles.enumerated().compactMap { index, title -> AgendaItem? in
            guard let time = recurringTimes[title] else { return nil }
            return AgendaItem(
                // O deslocamento negativo entra no id com o sinal, o que já o
                // torna único: "m-29.0" nunca colide com "m6.0".
                id: "m\(day.dayOffset).\(index)",
                title: title,
                startMinute: time.start, endMinute: time.end,
                accountID: time.account, dayOffset: day.dayOffset
            )
        }
    }).sorted { ($0.startMinute, $0.dayOffset, $0.id) < ($1.startMinute, $1.dayOffset, $1.id) }

    /// O catálogo por trás dos campos Para/Cc/Cco. Protótipo: `CONTACTS`.
    public static let contacts: [DirectoryContact] = [
        DirectoryContact(name: "Marina Duarte", address: "marina@clientepremium.com",
                         org: "Cliente Premium", frequency: 42),
        DirectoryContact(name: "Equipe Produto", address: "produto@empresa.com",
                         org: "Interno", frequency: 38),
        DirectoryContact(name: "Bruno Sato", address: "bruno.sato@gmail.com",
                         org: "Pessoal", frequency: 27),
        DirectoryContact(name: "Cláudia Rocha", address: "claudia@transrota.com.br",
                         org: "TransRota", frequency: 19),
        DirectoryContact(name: "Jurídico", address: "juridico@empresa.com",
                         org: "Interno", frequency: 16),
        DirectoryContact(name: "Financeiro", address: "financeiro@empresa.com",
                         org: "Interno", frequency: 12),
        DirectoryContact(name: "Pedro Alencar", address: "pedro@empresa.com",
                         org: "Interno", frequency: 11),
        DirectoryContact(name: "Suporte Hostinger", address: "suporte@hostinger.com",
                         org: "Fornecedor", frequency: 7),
        DirectoryContact(name: "Ana Beatriz", address: "ana.beatriz@transrota.com.br",
                         org: "TransRota", frequency: 6),
        DirectoryContact(name: "Compliance", address: "compliance@empresa.com",
                         org: "Interno", frequency: 5),
    ]

    /// Arquivos de exemplo do botão de anexo. Protótipo: `FILES`.
    public static let attachments: [(name: String, size: String)] = [
        ("proposta-transrota.pdf", "240 KB"),
        ("contrato-v4.docx", "86 KB"),
        ("diagnostico-processos.xlsx", "312 KB"),
    ]

    private static func person(
        _ name: String, _ address: String, _ role: String, _ status: EventPerson.Status
    ) -> EventPerson {
        EventPerson(name: name, address: address, role: role, status: status)
    }

    /// Protótipo: `EV_DEFAULT` — o que um compromisso sem metadados mostra.
    public static let eventDefault = EventDetail(
        place: "Sem local definido", link: nil,
        organizer: person("Ricardo Gomes", "ricardo@empresa.com", "organizador", .yes),
        people: [], note: "Criado manualmente na agenda.",
        recurrence: "Evento único", notice: "Alerta 10 min antes",
        agenda: [], thread: []
    )

    /// Protótipo: `EV_META`, já com os apelidos de título que ele registra logo
    /// abaixo da tabela (`EV_META['Standup produto'] = EV_META['Standup']`…).
    public static let eventDetails: [String: EventDetail] = {
        let standup = EventDetail(
            place: "Google Meet · sala do time",
            link: "https://meet.google.com/kzq-mfrp-tdy",
            organizer: person("Equipe Produto", "produto@empresa.com", "organizador", .yes),
            people: [
                person("Ricardo Gomes", "ricardo@empresa.com", "você", .yes),
                person("Pedro Alencar", "pedro@empresa.com", "obrigatório", .yes),
                person("Ana Beatriz", "ana.beatriz@transrota.com.br", "opcional", .maybe),
            ],
            note: "Série recorrente criada pela Equipe Produto.",
            recurrence: "Toda seg–qui, 09:30", notice: "Alerta 5 min antes",
            agenda: [
                "O que travou desde ontem",
                "Decisões que precisam de você",
                "Riscos da release",
            ],
            thread: [
                EventThreadEntry(when: "24 ago · 18:04", who: "Equipe Produto",
                                 what: "Notas do standup + bloqueio no deploy", kind: .email),
                EventThreadEntry(when: "18 ago", who: "Equipe Produto",
                                 what: "Série recorrente criada", kind: .system),
            ]
        )
        let oneOnOne = EventDetail(
            place: "Zoom · sala pessoal",
            link: "https://zoom.us/j/9182736450?pwd=okamiuni",
            organizer: person("Ricardo Gomes", "ricardo@empresa.com", "organizador", .yes),
            people: [person("Marina Duarte", "marina@clientepremium.com", "obrigatório", .yes)],
            note: "Criado a partir do email \"Revisão do contrato — podemos fechar quinta?\".",
            recurrence: "Quinzenal, terças", notice: "Alerta 15 min antes",
            agenda: ["Escopo de suporte e SLA", "Cláusulas 4 e 7", "Data de assinatura"],
            thread: [
                EventThreadEntry(when: "25 ago · 09:42", who: "Marina Duarte",
                                 what: "Revisão do contrato — podemos fechar quinta?", kind: .email),
                EventThreadEntry(when: "25 ago · 09:44", who: "OkamiUNI",
                                 what: "Compromisso detectado no texto e adicionado", kind: .ai),
            ]
        )
        let contractReview = EventDetail(
            place: "Zoom · sala pessoal",
            link: "https://zoom.us/j/9182736450?pwd=okamiuni",
            organizer: person("Marina Duarte", "marina@clientepremium.com", "organizador", .yes),
            people: [
                person("Ricardo Gomes", "ricardo@empresa.com", "você", .yes),
                person("Jurídico", "juridico@empresa.com", "obrigatório", .maybe),
            ],
            note: "Assinatura precisa sair até sexta — Marina viaja depois.",
            recurrence: "Evento único", notice: "Alerta 15 min antes",
            agenda: ["Fechar redação do SLA", "Confirmar prazo de assinatura"],
            thread: [
                EventThreadEntry(when: "25 ago · 09:42", who: "Marina Duarte",
                                 what: "Revisão do contrato — podemos fechar quinta?", kind: .email),
                EventThreadEntry(when: "25 ago · 10:10", who: "Você",
                                 what: "Aceitou o convite", kind: .system),
            ]
        )
        let focus = EventDetail(
            place: "Bloco de foco · notificações silenciadas", link: nil,
            organizer: person("Ricardo Gomes", "ricardo@empresa.com", "organizador", .yes),
            people: [], note: "Reservado para escrever a proposta da TransRota.",
            recurrence: "Evento único", notice: "Sem alerta",
            agenda: ["Escopo em 1 página", "Investimento e prazos"],
            thread: [
                EventThreadEntry(when: "24 ago · 11:07", who: "Formulário do site",
                                 what: "Novo lead: consultoria para 40 pessoas", kind: .email),
                EventThreadEntry(when: "24 ago · 11:09", who: "OkamiUNI",
                                 what: "Bloco de foco criado antes do prazo do lead", kind: .ai),
            ]
        )
        let weekly = EventDetail(
            place: "Sozinho · caderno", link: nil,
            organizer: person("Ricardo Gomes", "ricardo@empresa.com", "organizador", .yes),
            people: [], note: "Fechamento da semana.",
            recurrence: "Toda sexta", notice: "Alerta 10 min antes",
            agenda: ["Caixa em zero", "Semana seguinte planejada"], thread: []
        )

        return [
            "Standup": standup,
            "Standup produto": standup,
            "1:1 Marina": oneOnOne,
            "1:1 Marina Duarte": oneOnOne,
            "Revisão do contrato": contractReview,
            "Foco: proposta": focus,
            "Foco: proposta TransRota": focus,
            "Bloco: proposta": focus,
            "Proposta TransRota": focus,
            "Revisão semanal": weekly,
            "Planejar semana": weekly,
        ]
    }()

    /// Protótipo: `Object.assign({}, EV_DEFAULT, EV_META[title] || {})` —
    /// título sem metadados cai no padrão em vez de sumir da tela.
    public static func eventDetail(for title: String) -> EventDetail {
        eventDetails[title] ?? eventDefault
    }

    /// Itens pendentes detectados nos emails, para a seção "Vindo do email" da trilha.
    public static let pendingItems: [PendingItem] = [
        PendingItem(id: "p1", text: "Confirmar call de contrato com Marina — quinta 15h", accountID: "zoho"),
        PendingItem(id: "p2", text: "Renovar domínio meusite.com antes de 06/09", accountID: "host"),
    ]
}

/// Um item pendente detectado num email, para agendamento ou follow-up.
public struct PendingItem: Sendable, Hashable, Identifiable {
    public let id: String
    public let text: String
    public let accountID: String

    public init(id: String, text: String, accountID: String) {
        self.id = id
        self.text = text
        self.accountID = accountID
    }
}
