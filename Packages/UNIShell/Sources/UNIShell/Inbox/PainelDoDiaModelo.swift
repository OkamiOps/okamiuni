import Foundation
import UNICore

/// O que o painel 11 escreve, decidido **fora** da `View`.
///
/// A regra é a de sempre: nenhuma conta de horário, de contagem ou de palavra
/// mora numa `View`. O que é regra de produto — quem cabe na linha do tempo,
/// quando um prazo é urgente, quando um valor pode aparecer — está em UNICore
/// (`PlanoDoDia`, `DinheiroNoTexto`, `DayPlan`); o que sobra aqui é a costura
/// entre o `DayPlan` e o desenho.
struct PainelDoDiaModelo {

    /// Uma pessoa esperando: o azulejo da primeira coluna.
    struct Espera: Identifiable {
        let id: String
        let accountID: String
        let nome: String
        let iniciais: String
        let numero: String
        let sufixo: String
        let palavra: String
        let alerta: Bool
        let porque: String
        let temRascunho: Bool
        /// A intenção é de gente (`request`, `scheduling`, `lead`) — só assim
        /// o azulejo pode ganhar o botão primário.
        let pedeGente: Bool
    }

    /// Uma promessa sua: o azulejo de "Você deve".
    struct Promessa: Identifiable {
        let item: PendingItem
        let titulo: String
        let iniciais: String
        /// "hoje", "sex", "3d" — ou "—" quando o email não disse quando.
        let quando: String
        let alerta: Bool
        let porque: String
        /// O minuto da próxima folga, quando existe uma.
        let folga: Int?
        let rotuloDaReserva: String?

        var id: String { item.id }
    }

    /// Uma linha de "Dinheiro e prazos".
    struct LinhaDeDinheiro: Identifiable {
        let id: String
        let titulo: String
        /// "vence 05/09 · vantion", em versalete.
        let quando: String
        let urgente: Bool
        /// Só quando o texto afirma um valor. `nil` = a linha mostra o prazo,
        /// e nada mais.
        let valor: String?
        let aReceber: Bool
        let quantia: DinheiroNoTexto.Valor?
    }

    /// Por que não há nenhuma resposta pronta. `nil` quando há.
    enum MotivoSemProntas: Equatable {
        /// A rota remota está configurada, mas a análise automática está
        /// desligada — o portão do opt-in barra a fila do rascunho antecipado.
        case precisaDoOptIn(destino: String)
        /// O motor não está disponível nesta máquina, ou pede entrar.
        case motorIndisponivel(destino: String)
        /// Nada barra: a fila simplesmente ainda não escreveu.
        case aindaNaoEscreveu

        /// A legenda do cabeçalho de "Esperando você".
        var legenda: String {
            switch self {
            case let .precisaDoOptIn(destino):
                L10n.tr("Respostas prontas precisam da análise automática pelo \(destino) · Ativar")
            case let .motorIndisponivel(destino):
                L10n.tr("\(destino) indisponível · Entrar")
            // Sem "· Gerar as prontas": o botão está logo ao lado, e a
            // legenda repetindo o rótulo dele lia como duas ações.
            case .aindaNaoEscreveu:
                L10n.tr("Nenhuma resposta pronta ainda")
            }
        }
    }

    let espera: [Espera]
    let promessas: [Promessa]
    let dinheiro: [LinhaDeDinheiro]
    let blocos: [PlanoDoDia.Bloco]
    /// Os blocos que "Aceitar o plano" cria.
    let propostos: [PlanoDoDia.Bloco]
    let contas: [String: (total: Int, pedeVoce: Bool)]
    let legendaDaEspera: String
    /// O motivo de não haver prontas — `nil` quando há.
    let motivoSemProntas: MotivoSemProntas?
    let legendaDosCompromissos: String
    let foraDaLista: String
    let progresso: Double
    let progressoEscrito: String
    let composicao: String
    let emJogo: [(rotulo: String, valor: String, aReceber: Bool)]

    var legendaDoPlano: String {
        let n = propostos.count
        let blocos = n == 1 ? L10n.tr("1 bloco proposto") : L10n.tr("\(n) blocos propostos")
        return L10n.tr("agenda + prazos + o que você prometeu · \(blocos)")
    }

