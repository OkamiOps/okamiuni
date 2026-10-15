import SwiftUI
import UNIDesign
import UNICore
// Por uma linha: `MimeBody.textFromHTML`, que deriva o texto do convite
// HTML-only na hora de exibir. Nenhuma segunda cópia da regra.
import UNISync

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

/// O aviso de cancelar/remover, no idioma da janela — não o diálogo do macOS.
enum EventConfirmKind: Equatable {
    case cancelMeeting
    case removeFromCalendar

    var title: String {
        switch self {
        case .cancelMeeting: L10n.tr("Cancelar esta reunião?")
        case .removeFromCalendar: L10n.tr("Remover do calendário?")
        }
    }

    var message: String {
        switch self {
        case .cancelMeeting:
            L10n.tr("Os convidados recebem o cancelamento e o compromisso sai da agenda.")
        case .removeFromCalendar:
            L10n.tr("O compromisso sai da agenda. Os convidados não recebem aviso.")
        }
    }

    var actionTitle: String {
        switch self {
        case .cancelMeeting: L10n.tr("Cancelar reunião")
        case .removeFromCalendar: L10n.tr("Remover")
        }
    }

    /// O ícone do quadrado vermelho: cancelar uma reunião avisa gente (um
    /// envelope sai), remover do calendário só tira do calendário.
    var icon: String {
        switch self {
        case .cancelMeeting: "envelope.badge"
        case .removeFromCalendar: "calendar.badge.minus"
        }
    }

