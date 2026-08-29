import Testing
import Foundation
@testable import UNICore

@Suite("Modelos")
struct ModelTests {

    @Test("iniciais saem do nome, não do email")
    func initialsFromName() {
        #expect(Contact(name: "Marina Duarte", address: "marina@x.com").initials == "MD")
        #expect(Contact(name: "Equipe Produto", address: "p@x.com").initials == "EP")
        #expect(Contact(name: "Ricardo", address: "r@x.com").initials == "R")
    }

    @Test("sem nome, as iniciais vêm do endereço")
    func initialsFromAddress() {
        #expect(Contact(name: "", address: "contato@meusite.com").initials == "C")
    }

    @Test("nomes com mais de duas palavras usam a primeira e a última")
    func initialsThreeWords() {
        #expect(Contact(name: "Ana Beatriz Silva", address: "a@x.com").initials == "AS")
    }

    /// A ordem é a que a barra lateral desenha, e a Lixeira entra **depois de
    /// Arquivado** — é a ordem de Gmail, Outlook e Mail, e é onde a mão a
    /// procura. Enviadas vem depois dela, no fim: é a última da barra porque é
    /// a que não pertence ao fluxo.
    @Test("as pastas batem com o protótipo — Lixeira ao fim do fluxo, Enviadas depois")
    func triageBuckets() {
        #expect(TriageBucket.allCases.map(\.rawValue)
            == ["hoje", "depois", "todos", "arquivar", "lixeira", "enviadas"])
        #expect(TriageBucket.today.label == "Hoje")
        #expect(TriageBucket.later.label == "Depois")
        #expect(TriageBucket.all.label == "Tudo")
        #expect(TriageBucket.archived.label == "Arquivado")
        #expect(TriageBucket.trash.label == "Lixeira")
        #expect(TriageBucket.sent.label == "Enviadas")
    }

    /// A lista da **triagem** é a de antes, e Enviadas não entra nela: ela é a
    /// que o menu "Mover para" usa, e mover uma mensagem recebida para
    /// Enviadas não quer dizer nada.
    @Test("a triagem continua sendo as cinco de sempre — Enviadas fica fora")
    func triageListExcludesSent() {
        #expect(TriageBucket.triage.map(\.rawValue)
            == ["hoje", "depois", "todos", "arquivar", "lixeira"])
        #expect(!TriageBucket.triage.contains(.sent))
    }

    /// "Tudo" é a visão da triagem: o que chegou e ainda pede decisão. O que
    /// você escreveu não entra — senão a caixa que a pessoa deixa aberta
    /// cresceria a cada resposta que ela mandasse.
    @Test("Enviadas fica fora de «Tudo», como a Lixeira")
    func sentIsNotInAll() {
        let enviada = Message.preview(id: "e1", bucket: .sent)
        #expect(!TriageBucket.all.contains(enviada))
        #expect(TriageBucket.sent.contains(enviada))
    }

    /// Em Enviadas a linha mostra **para quem** a mensagem foi: o remetente é
    /// sempre você, e repeti-lo em toda linha esconderia a única coisa que
    /// distingue uma da outra.
    @Test("a linha da lista mostra o destinatário em Enviadas, e o remetente no resto")
    func listHeadline() {
        // O remetente da `preview` é "Marina Duarte"; o destinatário é outro
        // nome de propósito, senão as duas respostas seriam a mesma e o teste
        // passaria com a regra invertida.
        let para = [Contact(name: "Ricardo Alves", address: "ricardo@meudominio.com.br")]
        #expect(Message.preview(bucket: .today, to: para).listHeadline == "Marina Duarte")
        #expect(Message.preview(bucket: .sent, to: para).listHeadline == "Ricardo Alves")

        // Sem nome, o endereço — e todos eles, não só o primeiro.
        let dois = para + [Contact(name: "", address: "socio@meudominio.com.br")]
        #expect(Message.preview(bucket: .sent, to: dois).listHeadline
            == "Ricardo Alves, socio@meudominio.com.br")
        // Enviada sem destinatário visível (só cópia oculta) cai no remetente:
        // dizer o seu nome é menos errado do que uma linha em branco.
        #expect(Message.preview(bucket: .sent).listHeadline == "Marina Duarte")
    }

    /// Sem isto, apagar não pareceria apagar: a caixa que a pessoa deixa aberta
    /// continuaria mostrando — e contando — o que ela acabou de jogar fora.
    @Test("«Tudo» mostra tudo menos a Lixeira")
    func allExcludesTrash() {
        #expect(TriageBucket.all.contains(Message.preview(bucket: .today)))
        #expect(TriageBucket.all.contains(Message.preview(bucket: .archived)))
        #expect(!TriageBucket.all.contains(Message.preview(bucket: .trash)))
        // E a Lixeira continua sendo uma caixa como as outras para o que é dela.
        #expect(TriageBucket.trash.contains(Message.preview(bucket: .trash)))
        #expect(!TriageBucket.trash.contains(Message.preview(bucket: .today)))
    }

    @Test("a caixa Tudo aceita qualquer mensagem; as outras filtram")
    func bucketMatching() {
        let m = Message.preview(bucket: .today)
        #expect(TriageBucket.all.contains(m))
        #expect(TriageBucket.today.contains(m))
        #expect(TriageBucket.archived.contains(m) == false)
    }
}