    static func reciboDoPlano(_ count: Int) -> String {
        count == 1 ? L10n.tr("1 bloco no seu dia") : L10n.tr("\(count) blocos no seu dia")
    }

    // MARK: - A costura

    init(
        plan: DayPlan,
        drafts: [String: ReadyDraft],
        pending: [PendingItem],
        agenda: [AgendaItem],
        messages: [Message],
        today: Date,
        nowMinute: Int,
        /// Os endereços das contas do dono — ninguém é lead de si próprio.
        myAddresses: Set<String> = [],
        /// Por que não há prontas, quando não há. A tela sabe da rota; o
        /// modelo só escolhe a frase.
        motivoSemProntas: MotivoSemProntas = .aindaNaoEscreveu,
        calendar: Calendar = .current
    ) {
        let linhas = plan.sections
            .filter { $0.kind == .waitingOnYou || $0.kind == .lead }
            .flatMap(\.rows)

        // Quem espera há mais tempo primeiro — e o prazo de hoje na frente de
        // todos, porque ele é o único que acaba.
        let ordenadas = linhas.sorted { a, b in
            let pa = Self.venceHoje(a, today: today, calendar: calendar)
            let pb = Self.venceHoje(b, today: today, calendar: calendar)
            if pa != pb { return pa }
            return a.item.message.receivedAt < b.item.message.receivedAt
        }

        // As conversas em que eu já falei: um lead não é lead depois de eu ter
        // respondido. Sai do que a Caixa já tem em memória — o `bucket` é o
        // mesmo que a lista de enviados lê.
        let enviadasPorMim = Set(
            messages.filter { $0.bucket == .sent }.map(\.conversationKey)
        )

        espera = ordenadas.compactMap { row -> Espera? in
            let mensagem = row.item.message
            let nome = DashboardFocus.personName(
                displayName: mensagem.from.name, address: mensagem.from.address
            ) ?? mensagem.from.name
            // Nunca negativo: um email que chegou "amanhã" (relógio do
            // harness, fuso torto) não espera há menos zero dias.
            let dias = max(0, calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: mensagem.receivedAt),
                to: calendar.startOfDay(for: today)
            ).day ?? 0)
            let prazoHoje = Self.venceHoje(row, today: today, calendar: calendar)
            // A etiqueta é decidida em UNICore, e antes de qualquer palpite do
            // modelo: "lead novo" exige as quatro condições, e máquina não vira
            // azulejo nenhum.
            let etiqueta = EtiquetaDoAzulejo.decidir(
                message: mensagem,
                marks: mensagem.effectiveBulkMarks,
                triage: mensagem.triage,
                hasSentInThread: enviadasPorMim.contains(mensagem.conversationKey),
                myAddresses: myAddresses,
                today: today,
                calendar: calendar
            )

            // Máquina não espera você: sem etiqueta, o azulejo não existe e a
            // mensagem cai no excedente do rodapé.
            guard etiqueta != nil else { return nil }

            let numero: String
            let sufixo: String
            let palavra: String
            if prazoHoje, let prazo = mensagem.triage?.deadline?.date {
                let horas = max(
                    0, calendar.dateComponents([.hour], from: today, to: prazo).hour ?? 0
                )
                numero = "\(horas)"
                sufixo = "h"
                palavra = L10n.tr("prazo hoje")
            } else {
                numero = "\(dias)"
                sufixo = "d"
                palavra = (etiqueta ?? .esperando).palavra
            }