    /// O mesmo aviso, no formato que `UNIConfirmation` desenha.
    var confirmationText: UNIConfirmationText {
        UNIConfirmationText(
            title: title, detail: message, confirm: actionTitle, icon: icon
        )
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
    @State private var confirm: EventConfirmKind?
    @State private var cancelling = false

    @Environment(MeetingRoomFactory.self) private var meetingFactory: MeetingRoomFactory?

    /// Abre a lista de destinatários nos renders fora da tela. Nulo no app;
    /// existe para provar o empilhamento sem clicar nem tomar o foco do Mac.
    private let seededForwardQuery: String?

    public init(store: MailStore, itemID: String) {
        self.store = store
        self.itemID = itemID
        seededForwardQuery = nil
    }

    /// A mesma janela com as seções já abertas. **Só para verificação fora da
    /// tela**, como o `initialMode` da `CalendarScreen`: o harness não clica em
    /// cabeçalho nenhum, e sem este caminho o que a seção aberta mostra seria
    /// um estado que nenhum PNG jamais fotografaria.
    init(store: MailStore, itemID: String, debugSections: EventSections) {
        self.store = store
        self.itemID = itemID
        seededForwardQuery = nil
        _sections = State(initialValue: debugSections)
    }

    /// O painel já aberto e a busca semeada, exclusivamente para renderização
    /// offscreen nos testes de sobreposição.
    init(store: MailStore, itemID: String, debugForwardQuery: String) {
        self.store = store
        self.itemID = itemID
        seededForwardQuery = debugForwardQuery
        _forwardOpen = State(initialValue: true)
    }

    /// O aviso já aberto. Só para o teste fotografar o cartão no lugar do
    /// `confirmationDialog` do sistema.
    init(store: MailStore, itemID: String, debugConfirm: EventConfirmKind) {
        self.store = store
        self.itemID = itemID
        seededForwardQuery = nil
        _confirm = State(initialValue: debugConfirm)
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
    /// A tabela de fixture continua sendo o caminho só da agenda de exemplo.
    /// Compromisso nascido de um email reconstrói o detalhe da mensagem de
    /// origem em vez de cair no Ricardo Gomes.
    private var detail: EventDetail {
        guard let item else { return Fixtures.eventDefault }
        // Só o id determinístico — `originMessage` passa por `originMessageID`,
        // que lê `detail`, e os dois juntos seriam um laço.
        let origem = DetectedEventConversion.messageID(forAgendaID: itemID)
            .flatMap { store.message($0) }
        return InviteAgenda.resolvedDetail(
            for: item,
            origin: origem,
            account: account
        )
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

    private var swatch: TokenColor? {
        item.flatMap { CalendarTint.token(of: $0, in: store, theme: theme) }
    }

    private var tint: Color {
        guard let item else {
            return account.flatMap { TokenColor(css: $0.tint(isDark: theme.isDark))?.color }
                ?? theme.accent.color
        }
        return CalendarEventChrome.ink(swatch, cancelled: item.isCancelled, theme: theme)
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
                Text(L10n.tr("Este compromisso não está mais na agenda."))
                    .font(theme.serif.font(size: 16))
                    .italic()
                    .foregroundStyle(theme.ink4.color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // `glassWindow`: o fundo de uma janela **solta** — fechado o bastante
        // para texto no Vidro, `surface` nos 26 opacos. Mesmo token da janela
        // da mensagem e do compositor.
        .background(theme.glassWindow.color)
        .overlay { if let confirm { confirmLayer(confirm) } }
        .onExitCommand { confirm = nil }
        .task { if store.agenda.isEmpty { await store.load() } }
    }

    /// A confirmação é a **do app** — `UNIConfirmation`, a mesma peça que a
    /// Lixeira usa. Era um cartão próprio desta janela (`EventConfirmCard`),
    /// com outra largura, outro raio e outros botões: dois desenhos de
    /// pergunta no mesmo app.
    private func confirmLayer(_ kind: EventConfirmKind) -> some View {
        ZStack {
            ModalScrim(onTap: { confirm = nil })
            UNIConfirmation(
                text: kind.confirmationText,
                onConfirm: {
                    confirm = nil
                    switch kind {
                    case .cancelMeeting: performCancel()
                    case .removeFromCalendar: performRemove()
                    }
                },
                onCancel: { confirm = nil }
            )
        }
        .accessibilityAddTraits(.isModal)
    }

    var canCancelMeeting: Bool {
        Self.isCreatedHere(itemID)
    }

    /// Compromisso que eu não criei neste app: veio do Calendário, de um
    /// convite ou da caixa. Tira da agenda; não manda METHOD:CANCEL.
    var canRemoveFromCalendar: Bool {
        item != nil && !canCancelMeeting
    }

    /// O prefixo `manual-` é o que o "Novo compromisso" grava. Sem ele, o
    /// evento veio de fora — EventKit, CalDAV, email — e cancelar a reunião
    /// (avisar convidados, apagar a sala) não é o nosso papel.
    nonisolated static func isCreatedHere(_ itemID: String) -> Bool {
        itemID.hasPrefix("manual-")
    }

    /// Protótipo: `padding: 13px 18px; background: var(--surface2)`.
    /// O último semáforo termina em x=70. O mesmo respiro de 14pt da barra
    /// principal põe o primeiro elemento em x=84, sem parecer grudado nele.
    static let headerLeadingInset: CGFloat = WindowChrome.trafficLightInset + 14

    /// A barra da janela: os semáforos nativos na linha da plataforma e, na
    /// outra ponta, editar e encaminhar.
    ///
    /// Protótipo: `padding: 14px 16px 0`, **sem fundo e sem linha** — o
    /// desenho dos modais tirou a barra de `surface2` que havia aqui. A janela
    /// do compromisso começa pela contagem ou pelo título, e uma faixa cinza
    /// antes deles só adiava a informação.
    private var header: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            iconButton("pencil", label: L10n.tr("Editar compromisso")) {
                // Editar agenda é do Marco 4 (EventKit). Até lá o botão abre o
                // que existe: o email que gerou o compromisso.
                revealOriginMessage()
            }
            .disabled(originMessageID == nil)
            iconButton("arrowshape.turn.up.right", label: L10n.tr("Encaminhar convite")) {
                forwardOpen.toggle()
                if forwardOpen { forwardSent = false }
            }
        }
        .padding(.leading, Self.headerLeadingInset)
        .padding(.trailing, 16)
        .frame(height: TrafficLightLayout.contentCenterFromTop * 2)
        .trafficLightsOnTheLine(barHeight: TrafficLightLayout.contentCenterFromTop * 2)
    }

    private func iconButton(
        _ symbol: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(theme.ink2.color)
                .frame(width: 28, height: 28)
                .contentShape(RoundedRectangle(cornerRadius: theme.modalButtonRadius))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.modalButtonRadius)
        .accessibilityLabel(label)
        .help(label)
    }

    private func content(_ item: AgendaItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // A ordem é a do desenho, e ela é um argumento: primeiro o que
            // está a ponto de acontecer (a contagem e o Entrar), depois o que
            // é (título e quando), depois o que levar, depois quem vai.
            if let contagem { countdown(contagem, item: item) }
            title(item)
            if contagem == nil, let link = detail.meetingLink { linkCard(link) }
            if !prepLines.isEmpty { prep }
            if let rsvp { rsvpRow(rsvp) }
            people
            if detail.hasAgenda { agenda }
            if let texto = detail.visibleDescription { descricao(texto) }
            if detail.hasThread { thread }
            if forwardOpen {
                // O menu de destinatários sai do painel por desenho. Este
                // `zIndex` precisa estar aqui, no nível dos irmãos de
                // `content`: o valor interno do `RecipientField` não impede a
                // nota de origem, desenhada depois, de atravessá-lo.
                forwardPanel.zIndex(100)
            }
            if forwardSent { forwardConfirmation }
            if !detail.hasThread { originNote }
            Color.clear
                .frame(height: 0)
                .id(Self.bottomAnchor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - A contagem, e entrar

    /// "COMEÇA EM / 12 min" — e `nil` quando não é hora de contar.
    /// Ver `EventPrep.countdown`.
    private var contagem: String? {
        guard let item, !item.isCancelled else { return nil }
        let inicio = store.agendaDate(for: item)
        let fim = inicio.addingTimeInterval(TimeInterval(item.endMinute - item.startMinute) * 60)
        return EventPrep.countdown(start: inicio, end: fim)
    }

    /// O bloco da contagem: `background: accentSoft; border-radius: 12;
    /// margin: 12px 28px 0; padding: 16px 20px`, com "COMEÇA EM" em 11/0.08em,
    /// o número em mono 32 e **Entrar** grande à direita.
    ///
    /// Entrar é a única coisa grande da janela nesse momento, e é de propósito:
    /// a doze minutos da reunião não há segunda coisa a fazer.
    private func countdown(_ texto: String, item: AgendaItem) -> some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                ModalEyebrow(
                    text: texto == L10n.tr("agora") ? L10n.tr("Em curso") : L10n.tr("Começa em"),
                    size: 11, accented: true, tracking: 0.08
                )
                Text(texto)
                    .font(theme.mono.font(size: 32, weight: .semibold))
                    .tracking(-0.02 * 32)
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
                if let link = detail.meetingLink {
                    HStack(spacing: 6) {
                        Text(link)
                            .font(theme.mono.font(size: 12))
                            .foregroundStyle(theme.ink3.color)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button { copy(link) } label: {
                            Text(copied ? L10n.tr("copiado") : L10n.tr("copiar"))
                                .font(theme.sans.font(size: 12, weight: .medium))
                                .foregroundStyle(theme.accentInk.color)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusRing(cornerRadius: theme.modalButtonRadius)
                    }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let destino = MeetingLink.destino(detail.meetingLink) {
                Button { abreLink(destino) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "video.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .accessibilityHidden(true)
                        Text(L10n.tr("Entrar"))
                    }
                    .font(theme.sans.font(size: 16, weight: .bold))
                    .foregroundStyle(theme.onAccent.color)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 15)
                    .background(
                        theme.accent.color,
                        in: RoundedRectangle(
                            cornerRadius: theme.modalButtonRadius, style: .continuous
                        )
                    )
                    .shadow(theme.modalAccentGlow)
                    .contentShape(RoundedRectangle(cornerRadius: theme.modalButtonRadius))
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: theme.modalButtonRadius, tint: \.onAccent)
                .help(L10n.tr("Abrir a reunião no navegador"))
                .accessibilityIdentifier("event-join")
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 20)
        .background(
            theme.accentSoft.color,
            in: RoundedRectangle(cornerRadius: theme.modalFieldRadius, style: .continuous)
        )
        .padding(.horizontal, Theme.modalSide)
        .padding(.top, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Começa em \(texto)"))
    }

    // MARK: - Para chegar pronto

    private var prepLines: [EventPrep.Line] {
        EventPrep.lines(
            guests: guests, messages: store.messages, me: account?.address ?? ""
        )
    }

    /// `border: 1px solid line; border-radius: 12; margin: 14px 28px 0;
    /// padding: 14px 16px`, com o rótulo no acento e um ponto por linha.
    ///
    /// Só com e-mail de verdade destas pessoas — ver `EventPrep`.
    private var prep: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.accentInk.color)
                    .accessibilityHidden(true)
                ModalEyebrow(text: L10n.tr("Para chegar pronto"), accented: true)
            }
            ForEach(prepLines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    ModalBullet(size: 6, color: theme.liveMeeting)
                    Text("\(line.who): \(line.what)")
                        .font(theme.sans.font(size: 13.5))
                        .lineSpacing(0.45 * 13.5)
                        .foregroundStyle(theme.ink.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { store.reveal(line.id) } label: {
                        Text(L10n.tr("Ler"))
                            .font(theme.sans.font(size: 13, weight: .medium))
                            .foregroundStyle(theme.accentInk.color)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusRing(cornerRadius: theme.modalButtonRadius)
                }
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: theme.modalFieldRadius, style: .continuous)
                .strokeBorder(theme.modalLine.color, lineWidth: Hairline.thickness(displayScale))
        }
        .padding(.horizontal, Theme.modalSide)
        .padding(.top, 14)
    }