@Suite("Fixtures e fuso horário")
struct FixtureTimeZoneTests {

    /// O bug: `today` era fixado em America/Sao_Paulo e o minuto era derivado
    /// dele com `Calendar.current`. Numa máquina em Berlim isso dava 1020 em
    /// vez de 720, e a agenda marcava "agora" às 17:00. Este teste trava as
    /// duas pontas juntas — ele falha em qualquer fuso onde elas discordem.
    @Test("o minuto derivado de today bate com nowMinute")
    func derivedMinuteMatchesConstant() {
        let cal = Calendar.current
        let derived = cal.component(.hour, from: Fixtures.today) * 60
            + cal.component(.minute, from: Fixtures.today)
        #expect(derived == Fixtures.nowMinute)
    }

    @Test("today cai no dia do protótipo no calendário local")
    func todayIsTheProtoypeDay() {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Fixtures.today)
        #expect(parts.year == 2026)
        #expect(parts.month == 8)
        #expect(parts.day == 25)
    }
}

@Suite("Dia como dado")
struct DayLabelTests {

    @Test("os dois dias com nome são hoje e ontem")
    func namedDays() {
        #expect(DayLabel.name(forOffset: 0) == "Hoje")
        #expect(DayLabel.name(forOffset: -1) == "Ontem")
    }

    /// Sem esta metade, "Hoje" viraria o rótulo de qualquer dia sem nome —
    /// que é o erro simétrico ao que a lista tinha.
    @Test("nenhum outro dia tem nome", arguments: [-30, -7, -2, 1, 2, 365])
    func unnamedDays(offset: Int) {
        #expect(DayLabel.name(forOffset: offset) == nil)
    }

    @Test("só o dia corrente mostra a hora no carimbo da linha")
    func clockOnlyToday() {
        #expect(DayLabel.showsClockTime(forOffset: 0))
        #expect(DayLabel.showsClockTime(forOffset: -1) == false)
        #expect(DayLabel.showsClockTime(forOffset: -9) == false)
    }
}

@Suite("As fixtures são as do design")
struct FixtureContentTests {