            return Espera(
                id: row.id,
                accountID: mensagem.accountID,
                nome: nome,
                iniciais: Self.iniciais(de: nome),
                numero: numero,
                sufixo: sufixo,
                palavra: palavra,
                alerta: prazoHoje || dias >= 3,
                porque: row.why,
                temRascunho: drafts[row.id] != nil,
                pedeGente: DayPlan.pedeGente(mensagem.triage)
            )
        }

        // As promessas: o texto é o título, e o prazo é o que o email disse.
        // O horário sai da linha do tempo mais abaixo — é lá que uma promessa
        // deixa de cair em cima da outra.
        let folgasLivres = FreeSlots.next(
            days: 1, minMinutes: PlanoDoDia.minutosDaPromessa, agenda: agenda,
            now: today, nowMinute: nowMinute, calendar: calendar
        ).filter { $0.day == 0 }

        let esboços: [(item: PendingItem, titulo: String, quando: String, alerta: Bool)] =
            pending.map { item in
                let titulo = Self.titulo(de: item.text)
                let quando: String
                var alerta = false
                if let vence = item.dueDate {
                    if calendar.isDate(vence, inSameDayAs: today) {
                        quando = L10n.tr("hoje")
                        alerta = true
                    } else if vence < today {
                        quando = L10n.tr("venceu")
                        alerta = true
                    } else {
                        let dias = calendar.dateComponents(
                            [.day],
                            from: calendar.startOfDay(for: today),
                            to: calendar.startOfDay(for: vence)
                        ).day ?? 0
                        quando = dias <= 6
                            ? String(
                                DayPlan.weekdayName(calendar.component(.weekday, from: vence))
                                    .prefix(3)
                            )
                            : "\(dias)d"
                    }
                } else {
                    quando = "—"
                }
                return (item, titulo, quando, alerta)
            }

        // Dinheiro e prazos: o que o `MessageTriage` afirmou, com o valor só
        // quando o texto o escreve.
        dinheiro = plan.sections.flatMap(\.rows).compactMap { row -> LinhaDeDinheiro? in
            let mensagem = row.item.message
            guard let prazo = mensagem.triage?.deadline else { return nil }
            let cheia = messages.first { $0.id == row.id } ?? mensagem
            let quantia = DinheiroNoTexto.primeiro(
                em: [prazo.evidence, mensagem.subject, mensagem.snippet] + cheia.body
            )
            let horas = calendar.dateComponents(
                [.hour], from: today, to: prazo.date
            ).hour ?? .max
            let quando = calendar.isDate(prazo.date, inSameDayAs: today)
                ? L10n.tr("vence hoje · \(mensagem.accountID)")
                : "\(Self.dataCurta(prazo.date)) · \(mensagem.accountID)"
            return LinhaDeDinheiro(
                id: row.id,
                titulo: Self.titulo(de: mensagem.subject),
                quando: quando,
                urgente: horas <= 24,
                valor: quantia?.texto,
                // Quem pede a **sua** resposta está do lado de fora esperando
                // por você; robô e lista cobram. É o que se pode afirmar sem
                // ler os enviados — a leitura de verdade é a entrega 2.
                aReceber: DayPlan.pedeGente(mensagem.triage),
                quantia: quantia
            )
        }

        // A linha do tempo.
        let prazosDeHoje = dinheiro.compactMap { linha -> PlanoDoDia.Prazo? in
            guard let mensagem = plan.sections.flatMap(\.rows)
                .first(where: { $0.id == linha.id })?.item.message,
                let prazo = mensagem.triage?.deadline,
                calendar.isDate(prazo.date, inSameDayAs: today)
            else { return nil }
            let partes = calendar.dateComponents([.hour, .minute], from: prazo.date)
            // "Prazo Jayden": o nome de quem cobra cabe no bloco; o assunto
            // inteiro não cabe, e um bloco que só escreve "Prazo …" não diz
            // nada.
            return PlanoDoDia.Prazo(
                id: linha.id,
                title: L10n.tr("Prazo \(DashboardDay.firstName(of: mensagem.from))"),
                minute: (partes.hour ?? 0) * 60 + (partes.minute ?? 0)
            )
        }
        let promessasDeHoje = esboços
            .filter(\.alerta)
            .map { esboço in
                PlanoDoDia.Promessa(
                    id: esboço.item.id, title: esboço.titulo,
                    dueMinute: esboço.item.dueDate.map { vence in
                        let partes = calendar.dateComponents([.hour, .minute], from: vence)
                        return (partes.hour ?? 0) * 60 + (partes.minute ?? 0)
                    }
                )
            }
        let linhaDoTempo = PlanoDoDia.make(
            agenda: agenda,
            replyBlock: plan.replyBlock,
            replyTitle: DashboardMetrics.replyBlockTitle(
                names: DashboardDay.planNames(for: plan)
            ),
            promessas: promessasDeHoje,
            prazos: prazosDeHoje,
            now: today,
            nowMinute: nowMinute,
            calendar: calendar
        )
        blocos = linhaDoTempo
        propostos = linhaDoTempo.filter { $0.tipo == .proposto }

        // Agora sim: cada promessa herda o horário que a linha do tempo lhe
        // deu, e "Reservar 13:00" nunca aparece duas vezes.
        promessas = esboços.map { esboço in
            // A promessa que a linha do tempo já colocou usa o horário dela;
            // a que não vence hoje pega a primeira folga **depois** do que já
            // foi proposto — senão duas reservas cairiam na mesma hora.
            let ocupadoAte = linhaDoTempo
                .filter { $0.tipo == .proposto }
                .map { $0.startMinute + $0.minutes }
                .max() ?? 0
            let depois = folgasLivres.first {
                $0.end - max($0.start, ocupadoAte) >= PlanoDoDia.minutosDaPromessa
            }
            let folga = linhaDoTempo.first { $0.id == esboço.item.id }?.startMinute
                ?? depois.map { max($0.start, ocupadoAte) }
                ?? folgasLivres.first?.start
            return Promessa(
                item: esboço.item,
                titulo: esboço.titulo,
                iniciais: Self.iniciais(de: esboço.titulo),
                quando: esboço.quando,
                alerta: esboço.alerta,
                porque: esboço.item.text,
                folga: folga,
                rotuloDaReserva: folga.map { L10n.tr("Reservar \(MinuteFormat.clock($0))") }
            )
        }

        // O semáforo por conta: quantos itens ela tem na tela, e se algum
        // deles pede você.
        var porConta: [String: (total: Int, pedeVoce: Bool)] = [:]
        for item in espera {
            var estado = porConta[item.accountID] ?? (0, false)
            estado.total += 1
            estado.pedeVoce = true
            porConta[item.accountID] = estado
        }
        for promessa in promessas {
            var estado = porConta[promessa.item.accountID] ?? (0, false)
            estado.total += 1
            if promessa.alerta { estado.pedeVoce = true }
            porConta[promessa.item.accountID] = estado
        }
        contas = porConta

        // Zero prontas nunca é só "nenhuma resposta pronta": essa frase deixa a
        // pessoa achando que a IA não está fazendo nada. O cabeçalho diz o
        // motivo — o opt-in desligado, o motor fora do ar — e oferece a porta.
        let prontas = espera.filter(\.temRascunho).count
        legendaDaEspera = prontas == 0
            ? motivoSemProntas.legenda
            : (prontas == 1 ? L10n.tr("1 resposta pronta") : L10n.tr("\(prontas) respostas prontas"))
        self.motivoSemProntas = prontas == 0 ? motivoSemProntas : nil
        // "0 promessas" soa como "a IA olhou e não achou nada". Ela não olhou:
        // ler o que EU prometi nos enviados é a próxima entrega, e o cabeçalho
        // diz isso em vez de fingir um resultado.
        legendaDosCompromissos = switch promessas.count {
        case 0: L10n.tr("lido dos seus enviados · na próxima versão")
        case 1: L10n.tr("1 promessa")
        default: L10n.tr("\(promessas.count) promessas")
        }

        let disparos = plan.counts[.broadcasts] ?? 0
        let newsletters = plan.counts[.newsletters] ?? 0
        foraDaLista = L10n.tr("\(disparos) \(disparos == 1 ? L10n.tr("disparo") : L10n.tr("disparos")) e ")
            + L10n.tr("\(newsletters) \(newsletters == 1 ? L10n.tr("newsletter ficou") : L10n.tr("newsletters ficaram")) de fora")

        // A barra: o dia feito e o dia inteiro.
        let reuniõesDeHoje = agenda.filter { $0.dayOffset == 0 && !$0.isCancelled }
        let reuniõesPassadas = reuniõesDeHoje.filter { $0.endMinute <= nowMinute }.count
        let resolvidasHoje = messages.filter { mensagem in
            (mensagem.bucket == .sent || mensagem.bucket == .archived)
                && calendar.isDate(mensagem.receivedAt, inSameDayAs: today)
        }.count
        let feitos = reuniõesPassadas + resolvidasHoje
        let total = feitos + espera.count + promessas.count
            + (reuniõesDeHoje.count - reuniõesPassadas)
        progresso = total > 0 ? min(1, Double(feitos) / Double(total)) : 0
        progressoEscrito = L10n.tr("\(feitos) de \(total)")
        composicao = Self.composicao(
            respostas: espera.count, promessas: promessas.count,
            reuniões: reuniõesDeHoje.count
        )

        // Em jogo: só o que tem valor lido do texto.
        emJogo = Self.emJogo(dinheiro)
    }

    // MARK: - Peças

    private static func venceHoje(
        _ row: DayPlan.Row, today: Date, calendar: Calendar
    ) -> Bool {
        guard let prazo = row.item.message.triage?.deadline?.date else { return false }
        return calendar.isDate(prazo, inSameDayAs: today)
    }

    /// "JW" de "Jack Whitmore"; "PM" de "Proposta Marina".
    static func iniciais(de nome: String) -> String {
        let letras = nome.split(separator: " ").prefix(2).compactMap(\.first)
        let texto = String(letras).uppercased()
        return texto.isEmpty ? "?" : texto
    }

    /// O título curto: a primeira oração, sem o que vem depois do travessão.
    static func titulo(de texto: String) -> String {
        let cortes = ["—", " - ", ":"]
        var curto = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        for corte in cortes {
            if let faixa = curto.range(of: corte) {
                curto = String(curto[..<faixa.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return curto.count > 34 ? String(curto.prefix(33)) + "…" : curto
    }

    /// "vence 05/09", em pt-BR fixo — `Locale.current` mentiria no bundle de
    /// teste (ver a nota em `Render.bitmap`).
    static func dataCurta(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.setLocalizedDateFormatFromTemplate("ddMM")
        return L10n.tr("vence \(formatter.string(from: date))")
    }

    /// "3 respostas · 2 promessas · 2 reuniões".
    static func composicao(respostas: Int, promessas: Int, reuniões: Int) -> String {
        var partes: [String] = []
        if respostas > 0 {
            partes.append("\(respostas) \(respostas == 1 ? L10n.tr("resposta") : L10n.tr("respostas"))")
        }
        if promessas > 0 {
            partes.append("\(promessas) \(promessas == 1 ? L10n.tr("promessa") : L10n.tr("promessas"))")
        }
        if reuniões > 0 {
            partes.append("\(reuniões) \(reuniões == 1 ? L10n.tr("reunião") : L10n.tr("reuniões"))")
        }
        return partes.joined(separator: " · ")
    }

    /// "a receber R$ 4.200" e "a pagar R$ 89" — só o que tem valor, e só
    /// somando o que está na mesma moeda.
    static func emJogo(
        _ linhas: [LinhaDeDinheiro]
    ) -> [(rotulo: String, valor: String, aReceber: Bool)] {
        func soma(_ lado: [LinhaDeDinheiro]) -> String? {
            let valores = lado.compactMap(\.quantia)
            guard let moeda = valores.first?.currency else { return nil }
            let mesmos = valores.filter { $0.currency == moeda }
            let total = mesmos.reduce(0) { $0 + $1.amount }
            guard total > 0 else { return nil }
            return moeda == "créditos"
                ? L10n.tr("\(escrito(total)) créditos")
                : "\(moeda) \(escrito(total))"
        }
        var partes: [(rotulo: String, valor: String, aReceber: Bool)] = []
        if let receber = soma(linhas.filter(\.aReceber)) {
            partes.append((L10n.tr("a receber"), receber, true))
        }
        if let pagar = soma(linhas.filter { !$0.aReceber }) {
            partes.append((L10n.tr("a pagar"), pagar, false))
        }
        return partes
    }

    /// 4200 → "4.200"; 250.5 → "250,50".
    private static func escrito(_ valor: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = L10n.locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = valor == valor.rounded() ? 0 : 2
        return formatter.string(from: NSNumber(value: valor)) ?? "\(Int(valor))"
    }
}