    // MARK: - Você vai?

    /// O convite ao qual se pode responder, e a resposta já dada.
    ///
    /// Existe **só** quando o compromisso nasceu de um convite que ainda está
    /// na caixa: é de lá que sai o `text/calendar` com `UID` e `ORGANIZER`, e
    /// sem eles não há `METHOD:REPLY` a enviar. Compromisso criado aqui ou
    /// vindo do Calendário do sistema não mostra a linha — o brief pede
    /// exatamente isso.
    private var rsvp: (invite: CalendarInvite, message: Message, response: InviteRSVPResponse?)? {
        guard let id = originMessageID, let message = store.message(id),
              let invite = ReaderPane.convite(de: message),
              store.inviteRSVPUnavailableReason(for: invite, from: message) == nil
        else { return nil }
        return (invite, message, store.inviteRSVPState(for: invite, from: message))
    }

    /// `border-top` e `border-bottom` de um pixel, `padding: 10px 0`, com
    /// "Você vai?" à esquerda e os três botões à direita. O escolhido fica em
    /// verde com borda; os outros dois, contornados.
    private func rsvpRow(
        _ rsvp: (invite: CalendarInvite, message: Message, response: InviteRSVPResponse?)
    ) -> some View {
        HStack(spacing: 12) {
            Text(L10n.tr("Você vai?"))
                .font(theme.sans.font(size: 13.5))
                .foregroundStyle(theme.ink3.color)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                ForEach(InviteRSVPResponse.allCases, id: \.self) { response in
                    rsvpButton(response, rsvp: rsvp)
                }
            }
        }
        .padding(.vertical, 10)
        .hairline(theme.modalLine, edges: .top)
        .hairline(theme.modalLine, edges: .bottom)
        .padding(.horizontal, Theme.modalSide)
        .padding(.top, 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Sua resposta ao convite"))
    }