    /// Design, `const MSGS` (linha 1547). A tabela inteira, na ordem em que ele
    /// escreve: id, conta, remetente, dia e caixa.
    ///
    /// Números literais de propósito. Comparar `messages.count` com
    /// `messages.filter{…}.count` seria verdadeiro por construção e passaria
    /// com as quatro mensagens erradas que estavam aqui.
    @Test("as sete mensagens do design estão todas, com conta, dia e caixa")
    func sevenMessagesFromTheDesign() throws {
        let expected: [(id: String, account: String, from: String, day: Int, bucket: TriageBucket)] = [
            ("m1", "zoho",   "Marina Duarte",        0, .today),
            ("m4", "zoho",   "Equipe Produto",       0, .today),
            ("m6", "host",   "Formulário do site",  -1, .today),
            ("m2", "host",   "Hostinger",            0, .later),
            ("m3", "gmail",  "Bruno Sato",          -1, .later),
            ("m7", "gmail",  "Newsletter Ofício",   -1, .later),
            ("m5", "icloud", "Apple",               -1, .archived),
        ]

        #expect(Fixtures.messages.count == 7)
        #expect(Fixtures.messages.map(\.id) == expected.map(\.id))

        for row in expected {
            let message = try #require(Fixtures.messages.first { $0.id == row.id })
            #expect(message.accountID == row.account)
            #expect(message.from.name == row.from)
            #expect(message.dayOffset == row.day)
            #expect(message.bucket == row.bucket)
        }
    }

    /// O contador da barra lateral é `count(for:)`. Estes são os números que o
    /// design mostra: 3 / 3 / 7 / 1.
    @Test("os contadores por caixa batem com o design")
    @MainActor
    func bucketCountsFromTheDesign() async {
        let store = MailStore(source: InMemoryMailSource.fixtures)
        await store.load()
        #expect(store.count(for: .today) == 3)
        #expect(store.count(for: .later) == 3)
        #expect(store.count(for: .all) == 7)
        #expect(store.count(for: .archived) == 1)
    }

    @Test("nenhuma mensagem aponta para uma conta que não existe")
    func everyMessageHasAnAccount() {
        let ids = Set(Fixtures.accounts.map(\.id))
        #expect(Fixtures.messages.allSatisfy { ids.contains($0.accountID) })
    }

    @Test("nenhuma das quatro contas fica sem mensagem na lista do design")
    func everyAccountHasAMessage() {
        let used = Set(Fixtures.messages.map(\.accountID))
        #expect(Fixtures.accounts.allSatisfy { used.contains($0.id) })
    }

    /// O que o dono do projeto viu: HOST onde o design escreve HOSTINGER.
    @Test("a conta do site declara 'hostinger', e a chave interna continua 'host'")
    func hostingerIsWrittenOut() throws {
        let site = try #require(Fixtures.accounts.first { $0.id == "host" })
        #expect(site.host == "hostinger")
        #expect(site.id == "host")
    }

    @Test("as outras três declaram o host do design", arguments: [
        ("zoho", "zoho"), ("gmail", "gmail"), ("icloud", "icloud"),
    ])
    func remainingHosts(id: String, host: String) throws {
        let account = try #require(Fixtures.accounts.first { $0.id == id })
        #expect(account.host == host)
    }

    /// Os três compromissos detectados do design, com os horários que `TIMES`
    /// dá a cada um.
    @Test("os compromissos detectados são os três do design")
    func detectedEvents() throws {
        let labels = Fixtures.messages.compactMap(\.detectedEvent?.label)
        #expect(labels == [
            "Call de contrato · qui 27, 15:00",
            "Bloco de foco · qua 26, 09:00",
            "Renovar domínio · 04 set, 10:00",
        ])

        let renewal = try #require(Fixtures.messages.first { $0.id == "m2" }?.detectedEvent)
        let parts = Calendar.current.dateComponents([.month, .day, .hour], from: renewal.start)
        #expect(parts.month == 9)
        #expect(parts.day == 4)
        #expect(parts.hour == 10)
        #expect(renewal.duration == 1800)
    }

    @Test("cada mensagem do design traz corpo e etiqueta")
    func bodiesAndTags() {
        #expect(Fixtures.messages.allSatisfy { !$0.body.isEmpty })
        #expect(Fixtures.messages.allSatisfy { !$0.tags.isEmpty })
    }

    /// Design: `summary` existe nas sete. Era `nil` em três das quatro antigas,
    /// e o leitor abria sem a faixa "Resumo no dispositivo".
    @Test("as sete têm resumo")
    func everyMessageHasASummary() {
        #expect(Fixtures.messages.allSatisfy { ($0.summary?.isEmpty == false) })
    }

    /// `replyHints` do design. Cinco têm sugestão, duas não — a newsletter e o
    /// recibo, que não pedem resposta.
    @Test("as sugestões de resposta são as do design")
    func replyHints() throws {
        let withHints = Fixtures.messages.filter { !$0.replyHints.isEmpty }
        #expect(withHints.count == 5)

        let marina = try #require(Fixtures.messages.first { $0.id == "m1" })
        #expect(marina.replyHints == ["Confirmar quinta 15h", "Pedir mais um dia"])

        let receipt = try #require(Fixtures.messages.first { $0.id == "m5" })
        #expect(receipt.replyHints.isEmpty)
    }

    /// A trilha diária filtra `dayOffset == 0`. Ampliar as mensagens não podia
    /// mexer nisso — são coleções separadas —, e este teste é o que garante
    /// que continuou não mexendo.
    @Test("a terça da agenda continua com os cinco blocos da trilha")
    func agendaUntouched() {
        #expect(Fixtures.agenda.count == 5)
        #expect(Fixtures.week.filter { $0.dayOffset == 0 }.count == 5)
    }
}

