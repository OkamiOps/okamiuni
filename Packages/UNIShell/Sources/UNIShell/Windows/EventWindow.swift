import SwiftUI
import UNIDesign
import UNICore

/// As cores semânticas do protótipo (`semC`), já convertidas de oklch para
/// sRGB — `TokenColor` lê hex. A mesma conversão que produziu o `#D73337` /
/// `#FF7972` do marcador de "agora" na trilha de agenda.
///
/// Em tema escuro elas sobem de luminosidade, como o protótipo faz: L 0.52 não
/// passa em fundo escuro.
enum SemanticColor {
    static func ok(isDark: Bool) -> Color {
        TokenColor(css: isDark ? "#89D298" : "#317A45")?.color ?? .green
    }

    static func warn(isDark: Bool) -> Color {
        TokenColor(css: isDark ? "#F6B669" : "#945500")?.color ?? .orange
    }

    /// O vermelho do marcador de "agora" — `semC('live')` do protótipo. Uma
    /// definição só, usada pela trilha diária e pela grade da semana: eram duas
    /// cópias do mesmo par de hex.
    static func live(isDark: Bool) -> Color {
        TokenColor(css: isDark ? "#FF7972" : "#D73337")?.color ?? .red
    }
}

/// A tela **04 Detalhe do compromisso** (linhas 588–742 do protótipo,
/// 560 de largura). Abre clicando num compromisso da trilha de agenda.
public struct EventWindow: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dismiss) private var dismiss

    let store: MailStore
    let itemID: String

    /// Quem abre o link da reunião.
    ///
    /// **É o conserto do "Entrar" mudo.** O botão em destaque da janela
    /// chamava `UNIWindow.logSend("Abriria …")` — uma linha no `stderr` e mais
    /// nada. A pessoa clicava em cima da hora e a reunião não abria.
    ///
    /// Entra pela porta, e não como `NSWorkspace.shared.open` escondido no
    /// fechamento, por uma razão só: nenhum teste deste projeto abre navegador.
    /// O ensaio injeta um abridor que anota o endereço e devolve — e é assim que
    /// o clique se prova sem tirar a máquina de quem está usando.
    var abreLink: @MainActor (URL) -> Void = { url in
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }

    /// As seções recolhíveis — participantes e "o que gerou". Nascem
    /// recolhidas e **não** atravessam a abertura seguinte: ver `EventSections`.
    @State private var sections = EventSections()

    @State private var forwardOpen = false
    @State private var forwardTo: [Contact] = []
    @State private var forwardNote = ""
    @State private var forwardSent = false
    @State private var copied = false

    public init(store: MailStore, itemID: String) {
        self.store = store
        self.itemID = itemID
    }

    private var item: AgendaItem? {
        store.agenda.first { $0.id == itemID }
    }

    /// O que este compromisso mostra além do horário.
    ///
    /// **O que ele carrega primeiro.** Um compromisso criado de um convite traz
    /// local, link, organizador, participantes e descrição de verdade — e essa
    /// janela mostrava, por cima deles, o `EV_DEFAULT` do protótipo: "Sem local
    /// definido", "Ricardo Gomes · ricardo@empresa.com" e "Criado manualmente
    /// na agenda", numa reunião que o Favini tinha convidado.
    ///
    /// A tabela de fixture continua sendo o caminho de quem não carrega nada —
    /// os compromissos da agenda de exemplo, que é o que o Marco 1 desenha.
    private var detail: EventDetail {
        item?.detail ?? Fixtures.eventDetail(for: item?.title ?? "")
    }

    private var account: Account? {
        item.flatMap { store.account($0.accountID) }
    }

    /// A mensagem que gerou este compromisso, se ela ainda existe na caixa.
    ///
    /// Mesma regra dos menus de contexto — `ContextMenus.originMessageID` casa
    /// a linha `.email` da seção "o que gerou este compromisso" com o assunto
    /// de uma mensagem. Uma segunda regra aqui divergiria da do menu no
    /// primeiro ajuste, e o botão e o item levariam a lugares diferentes.
    ///
    /// `internal`: `WindowTests` lê isto para provar o destino do botão sem
    /// clicar em nada.
    var originMessageID: String? {
        // O compromisso nascido de um email **sabe** de qual: o `id` dele é
        // `email-<messageID>`. Perguntar isso primeiro é mais barato e mais
        // certo que casar assunto com assunto — e é o que faz o botão "Email"
        // funcionar num compromisso vindo de convite, cuja linha de histórico
        // pode não casar com nenhuma mensagem da caixa.
        if let doID = DetectedEventConversion.messageID(forAgendaID: itemID),
           store.messages.contains(where: { $0.id == doID }) {
            return doID
        }
        return ContextMenus.originMessageID(for: detail, in: store.messages)
    }

    private var tint: Color {
        account.flatMap { TokenColor(css: $0.tint(isDark: theme.isDark))?.color } ?? theme.accent.color
    }

    /// O dono da caixa é a conta do compromisso — nunca um endereço fixo: o app
    /// aceita qualquer conta, de qualquer provedor e domínio.
    private var guests: [EventPerson] {
        detail.guests(me: account?.address ?? "")
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if let item {
                ScrollViewReader { scroll in
                    ScrollView { content(item) }
                        .frame(maxHeight: .infinity)
                        // Protótipo: abrir o painel rola o modal até o fim
                        // (`_modalScroll.scrollTop = scrollHeight`) — senão ele
                        // nasce fora da vista, embaixo da pauta e do histórico.
                        .onChange(of: forwardOpen) { _, isOpen in
                            guard isOpen else { return }
                            withAnimation { scroll.scrollTo(Self.bottomAnchor, anchor: .bottom) }
                        }
                }
                footer
            } else {
                Text("Este compromisso não está mais na agenda.")
                    .font(theme.serif.font(size: 16))
                    .italic()
                    .foregroundStyle(theme.ink4.color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.color)
        .task { if store.agenda.isEmpty { await store.load() } }
    }

    /// Protótipo: `padding: 13px 18px; background: var(--surface2)`.
    private var header: some View {
        HStack(spacing: 10) {
            TintChip(label: account?.host ?? "", tint: tint, emphasized: true)
            Text("Compromisso")
                .capsLabel(size: 9.5)
                .frame(maxWidth: .infinity, alignment: .leading)
            CloseCross { dismiss() }
        }
        // A 04 não tem a barra de 42pt das outras três: o cabeçalho dela **é** a
        // barra. Como a janela é de verdade, os semáforos nativos moram aqui
        // dentro, e o conteúdo começa depois deles — a mesma medida da barra da
        // janela principal.
        .padding(.leading, WindowChrome.trafficLightInset)
        .padding(.trailing, 18)
        .padding(.vertical, 13)
        .background(theme.surface2.color)
        .hairline(theme.line2, edges: .bottom)
    }

    private func content(_ item: AgendaItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            title(item)
            if let link = detail.link { linkCard(link) }
            fields
            people
            if detail.hasAgenda { agenda }
            if let texto = detail.descricao, !texto.isEmpty { descricao(texto) }
            if detail.hasThread { thread }
            if forwardOpen { forwardPanel }
            if forwardSent { forwardConfirmation }
            // A nota de origem tinha cartão próprio no fim da janela, embaixo
            // da seção que fala da mesma coisa — duas caixas dizendo de onde o
            // compromisso veio, uma logo abaixo da outra. Com histórico, ela
            // passa a ser a última linha **de dentro** da seção; sem histórico
            // (o compromisso da agenda de exemplo) o cartão continua sendo o
            // único lugar onde essa frase cabe.
            if !detail.hasThread { originNote }
            Color.clear
                .frame(height: 0)
                .id(Self.bottomAnchor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Âncora do fim do modal, para o painel de encaminhar entrar na vista.
    private static let bottomAnchor = "uni.event.bottom"

    /// Protótipo: `padding: 18px 20px 4px`, com a barra da conta de 3pt à esquerda.
    private func title(_ item: AgendaItem) -> some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tint)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                    .font(theme.serif.font(size: 22, weight: .semibold))
                    .lineSpacing(0.25 * 22)   // line-height: 1.25
                    .foregroundStyle(theme.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                Text(DateLabels.eventDate(Fixtures.today))
                    .font(theme.sans.font(size: 13))
                    .foregroundStyle(theme.ink.color)
                    .padding(.top, 7)
                Text("\(item.rangeLabel) · \(item.durationLabel) · \(detail.recurrence)")
                    .font(theme.mono.font(size: 11))
                    .foregroundStyle(theme.ink3.color)
                    .padding(.top, 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 4)
    }

    /// Protótipo: `margin: 14px 20px 0; padding: 12px 14px; background:
    /// var(--accent-soft); border: 0.5px solid var(--accent-line)`.
    private func linkCard(_ link: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Link da reunião")
                    .font(theme.mono.font(size: 8.5, weight: .medium))
                    .tracking(theme.capsTracking(at: 8.5))
                    .textCase(.uppercase)
                    .foregroundStyle(theme.accentInk.color)
                // Clicável quando é um endereço de verdade: entrar na reunião é
                // o que a pessoa veio fazer aqui, e copiar o link para colar no
                // navegador era um passo a mais em cima da hora.
                //
                // O `Link` do SwiftUI saiu daqui: ele abre por conta própria, e
                // por isso o cartão e o botão "Entrar" do rodapé eram dois
                // caminhos diferentes para a mesma reunião — um funcionava, o
                // outro só escrevia no console. Agora os dois passam pelo mesmo
                // `abreLink`, e o mesmo `MeetingLink.destino` decide se há o que
                // abrir.
                if let destino = MeetingLink.destino(link) {
                    Button { abreLink(destino) } label: {
                        Text(link)
                            .font(theme.mono.font(size: 11.5))
                            .foregroundStyle(theme.accentInk.color)
                            .underline()
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusRing(cornerRadius: theme.radiusSmall)
                    .help("Abrir a reunião no navegador")
                } else {
                    Text(link)
                        .font(theme.mono.font(size: 11.5))
                        .foregroundStyle(theme.ink.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            ChromeButton(
                copied ? "Link copiado ✓" : "Copiar link",
                appearance: .outlined, size: 11.5, weight: .semibold,
                height: 28, horizontalPadding: 12
            ) {
                copy(link)
            }
            .fixedSize()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.accentSoft.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusLarge)
                .strokeBorder(theme.accentLine.color, lineWidth: Hairline.thickness(displayScale))
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    /// Protótipo: `padding: 16px 20px 0`, três linhas com calha de 70pt.
    private var fields: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Local", value: plain(detail.place))
            field("Conta", value: plain("\(account?.host ?? "—") · \(detail.notice)"))
            // Protótipo: o nome em `--ink` e o endereço em `--ink3`, na mesma
            // linha. Dois `Text` somados dariam depreciação no macOS 26.
            field("Organiza", value: Self.organizerLine(
                name: detail.organizer.name,
                address: detail.organizer.address,
                ink: theme.ink.color,
                ink3: theme.ink3.color
            ))
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    private func plain(_ text: String) -> AttributedString {
        var value = AttributedString(text)
        value.foregroundColor = theme.ink.color
        return value
    }

    nonisolated static func organizerLine(
        name: String, address: String, ink: Color, ink3: Color
    ) -> AttributedString {
        var line = AttributedString(name)
        line.foregroundColor = ink
        var tail = AttributedString(" · \(address)")
        tail.foregroundColor = ink3
        line.append(tail)
        return line
    }

    private func field(_ label: String, value: AttributedString) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(theme.mono.font(size: 8.5, weight: .medium))
                .tracking(theme.capsTracking(at: 8.5))
                .textCase(.uppercase)
                .foregroundStyle(theme.ink4.color)
                .frame(width: 70, alignment: .leading)
                .padding(.top, 2)
            Text(value)
                .font(theme.sans.font(size: 12.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Protótipo: `padding: 18px 20px 0`, com "Participantes · N" no topo.
    ///
    /// **Nasce recolhida** — pedido do dono: oito participantes tomavam a
    /// janela inteira e empurravam para fora da vista o quando, o onde e o
    /// link. Recolhida, o cabeçalho conta quantos são e a lista mostra o
    /// organizador; o clique no cabeçalho abre o resto. Ver `EventSections`.
    private var people: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(
                title: "Participantes · \(detail.guestCount)",
                expanded: sections.participants,
                help: sections.participants
                    ? "Recolher a lista de participantes"
                    : "Mostrar os \(detail.guestCount) participantes"
            ) {
                sections.toggleParticipants()
            }
            .padding(.bottom, 9)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(EventSections.visibleGuests(guests, expanded: sections.participants)) { guest in
                    HStack(spacing: 10) {
                        Text(guest.initials)
                            .font(theme.sans.font(size: 9.5, weight: .bold))  // 650
                            .foregroundStyle(theme.ink2.color)
                            .frame(width: 26, height: 26)
                            .background(theme.surface3.color)
                            .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 0) {
                            Text(guest.name)
                                .font(theme.sans.font(size: 12.5, weight: .medium))  // 550
                                .foregroundStyle(theme.ink.color)
                                .lineLimit(1)
                            Text("\(guest.address) · \(guest.role)")
                                .font(theme.sans.font(size: 11))
                                .foregroundStyle(theme.ink3.color)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        statusBadge(guest.status)
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 18)
    }

    private func statusBadge(_ status: EventPerson.Status) -> some View {
        let color: Color? = switch status {
        case .yes: SemanticColor.ok(isDark: theme.isDark)
        case .maybe: SemanticColor.warn(isDark: theme.isDark)
        case .pending: nil
        }
        return Text(status.label)
            .font(theme.mono.font(size: 8.5, weight: .medium))
            .tracking(0.08 * 8.5)   // 0.08em literal no protótipo
            .textCase(.uppercase)
            .foregroundStyle(color ?? theme.ink3.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.map { $0.opacity(0.14) } ?? theme.surface3.color)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .fixedSize()
    }

    private var agenda: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Pauta")
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(detail.agenda.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 9) {
                        Circle()
                            .fill(theme.ink4.color)
                            .frame(width: 4, height: 4)
                            .padding(.top, 7)
                        Text(line)
                            .font(theme.sans.font(size: 13))
                            .lineSpacing(0.45 * 13)   // line-height: 1.45
                            .foregroundStyle(theme.ink.color)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 18)
    }

    /// A `DESCRIPTION` do convite, inteira, no mesmo bloco da pauta.
    ///
    /// Inteira de propósito: é o que o organizador escreveu, e recortar
    /// escondia justamente o que costuma estar no fim — a instrução de entrar
    /// pelo telefone, o código da sala, o "leve a proposta impressa".
    @ViewBuilder
    private func descricao(_ texto: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Descrição")
                .padding(.bottom, 8)
            Text(texto)
                .font(theme.sans.font(size: 13))
                .lineSpacing(0.45 * 13)
                .foregroundStyle(theme.ink.color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 18)
    }

    /// Protótipo: `border-left: 0.5px solid var(--line); padding-left: 14px`.
    ///
    /// **Nasce recolhida, e o cabeçalho diz de quando é o email.** Antes eram
    /// duas coisas soltas no fim da janela: a linha do histórico, e um cartão
    /// cinza com "Do convite por email · conta vantion" logo abaixo, dizendo a
    /// mesma coisa noutro desenho. Agora a nota é a última linha **de dentro**
    /// da seção, e a seção inteira só ocupa altura quando alguém pede.
    private var thread: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(
                title: EventSections.originHeader(detail.thread),
                expanded: sections.origin,
                help: sections.origin
                    ? "Recolher o histórico deste compromisso"
                    : "Mostrar o email e a origem deste compromisso"
            ) {
                sections.toggleOrigin()
            }

            if sections.origin {
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(detail.thread) { entry in threadRow(entry) }
                    originLine
                }
                .padding(.top, 10)
                .padding(.leading, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    Rectangle().fill(theme.line.color).frame(width: Hairline.thickness(displayScale))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 20)
    }

    /// Uma linha do histórico, no vocabulário das linhas de mensagem do app:
    /// quem escreveu em `sans` 12,5 destacado, o assunto em `serif` logo
    /// abaixo, o carimbo em `mono` na direita — a mesma divisão de papéis de
    /// `MessageRow` e da pilha da conversa.
    ///
    /// A linha do email **é clicável** quando há mensagem para onde ir: leva ao
    /// mesmo lugar que o botão "Email" do rodapé, pela mesma função. Sem
    /// mensagem casada ela não vira botão — clique que não faz nada é o defeito
    /// que esta tarefa veio tirar, não um a acrescentar.
    @ViewBuilder
    private func threadRow(_ entry: EventThreadEntry) -> some View {
        if entry.kind == .email, originMessageID != nil {
            Button { revealOriginMessage() } label: {
                threadRowBody(entry).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusRing(cornerRadius: theme.radiusSmall)
            .help("Mostrar na janela principal o email que gerou este compromisso")
        } else {
            threadRowBody(entry)
        }
    }

    private func threadRowBody(_ entry: EventThreadEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(dotColor(entry.kind))
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.who)
                        .font(theme.sans.font(size: 12.5, weight: .semibold))  // 590
                        .foregroundStyle(theme.ink.color)
                        .lineLimit(1)
                    Text(entry.kind.rawValue)
                        .font(theme.mono.font(size: 8.5, weight: .medium))
                        .tracking(theme.capsTracking(at: 8.5))
                        .textCase(.uppercase)
                        .foregroundStyle(theme.ink4.color)
                    Spacer(minLength: 8)
                    Text(entry.when)
                        .font(theme.mono.font(size: 10))
                        .foregroundStyle(theme.ink4.color)
                        .fixedSize()
                }
                Text(entry.what)
                    .font(theme.serif.font(size: 13.5))
                    .lineSpacing(0.45 * 13.5)
                    .foregroundStyle(theme.ink2.color)
                    .padding(.top, 3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A nota de origem, integrada à seção: uma linha de apoio embaixo do
    /// histórico, e não mais um cartão cinza jogado no fim da janela.
    private var originLine: some View {
        Text(detail.note)
            .font(theme.sans.font(size: 11.5))
            .lineSpacing(0.45 * 11.5)
            .foregroundStyle(theme.ink3.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dotColor(_ kind: EventThreadEntry.Kind) -> Color {
        switch kind {
        case .email: tint
        case .ai: theme.accent.color
        case .system: theme.ink4.color
        }
    }

    /// Protótipo: `margin: 18px 20px 0; padding: 14px; border: 0.5px solid var(--accent)`.
    private var forwardPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Encaminhar convite")
                .font(theme.mono.font(size: 8.5, weight: .medium))
                .tracking(theme.capsTracking(at: 8.5))
                .textCase(.uppercase)
                .foregroundStyle(theme.accentInk.color)
                .padding(.bottom, 10)

            RecipientField(
                label: nil,
                placeholder: "quem do time precisa entrar; ",
                inputMinWidth: 150,
                menuWidth: 320,
                pool: store.contactPool,
                chips: $forwardTo
            )
            .padding(.bottom, 9)
            .hairline(theme.line, edges: .bottom)
            // Protótipo: `z-index: 50` no menu. Sem isto, o recado e os botões
            // — irmãos posteriores na pilha — pintam por cima das sugestões.
            .zIndex(50)

            TextField("Recado opcional para quem vai receber…", text: $forwardNote)
                .textFieldStyle(.plain)
                .font(theme.serif.font(size: 14))
                .foregroundStyle(theme.ink.color)
                .padding(.top, 10)

            HStack(spacing: 8) {
                ChromeButton(
                    "Encaminhar",
                    appearance: forwardTo.isEmpty ? .muted : .accent,
                    size: 12.5, weight: .semibold, height: 30
                ) {
                    guard !forwardTo.isEmpty else { return }
                    UNIWindow.logSend(
                        "Encaminharia o convite para [\(forwardTo.map(\.address).joined(separator: ", "))]."
                    )
                    forwardSent = true
                    forwardOpen = false
                }
                ChromeButton("Cancelar", appearance: .outlined, height: 30, horizontalPadding: 12) {
                    forwardOpen = false
                    forwardTo = []
                    forwardNote = ""
                }
                Spacer(minLength: 8)
                Text("o convite vai com o link e a pauta")
                    .capsLabel()
                    .lineLimit(1)
            }
            .padding(.top, 12)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Fundo e borda desenhados, não recortados: um `clipShape` aqui cortaria
        // o menu de sugestões, que por desenho sai para fora do cartão.
        .background {
            RoundedRectangle(cornerRadius: theme.radiusLarge)
                .fill(theme.surface2.color)
                .strokeBorder(theme.accent.color, lineWidth: Hairline.thickness(displayScale))
        }
        .shadow(color: .black.opacity(0.10), radius: 9, x: 0, y: 6)
        .padding(.horizontal, 20)
        .padding(.top, 18)
    }

    private var forwardConfirmation: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(theme.accent.color)
                .frame(width: 6, height: 6)
            Text("Convite encaminhado para \(forwardTo.count) \(forwardTo.count == 1 ? "pessoa" : "pessoas")")
                .font(theme.sans.font(size: 12.5))
                .foregroundStyle(theme.accentInk.color)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .background(theme.accentSoft.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radiusLarge)
                .strokeBorder(theme.accentLine.color, lineWidth: Hairline.thickness(displayScale))
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
    }

    /// Protótipo: `padding: 16px 20px 20px`, cartão em `surface2`.
    private var originNote: some View {
        Text(detail.note)
            .font(theme.sans.font(size: 12.5))
            .lineSpacing(0.5 * 12.5)   // line-height: 1.5
            .foregroundStyle(theme.ink2.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface2.color)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusLarge))
            .overlay {
                RoundedRectangle(cornerRadius: theme.radiusLarge)
                    .strokeBorder(theme.line2.color, lineWidth: Hairline.thickness(displayScale))
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 20)
    }

    /// Protótipo: `padding: 12px 18px 15px`, botões de 30pt.
    private var footer: some View {
        HStack(spacing: 8) {
            // **"Entrar" abre a reunião.** Ele chamava `UNIWindow.logSend` —
            // uma linha no console e nada na tela —, e era o controle mudo mais
            // caro do app: o botão em destaque da janela, apertado em cima da
            // hora, sem nada acontecendo.
            //
            // Sem link de sala o botão **não existe**, como o protótipo desenha
            // (`sc-if ev.hasLink`) e como o resto do app faz quando não há para
            // onde ir. Quem decide é `MeetingLink.destino`, o mesmo do cartão
            // acima: um "link" que não se abre no navegador não acende botão.
            if let destino = MeetingLink.destino(detail.link) {
                ChromeButton(
                    "Entrar", appearance: .accent, size: 12.5, weight: .semibold,
                    height: 30, horizontalPadding: 16
                ) {
                    abreLink(destino)
                }
                .help("Abrir a reunião no navegador")
            }
            ChromeButton(
                "Encaminhar",
                appearance: forwardOpen ? .outlinedOn : .outlined,
                height: 30
            ) {
                forwardOpen.toggle()
                if forwardOpen { forwardSent = false }
            }
            .help("Encaminhar o convite para outras pessoas")

            // "Email" leva ao mesmo lugar que "Ir para o email de origem" dos
            // menus de contexto: `MailStore.reveal` desfaz o filtro, a caixa e
            // a busca que escondem a mensagem e a seleciona na janela
            // principal. Sem mensagem casada o botão apaga com o motivo no
            // `help` — controle que existe faz alguma coisa, e recusa muda é o
            // mesmo defeito de outra cor.
            //
            // O botão "Reagendar" **foi removido**: não há edição de agenda
            // neste marco, e um botão que abre uma tela inexistente é pior que
            // a ausência dele. Volta no Marco 4, com o EventKit.
            if detail.hasThread {
                ChromeButton(
                    "Email",
                    appearance: originMessageID == nil ? .muted : .outlined,
                    height: 30, horizontalPadding: 13
                ) {
                    revealOriginMessage()
                }
                .disabled(originMessageID == nil)
                .help(
                    originMessageID == nil
                        ? "O email que gerou este compromisso não está mais na caixa"
                        : "Mostrar na janela principal o email que gerou este compromisso"
                )
            }

            Spacer(minLength: 8)
            ChromeButton("Fechar", appearance: .quiet, height: 30) { dismiss() }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 15)
        .background(theme.surface2.color)
        .hairline(theme.line2, edges: .top)
    }

    /// O que o botão "Email" faz.
    ///
    /// `MailStore.reveal` desfaz o filtro de conta, a caixa e a busca que
    /// escondam a mensagem e a seleciona; a janela principal segue o
    /// `revealCount` para voltar à aba Email. Depois disso a janela 04 fecha:
    /// o pedido foi "me leve até o email", e deixá-la aberta por cima do
    /// destino esconderia justamente o que se pediu para ver.
    ///
    /// `internal` para `WindowTests` provar o destino sem clique nenhum —
    /// evento sintético é proibido neste projeto.
    func revealOriginMessage() {
        guard let id = originMessageID else { return }
        store.reveal(id)
        dismiss()
    }

    private func copy(_ link: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        #endif
        copied = true
        Task {
            try? await Task.sleep(for: .milliseconds(1600))
            copied = false
        }
    }
}

/// O rótulo de uma seção da janela 04 — e, quando a seção recolhe, o controle
/// que a abre.
///
/// Protótipo: `font-family: var(--mono); font-size: 8.5px; letter-spacing:
/// var(--caps); text-transform: uppercase; color: var(--ink4)`. Era o mesmo
/// bloco copiado cinco vezes no arquivo, e agora é um só — o que também garante
/// que a seção que recolhe e a que não recolhe fiquem na mesma linha de base.
///
/// O sinal é o "▾"/"▸" que o app já usa: "▾" na faixa de resposta do leitor
/// (aberta, e o clique recolhe) e "▸" no submenu de contexto (fechado, e o
/// clique abre). Nenhum componente novo além deste — é polimento, não reforma.
private struct SectionHeader: View {
    @Environment(\.theme) private var theme
    @State private var hovering = false

    let title: String
    /// `nil` numa seção que não recolhe ("Pauta", "Descrição"): sem seta, sem
    /// clique, sem hover — um rótulo, como sempre foi.
    var expanded: Bool?
    var help: String?
    var action: (() -> Void)?

    var body: some View {
        if let expanded, let action {
            Button(action: action) {
                row(expanded: expanded).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusRing(cornerRadius: theme.radiusSmall)
            .help(help ?? "")
            .onHover { hovering = $0 }
        } else {
            row(expanded: nil)
        }
    }

    private func row(expanded: Bool?) -> some View {
        HStack(spacing: 7) {
            Text(title)
                .font(theme.mono.font(size: 8.5, weight: .medium))
                .tracking(theme.capsTracking(at: 8.5))
                .textCase(.uppercase)
                .foregroundStyle(hovering ? theme.ink3.color : theme.ink4.color)
            if let expanded {
                Text(expanded ? "▾" : "▸")
                    .font(theme.mono.font(size: 8.5))
                    .foregroundStyle(hovering ? theme.ink3.color : theme.ink4.color)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// O × do canto do cabeçalho. Protótipo: 22×22, raio `var(--r2)`, `--ink3`,
/// com `--surface3` no hover.
private struct CloseCross: View {
    @Environment(\.theme) private var theme
    @State private var hovering = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("×")
                .font(theme.sans.font(size: 13))
                .foregroundStyle(theme.ink3.color)
                .frame(width: 22, height: 22)
                .background(hovering ? theme.surface3.color : .clear)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.radiusSmall)
        .onHover { hovering = $0 }
    }
}

#if os(macOS)
#Preview("04 Detalhe do compromisso") {
    EventWindow(store: MailStore(source: InMemoryMailSource.fixtures), itemID: "e2")
        .environment(ThemeStore())
        .frame(width: 560, height: 788)
}
#endif