    private func rsvpButton(
        _ response: InviteRSVPResponse,
        rsvp: (invite: CalendarInvite, message: Message, response: InviteRSVPResponse?)
    ) -> some View {
        let chosen = rsvp.response == response
        let accepted = response == .accepted
        return Button {
            _ = store.respondToInvite(rsvp.invite, from: rsvp.message, response: response)
        } label: {
            HStack(spacing: 6) {
                if chosen {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .accessibilityHidden(true)
                }
                Text(Self.rsvpLabel(response))
            }
            .font(theme.sans.font(size: 13, weight: chosen ? .semibold : .medium))
            .foregroundStyle(
                (chosen ? (accepted ? theme.modalGreen : theme.accentInk) : theme.ink2).color
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                chosen
                    ? (accepted ? theme.modalGreen : theme.accent).color.opacity(0.12)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: theme.modalButtonRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: theme.modalButtonRadius, style: .continuous)
                    .strokeBorder(
                        chosen
                            ? (accepted ? theme.modalGreen : theme.accent).color
                            : theme.modalLine.color,
                        lineWidth: Hairline.thickness(displayScale)
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: theme.modalButtonRadius))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.modalButtonRadius)
        .accessibilityAddTraits(chosen ? [.isSelected] : [])
    }

    /// "Vou · Talvez · Não vou", como o desenho escreve — e não o "Aceitar ·
    /// Talvez · Recusar" do cartão da Caixa. Ali a pessoa está decidindo sobre
    /// um convite que chegou; aqui ela está olhando o compromisso dela, e a
    /// pergunta é "você vai?".
    nonisolated static func rsvpLabel(_ response: InviteRSVPResponse) -> String {
        switch response {
        case .accepted: L10n.tr("Vou")
        case .tentative: L10n.tr("Talvez")
        case .declined: L10n.tr("Não vou")
        }
    }

    /// Âncora do fim do modal, para o painel de encaminhar entrar na vista.
    private static let bottomAnchor = "uni.event.bottom"

    /// O título: a linha do calendário, o nome em 25 e o quando.
    ///
    /// Protótipo: `padding: 18px 28px 0; gap: 5px`. A barra de 3pt à esquerda
    /// saiu — no desenho dos modais a cor do calendário é o **quadradinho de
    /// 9pt** da primeira linha, junto do nome do calendário e de quem organiza.
    /// A barra vertical dizia a mesma coisa sem dizer de quem era.
    private func title(_ item: AgendaItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(CalendarEventChrome.bar(swatch, cancelled: item.isCancelled, theme: theme))
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
                Text(calendarLine)
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(theme.ink3.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if item.isCancelled {
                Text(L10n.tr("Cancelado"))
                    .font(theme.mono.font(size: 8.5, weight: .medium))
                    .tracking(theme.capsTracking(at: 8.5))
                    .textCase(.uppercase)
                    .foregroundStyle(theme.ink4.color)
            }
            CalendarEventChrome.title(item.title, cancelled: item.isCancelled)
                .font(theme.sans.font(size: 25, weight: .bold))
                .tracking(theme.modalTitleTracking(at: 25))
                .foregroundStyle((item.isCancelled ? theme.ink4 : theme.ink).color)
                .fixedSize(horizontal: false, vertical: true)
            Text(whenLine(item))
                .font(theme.sans.font(size: 14.5))
                .foregroundStyle((item.isCancelled ? theme.ink4 : theme.ink2).color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.modalSide)
        .padding(.top, 18)
    }

    /// "Aitherion · Time · organiza Marina Costa" — a conta, o aviso de
    /// sincronia e quem organiza, numa linha.
    private var calendarLine: String {
        var partes: [String] = []
        if let host = account?.host, !host.isEmpty { partes.append(host) }
        if !detail.notice.isEmpty { partes.append(detail.notice) }
        let organizador = detail.organizer.name
        if !organizador.isEmpty { partes.append(L10n.tr("organiza \(organizador)")) }
        return partes.joined(separator: " · ")
    }

    /// "Hoje · 15:00 – 16:00 · Online", com a hora em mono semibold na tinta
    /// cheia — ela é o que se procura nesta linha.
    private func whenLine(_ item: AgendaItem) -> AttributedString {
        var linha = AttributedString(DateLabels.eventDate(store.agendaDate(for: item)) + " · ")
        linha.foregroundColor = theme.ink2.color
        var hora = AttributedString(item.rangeLabel)
        hora.font = theme.mono.font(size: 14.5, weight: .semibold)
        hora.foregroundColor = theme.ink.color
        linha.append(hora)
        var cauda = AttributedString(
            " · " + detail.place + " · " + RecurrenceRule.display(detail.recurrence)
        )
        cauda.foregroundColor = theme.ink2.color
        linha.append(cauda)
        return linha
    }

    /// Protótipo: `margin: 14px 20px 0; padding: 12px 14px; background:
    /// var(--accent-soft); border: 0.5px solid var(--accent-line)`.
    private func linkCard(_ link: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("Link da reunião"))
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
                    .help(L10n.tr("Abrir a reunião no navegador"))
                } else {
                    Text(link)
                        .font(theme.mono.font(size: 11.5))
                        .foregroundStyle(theme.ink.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            ChromeButton(
                copied ? L10n.tr("Link copiado ✓") : L10n.tr("Copiar link"),
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
            field(L10n.tr("Local"), value: plain(detail.place))
            field(L10n.tr("Conta"), value: plain("\(account?.host ?? "—") · \(detail.notice)"))
            // Protótipo: o nome em `--ink` e o endereço em `--ink3`, na mesma
            // linha. Dois `Text` somados dariam depreciação no macOS 26.
            field(L10n.tr("Organiza"), value: Self.organizerLine(
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

    /// Quem vai: avatar de 24, nome em 13,5 e o estado em 12,5 na cor dele.
    ///
    /// Protótipo: `padding: 6px 28px 0`, linhas de `padding: 8px 0`. O endereço
    /// saiu da linha — o desenho mostra nome e estado, e o endereço inteiro de
    /// quatro pessoas era a parte que empurrava a pauta para fora da vista.
    /// Ele continua no `help` de cada linha.
    ///
    /// **Nasce recolhida** — pedido do dono, de antes deste desenho: oito
    /// participantes tomavam a janela e empurravam para fora o quando, o onde e
    /// o link. O cabeçalho conta quantos são; o clique abre o resto.
    private var people: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(
                title: L10n.tr("Participantes · \(detail.guestCount)"),
                expanded: sections.participants,
                help: sections.participants
                    ? L10n.tr("Recolher a lista de participantes")
                    : L10n.tr("Mostrar os \(detail.guestCount) participantes")
            ) {
                sections.toggleParticipants()
            }
            .padding(.bottom, 6)

            ForEach(EventSections.visibleGuests(guests, expanded: sections.participants)) { guest in
                HStack(spacing: 10) {
                    Text(guest.initials)
                        .font(theme.sans.font(size: 10, weight: .semibold))
                        .foregroundStyle(theme.onAccent.color)
                        .frame(width: 24, height: 24)
                        .background(theme.liveMeeting.color, in: Circle())
                        .accessibilityHidden(true)
                    Text(guest.name)
                        .font(theme.sans.font(size: 13.5))
                        .foregroundStyle(theme.ink.color)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Self.guestStatusLine(guest))
                        .font(theme.sans.font(size: 12.5))
                        .foregroundStyle(statusTint(guest.status).color)
                        .lineLimit(1)
                }
                .padding(.vertical, 8)
                .help("\(guest.name) · \(guest.address) · \(guest.role)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.modalSide)
        .padding(.top, 6)
    }

    /// "organiza · vai", "vai", "sem resposta" — o papel e a resposta na mesma
    /// frase, como o desenho escreve.
    nonisolated static func guestStatusLine(_ guest: EventPerson) -> String {
        let resposta: String = switch guest.status {
        case .yes: L10n.tr("vai")
        case .maybe: L10n.tr("talvez")
        case .pending: L10n.tr("sem resposta")
        }
        let papel = guest.role.trimmingCharacters(in: .whitespaces)
        guard !papel.isEmpty, papel.lowercased().contains("organiz") else { return resposta }
        return L10n.tr("organiza · \(resposta)")
    }

    private func statusTint(_ status: EventPerson.Status) -> TokenColor {
        switch status {
        case .yes: theme.modalGreen
        case .maybe: theme.warning
        case .pending: theme.ink3
        }
    }

    /// A pauta, numa linha: o rótulo em `ink3` e o texto em `ink2`.
    ///
    /// Protótipo: `border-top` de um pixel, `padding: 10px 0 0`, 13,5 com
    /// `line-height: 1.5`. Era uma seção com marcadores e um cabeçalho
    /// próprio; o desenho a põe como a última linha da lista de participantes,
    /// que é onde ela é lida — depois de saber quem vai.
    private var agenda: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(L10n.tr("Pauta"))
                .font(theme.sans.font(size: 13.5))
                .foregroundStyle(theme.ink3.color)
                .fixedSize()
            Text(detail.agenda.joined(separator: " "))
                .font(theme.sans.font(size: 13.5))
                .lineSpacing(0.5 * 13.5)
                .foregroundStyle(theme.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 10)
        .hairline(theme.modalLine, edges: .top)
        .padding(.horizontal, Theme.modalSide)
        .padding(.top, 4)
    }

    /// A `DESCRIPTION` do convite, inteira, no mesmo bloco da pauta.
    ///
    /// Inteira de propósito: é o que o organizador escreveu, e recortar
    /// escondia justamente o que costuma estar no fim — a instrução de entrar
    /// pelo telefone, o código da sala, o "leve a proposta impressa".
    @ViewBuilder
    private func descricao(_ texto: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: L10n.tr("Descrição"))
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
                    ? L10n.tr("Recolher o histórico deste compromisso")
                    : L10n.tr("Mostrar o email e a origem deste compromisso")
            ) {
                sections.toggleOrigin()
            }

            if sections.origin {
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(detail.thread) { entry in threadRow(entry) }
                    originPreview
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
            .help(L10n.tr("Mostrar na janela principal o email que gerou este compromisso"))
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

    /// A mensagem que gerou este compromisso, se ela ainda está na caixa.
    ///
    /// É a mesma `originMessageID` do botão "Email": um lugar só decide qual é
    /// o email de origem, e a prévia mostra o corpo **daquele**, não de um
    /// segundo palpite.
    private var originMessage: Message? {
        originMessageID.flatMap { id in store.messages.first { $0.id == id } }
    }

    /// Até onde a mensagem cresce dentro da seção antes de passar a rolar.
    ///
    /// O convite do dono é HTML-only e comprido; sem teto, a seção empurraria o
    /// resto da janela (encaminhar, nota, rodapé) para fora da vista a cada
    /// abertura. Com teto, a mensagem está toda ali e a janela continua sendo
    /// uma janela de compromisso.
    static let originBodyMaxHeight: CGFloat = 260

    /// O texto do email de origem — o dele mesmo, e não só o que o banco
    /// gravou como parágrafo.
    ///
    /// **Dois caminhos, e o segundo é o defeito da M3-21.** O convite do dono é
    /// `text/html` puro: o `body` dele está vazio e tudo o que a mensagem diz
    /// está no HTML. A seção lia só o `body`, e por isso ficava com a linha do
    /// email e o botão — a prévia da M3-14 nunca aparecia. Aqui o texto é
    /// derivado do HTML **na hora de exibir**, pelo mesmo `MimeHTML` que a
    /// decodificação usa; nada é gravado, e nenhuma `WebView` entra nesta
    /// janela.
    private var originBody: [String] {
        guard let mensagem = originMessage else { return [] }
        let gravado = EventSections.bodyPreview(mensagem.body)
        guard gravado.isEmpty, let pagina = mensagem.bodyHTML, !pagina.isEmpty else {
            return gravado
        }
        return EventSections.bodyPreview(
            GmailMessageParser.paragraphs(from: MimeBody.textFromHTML(pagina))
        )
    }

    /// O email, e o salto para ele.
    ///
    /// **O que o dono pediu ao abrir a seção**: ela mostrava quem escreveu, o
    /// assunto, a data e a nota — o cabeçalho do email, e nada do email. Agora
    /// vem o texto plano inteiro, na tipografia do leitor, rolando dentro da
    /// seção acima de `originBodyMaxHeight`, e um "Abrir no leitor" explícito.
    ///
    /// **Não é o leitor.** O corpo em HTML, a política de conteúdo remoto e a
    /// faixa de confiança continuam morando no `ReaderPane`, que é onde a
    /// pessoa lê email; trazer tudo isso para dentro de uma janela de 560pt
    /// seria uma segunda tela de leitura para manter em dia. **`WebView` dentro
    /// da janela de compromisso continua sendo não** — o texto plano mais o
    /// salto é a versão honesta disso.
    ///
    /// **Sem corpo no banco, a janela busca.** Era o beco da M3-14: "esta
    /// janela não pede rede", e a seção ficava com a linha e o botão para
    /// sempre. Ela pede pela mesma porta do leitor
    /// (`MessageStore.loadBodyIfNeeded`, que já é uma tentativa por abertura e
    /// grava a resposta no banco), e mostra o mesmo "Carregando corpo…" da M3-3
    /// enquanto isso.
    @ViewBuilder
    private var originPreview: some View {
        let paragrafos = originBody
        if !paragrafos.isEmpty || originMessageID != nil {
            VStack(alignment: .leading, spacing: 7) {
                if paragrafos.isEmpty {
                    if case .carregando = store.bodyLoad(for: originMessageID ?? "") {
                        Text(ReaderPane.carregandoCorpo)
                            .font(theme.serif.font(size: 13.5))
                            .italic()
                            .foregroundStyle(theme.ink4.color)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(Array(paragrafos.enumerated()), id: \.offset) { _, paragrafo in
                                Text(paragrafo)
                                    .font(theme.serif.font(size: 13.5))
                                    .lineSpacing(0.45 * 13.5)
                                    .foregroundStyle(theme.ink.color)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: Self.originBodyMaxHeight)
                }

                if originMessageID != nil {
                    ChromeButton(
                        L10n.tr("Abrir no leitor"), appearance: .outlined, size: 11.5,
                        weight: .semibold, height: 26, horizontalPadding: 11
                    ) {
                        revealOriginMessage()
                    }
                    .help(L10n.tr("Abrir na janela principal o email que gerou este compromisso"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // A busca acontece quando a seção está **aberta**: um compromisso
            // com a seção recolhida não paga viagem nenhuma.
            .task(id: originMessageID) {
                guard let id = originMessageID else { return }
                await store.loadBodyIfNeeded(id)
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
        case .ai: theme.info.color
        case .system: theme.ink4.color
        }
    }

    /// Protótipo: `margin: 18px 20px 0; padding: 14px; border: 0.5px solid var(--accent)`.
    private var forwardPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.tr("Encaminhar convite"))
                .font(theme.mono.font(size: 8.5, weight: .medium))
                .tracking(theme.capsTracking(at: 8.5))
                .textCase(.uppercase)
                .foregroundStyle(theme.accentInk.color)
                .padding(.bottom, 10)

            RecipientField(
                label: nil,
                placeholder: L10n.tr("quem do time precisa entrar; "),
                inputMinWidth: 150,
                menuWidth: 320,
                pool: store.contactPool,
                chips: $forwardTo,
                seededQuery: seededForwardQuery
            )
            .padding(.bottom, 9)
            .hairline(theme.line, edges: .bottom)
            // Protótipo: `z-index: 50` no menu. Sem isto, o recado e os botões
            // — irmãos posteriores na pilha — pintam por cima das sugestões.
            .zIndex(50)

            TextField(L10n.tr("Recado opcional para quem vai receber…"), text: $forwardNote)
                .textFieldStyle(.plain)
                .font(theme.serif.font(size: 14))
                .foregroundStyle(theme.ink.color)
                .padding(.top, 10)

            HStack(spacing: 8) {
                ChromeButton(
                    L10n.tr("Encaminhar"),
                    appearance: canForwardInvite ? .accent : .muted,
                    size: 12.5, weight: .semibold, height: 30
                ) {
                    forwardInvite()
                }
                .disabled(!canForwardInvite)
                .help(forwardHelp)
                ChromeButton(L10n.tr("Cancelar"), appearance: .outlined, height: 30, horizontalPadding: 12) {
                    forwardOpen = false
                    forwardTo = []
                    forwardNote = ""
                }
                Spacer(minLength: 8)
                // Protótipo: "o convite vai com o link e a pauta". A pauta não
                // vai — o corpo é o **mesmo** texto de "Copiar convite"
                // (`ContextMenus.inviteText`): título, dia e horário, local,
                // link e participantes. Dizer "pauta" numa mensagem que não a
                // leva é a legenda mentindo sobre o botão.
                Text(L10n.tr("o convite vai com o link e os participantes"))
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
            Text(L10n.tr("Convite encaminhado para \(forwardTo.count) \(forwardTo.count == 1 ? L10n.tr("pessoa") : L10n.tr("pessoas"))"))
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

    /// O rodapé: **links**, não botões.
    ///
    /// Protótipo: `padding: 14px 28px 18px`, a linha de um pixel em cima,
    /// `font-size: 13`. À esquerda o que abre coisas ("Abrir o e-mail que
    /// gerou", "Encaminhar convite"), à direita o destrutivo em vermelho com a
    /// consequência escrita ao lado: "Cancelar reunião · avisa todos".
    ///
    /// Eram seis pastilhas numa barra de `surface2`, "Entrar" entre elas, e um
    /// `×` no canto. Duas coisas mudaram de lugar e ficaram melhores: **Entrar**
    /// subiu para o bloco da contagem, onde é a ação do momento, e **fechar**
    /// voltou a ser o semáforo vermelho da janela, que é onde o macOS o põe.
    private var footer: some View {
        HStack(spacing: 18) {
            // **Entrar fica no rodapé quando não há contagem.** O desenho só
            // mostra a janela a doze minutos da reunião, e ali o Entrar grande
            // do bloco da contagem é a ação do momento. Numa reunião de
            // quinta-feira esse bloco não existe — e sem esta linha a janela
            // deixaria de ter qualquer jeito de entrar, que é o defeito mais
            // caro que esta tela já teve (ver `abreLink`).
            if contagem == nil, let destino = MeetingLink.destino(detail.meetingLink) {
                footerLink(L10n.tr("Entrar")) { abreLink(destino) }
                    .help(L10n.tr("Abrir a reunião no navegador"))
                    .accessibilityIdentifier("event-join")
            }
            if detail.hasThread || originMessageID != nil {
                footerLink(L10n.tr("Abrir o e-mail que gerou"), enabled: originMessageID != nil) {
                    revealOriginMessage()
                }
                .help(
                    originMessageID == nil
                        ? L10n.tr("O email que gerou este compromisso não está mais na caixa")
                        : L10n.tr("Mostrar na janela principal o email que gerou este compromisso")
                )
            }
            footerLink(L10n.tr("Encaminhar convite"), accented: !forwardOpen) {
                forwardOpen.toggle()
                if forwardOpen { forwardSent = false }
            }
            .help(L10n.tr("Encaminhar o convite para outras pessoas"))

            Spacer(minLength: 8)

            if canCancelMeeting {
                destructiveLink(
                    cancelling ? L10n.tr("Cancelando…") : L10n.tr("Cancelar reunião"),
                    note: L10n.tr("avisa todos")
                ) { confirm = .cancelMeeting }
                .disabled(cancelling)
                .help(L10n.tr("Cancelar a reunião, avisar os convidados e tirar da agenda"))
            } else if canRemoveFromCalendar {
                destructiveLink(
                    L10n.tr("Remover do calendário"), note: L10n.tr("ninguém é avisado")
                ) { confirm = .removeFromCalendar }
                .help(L10n.tr("Tirar este compromisso do calendário"))
            }
        }
        .padding(.top, 14)
        .padding(.horizontal, Theme.modalSide)
        .padding(.bottom, 18)
        .hairline(theme.modalLine, edges: .top)
        .padding(.top, 14)
    }

    private func footerLink(
        _ title: String, enabled: Bool = true, accented: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(theme.sans.font(size: 13, weight: .medium))
                .foregroundStyle((enabled ? (accented ? theme.accentInk : theme.ink2) : theme.ink4).color)
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .focusRing(cornerRadius: theme.modalButtonRadius)
    }

    /// O destrutivo com a consequência ao lado, em `ink3` e peso normal: o que
    /// o clique faz **aos outros** não cabe num rótulo de botão, e sem isso
    /// "Cancelar" num rodapé lê como fechar a janela.
    private func destructiveLink(
        _ title: String, note: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(destructiveText(title, note: note))
                .lineLimit(1)
                // O destrutivo não cede: cortado, "Remover do calendário ·
                // ninguém é avi…" esconde justamente a consequência, que é a
                // razão de a frase existir.
                .fixedSize()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: theme.modalButtonRadius)
        .accessibilityLabel("\(title) — \(note)")
    }

    private func destructiveText(_ title: String, note: String) -> AttributedString {
        var linha = AttributedString(title)
        linha.font = theme.sans.font(size: 13, weight: .medium)
        linha.foregroundColor = theme.modalRed.color
        var cauda = AttributedString(" · " + note)
        cauda.font = theme.sans.font(size: 13)
        cauda.foregroundColor = theme.ink3.color
        linha.append(cauda)
        return linha
    }

    // MARK: - Encaminhar o convite

    /// O "Encaminhar" do painel só age com destinatário **e** conta.
    ///
    /// Sem conta não há de quem mandar: o convite sai por email, e email sai de
    /// uma conta. O botão apaga com o motivo no `help` — a regra do controle
    /// mudo, a mesma do "Email" do rodapé.
    private var canForwardInvite: Bool {
        Self.canForward(recipients: forwardTo.count, hasAccount: account != nil)
    }

    private var forwardHelp: String {
        Self.forwardHelp(
            recipients: forwardTo.count, account: account?.host, canSend: store.canSend
        )
    }

    nonisolated static func canForward(recipients: Int, hasAccount: Bool) -> Bool {
        recipients > 0 && hasAccount
    }

    nonisolated static func forwardHelp(recipients: Int, account: String?, canSend: Bool) -> String {
        guard let account else {
            return L10n.tr("Encaminhar — indisponível: este compromisso não está ligado a nenhuma conta, ")
                + L10n.tr("e o convite sai por email de uma conta.")
        }
        guard recipients > 0 else {
            return L10n.tr("Encaminhar — indisponível: escolha quem vai receber o convite.")
        }
        guard canSend else {
            return L10n.tr("Este marco não tem rede: o convite fica registrado no console.")
        }
        return L10n.tr("Põe o convite na fila de saída da conta \(account).")
    }

    private func forwardInvite() {
        guard let item, canForwardInvite else { return }
        guard Self.forwardInvite(
            item, detail: detail,
            // A mesma data que o cabeçalho desta janela mostra: o corpo do
            // convite e o que se lê na tela não podem discordar.
            date: store.agendaDate(for: item),
            to: forwardTo, note: forwardNote, in: store
        ) else { return }
        forwardSent = true
        forwardOpen = false
        forwardNote = ""
    }

    /// O que o "Encaminhar convite" de fato faz, num lugar que o teste alcança
    /// sem clique — o `@MainActor` é do `MailStore`, não da `View`.
    ///
    /// **Sem protocolo novo, e sem anexo.** O app ainda não tem anexos, então o
    /// `.ics` original não vai junto — dívida registrada. O que vai é o convite
    /// em texto, o **mesmo** de "Copiar convite" (`ContextMenus.inviteText`):
    /// título, dia e horário, local, link e participantes. Um segundo formato
    /// aqui divergiria do que a agenda copia no primeiro ajuste, e o link é o
    /// mínimo útil de verdade para quem recebe.
    ///
    /// A conta é a do compromisso (`AgendaItem.accountID`, desde a M3-11) —
    /// nunca um endereço cravado. Sem conta, ou sem porta de envio, vale o que
    /// valia: a linha no console e a confirmação na janela.
    ///
    /// Devolve se o painel pode fechar. `false` é "não saiu": o painel fica
    /// aberto com quem já foi escolhido, e o erro já está no `loadError`.
    @MainActor
    static func forwardInvite(
        _ item: AgendaItem,
        detail: EventDetail,
        date: Date,
        to: [Contact],
        note: String,
        in store: MailStore
    ) -> Bool {
        guard !to.isEmpty, let account = store.account(item.accountID) else { return false }
        guard store.canSend else {
            UNIWindow.logSend(
                "Encaminharia o convite para [\(to.map(\.address).joined(separator: ", "))]."
            )
            return true
        }
        let mensagem = ComposerOutgoing.message(
            accountID: account.id,
            from: Contact(name: account.displayName, address: account.address),
            to: to, cc: [], bcc: [],
            subject: forwardSubject(item.title),
            plainText: inviteBody(item, detail: detail, date: date, note: note),
            html: nil
        )
        return store.send(mensagem)
    }

    /// "Enc: " como em `ComposerSeed.forward` — encaminhar um convite e
    /// encaminhar um email não podem chegar com dois prefixos diferentes na
    /// mesma caixa. Compromisso sem título não vira "Enc: " pendurado.
    nonisolated static func forwardSubject(_ title: String) -> String {
        title.isEmpty ? L10n.tr("Enc: convite") : L10n.tr("Enc: \(title)")
    }

    /// O recado opcional em cima, o convite embaixo, separados por uma linha em
    /// branco. Recado só de espaços não abre parágrafo nenhum.
    nonisolated static func inviteBody(
        _ item: AgendaItem, detail: EventDetail, date: Date, note: String
    ) -> String {
        let convite = ContextMenus.inviteText(item, detail: detail, date: date)
        let recado = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return recado.isEmpty ? convite : "\(recado)\n\n\(convite)"
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
    func performCancel() {
        guard let item, canCancelMeeting, !cancelling else { return }
        cancelling = true
        let oauthID = account.flatMap {
            MeetingGoogleAccount.resolve(for: $0, among: store.accounts)?.id
        } ?? item.accountID
        let start = Calendar.current.date(
            byAdding: .minute,
            value: item.startMinute,
            to: Calendar.current.startOfDay(for: store.agendaDate(for: item))
        ) ?? store.agendaDate(for: item)
        Task { @MainActor in
            await meetingFactory?.deleteGoogleMeet(
                accountID: oauthID,
                eventID: item.calendarUID,
                hangoutLink: detail.meetingLink,
                start: start
            )
            store.cancelMeeting(item.id)
            dismiss()
        }
    }

    func performRemove() {
        guard let item, canRemoveFromCalendar else { return }
        store.removeFromAgenda(item.id)
        dismiss()
    }

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

#if os(macOS)
#Preview("04 Detalhe do compromisso") {
    EventWindow(store: MailStore(source: InMemoryMailSource.fixtures), itemID: "e2")
        .environment(ThemeStore())
        .frame(width: 560, height: 788)
}
#endif