@Suite("Navegação da agenda")
struct AgendaNavigationTests {

    private var anchor: Date { Fixtures.today }   // terça, 25/08/2026

    /// O defeito: só a visão Dia tinha `‹ ›`. Semana e mês ficavam presas no
    /// mês da âncora, sem como avançar.
    @Test("o passo do dia anda um dia")
    func dayStep() {
        #expect(MonthAgenda.navigationStep(days: .day, from: 0, anchor: anchor, direction: 1) == 1)
        #expect(MonthAgenda.navigationStep(days: .day, from: 3, anchor: anchor, direction: -1) == 2)
    }

    @Test("o passo da semana anda sete dias")
    func weekStep() {
        #expect(MonthAgenda.navigationStep(days: .week, from: 0, anchor: anchor, direction: 1) == 7)
        #expect(MonthAgenda.navigationStep(days: .week, from: 7, anchor: anchor, direction: -1) == 0)
    }

    /// Um mês não tem passo fixo: de 25/08 para setembro são 31 dias, de
    /// setembro para outubro são 30. Somar 30 ou 31 cravado erraria em metade
    /// do ano.
    @Test("o passo do mês respeita o tamanho de cada mês")
    func monthStep() {
        let umMes = MonthAgenda.navigationStep(days: .month, from: 0, anchor: anchor, direction: 1)
        #expect(umMes == 31)   // 25/08 -> 25/09
        let dois = MonthAgenda.navigationStep(days: .month, from: umMes, anchor: anchor, direction: 1)
        #expect(dois - umMes == 30)   // 25/09 -> 25/10
    }

    @Test("avançar e voltar devolve ao ponto de partida", arguments: [
        MonthAgenda.NavigationScope.day, .week, .month,
    ])
    func roundTrip(scope: MonthAgenda.NavigationScope) {
        let ida = MonthAgenda.navigationStep(days: scope, from: 0, anchor: anchor, direction: 1)
        let volta = MonthAgenda.navigationStep(days: scope, from: ida, anchor: anchor, direction: -1)
        #expect(volta == 0)
    }

    @Test("a semana mostrada acompanha o foco")
    func weekFollowsFocus() {
        let atual = WeekAgenda.weekOffsets(for: anchor)
        let seguinte = WeekAgenda.weekOffsets(for: anchor, focusOffset: 7)
        #expect(seguinte.count == 7)
        #expect(seguinte.allSatisfy { !atual.contains($0) })
        #expect(seguinte.min()! == atual.min()! + 7)
    }

    @Test("o mês mostrado acompanha o foco")
    func monthFollowsFocus() {
        let atual = MonthAgenda.dayOffsets(for: anchor)
        let seguinte = MonthAgenda.dayOffsets(for: anchor, focusOffset: 31)
        #expect(seguinte.count == atual.count)
        #expect(seguinte.min()! > atual.min()!)
    }
}
