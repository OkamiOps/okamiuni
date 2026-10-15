import AppKit
import SwiftUI
import UNICore
import UNIDesign
import UNISync

/// A aba **Agendas** das Configurações, de `ConfigAgendas.dc.html`.
///
/// Duas colunas. À esquerda, de onde as agendas vêm: cada fonte com as suas,
/// cada agenda com cor, nome e um interruptor de mostrar ou ocultar. À
/// direita, com o que um evento novo nasce e as salas de reunião.
///
/// ## O interruptor é o mesmo da grade
///
/// Mostrar ou ocultar uma agenda já existia — na página da conta, e antes
/// disso na lateral da Agenda. A preferência é uma só
/// (`MailStore.hiddenCalendarIDs`): duas telas escrevendo em dois lugares
/// seria o mesmo ajuste com duas respostas. A página da conta agora traz só
/// uma linha que leva até aqui.
///
/// ## O que o desenho tem e esta página não
///
/// A linha **Fuso**. O app inteiro lê `Calendar.current`; guardar outro fuso
/// aqui não mudaria uma única hora na grade, e um seletor que não muda nada
/// ensina a desconfiar dos outros cinco. Ela volta quando o app tiver fuso de
/// verdade.
struct ConfigAgendas: View {
    @Environment(\.theme) private var theme
    @Environment(\.configPalette) private var palette
    @Environment(\.displayScale) private var displayScale

    let mailStore: MailStore?
    let preferences: CalendarPreferences?
    let connections: MeetingConnections?
    /// Só para a **migração**: o serviço padrão que era por conta sobe uma vez
    /// para `CalendarPreferences.defaultRoom` e depois ninguém mais o lê.
    let legacyRooms: MeetingRoomSettingsStore?
    let accounts: [AccountStatus]
    /// Abre a folha de adicionar conta da janela — é por onde Google e
    /// CalDAV entram, porque uma agenda nova é sempre uma conta nova.
    let addAccount: () -> Void

    @State private var connecting = false
    @State private var now = Date()

    /// `column-gap: 34px` do desenho.
    private let columnGap: CGFloat = 34

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: columnGap) {
                calendarsColumn.frame(maxWidth: .infinity, alignment: .leading)
                rightColumn.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
        .task {
            if let preferences, let legacyRooms {
                preferences.migrateRoom(
                    from: legacyRooms, accountIDs: accounts.map(\.accountID)
                )
            }
            await connections?.refresh()
        }
        .sheet(isPresented: $connecting) {
            ConnectCalendarSheet(
                close: { connecting = false },
                addAccount: {
                    connecting = false
                    addAccount()
                }
            )
            .environment(\.theme, theme)
            .environment(\.configPalette, palette)
        }
    }

    // MARK: - Coluna 1 · Suas agendas

    private var sources: [AgendaSource] {
        AgendaSources.build(
            calendars: mailStore?.calendarsForSidebar ?? [],
            accounts: accounts,
            availability: mailStore?.calendarAvailability,
            now: now
        )
    }

    private var calendarsColumn: some View {
        let list = sources
        return VStack(alignment: .leading, spacing: 9) {
            ConfigBlockTitle(
                text: L10n.tr("Suas agendas"),
                note: AgendaSources.countNote(list)
            )
            VStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.id) { index, source in
                    sourceBlock(source, first: index == 0)
                }
                connectRow(first: list.isEmpty)
            }
            .configCard(palette, radius: 14, shadow: palette.sectionShadow)
            Text(L10n.tr("Ocultar uma agenda só muda o que você vê aqui — nada é apagado no servidor nem no Calendário do Mac."))
                .font(theme.sans.font(size: 12))
                .lineSpacing(12 * 0.5)
                .foregroundStyle(palette.ink3.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func sourceBlock(_ source: AgendaSource, first: Bool) -> some View {
        if source.kind == .eventKit,
           AgendaSources.needsCalendarPermission(mailStore?.calendarAvailability)
        {
            permissionNotice(first: first)
        } else {
            VStack(spacing: 0) {
                sourceHeader(source)
                    .padding(.horizontal, 15)
                    .padding(.top, 11)
                    .padding(.bottom, 9)
                    .overlay(alignment: .top) { if !first { divider } }
                ForEach(source.calendars) { calendarRow($0) }
                Color.clear.frame(height: 5)
            }
        }
    }

    /// `grid-template-columns: 28px minmax(0,1fr) auto; gap: 11px`.
    private func sourceHeader(_ source: AgendaSource) -> some View {
        HStack(spacing: 11) {
            monogram(source.monogram, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.title)
                    .font(theme.sans.font(size: 14, weight: .semibold))
                    .foregroundStyle(palette.ink.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(source.subtitle)
                    .font(theme.sans.font(size: 12))
                    .foregroundStyle(palette.ink3.color)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Circle()
                    .fill(tone(source.tone).color)
                    .frame(width: 6, height: 6)
                Text(source.state)
                    .font(theme.sans.font(size: 12, weight: .medium))
                    .foregroundStyle(tone(source.tone).color)
                    .lineLimit(1)
            }
        }
    }

    /// `padding: 7px 15px 7px 26px`, com a bolinha de 12, o nome, a marca de
    /// só leitura e o interruptor.
    private func calendarRow(_ connected: ConnectedCalendar) -> some View {
        let on = mailStore?.isCalendarEnabled(connected.id) ?? true
        let tint = TokenColor(css: connected.colorHex) ?? palette.accent
        return HStack(spacing: 11) {
            Circle()
                .fill(tint.color)
                .frame(width: 12, height: 12)
                .overlay { Circle().strokeBorder(palette.line.color, lineWidth: 1) }
            Text(connected.title)
                .font(theme.sans.font(size: 13.5, weight: .medium))
                .foregroundStyle((on ? palette.ink : palette.ink3).color)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if !connected.allowsModifications {
                Text(L10n.tr("só leitura"))
                    .font(theme.sans.font(size: 11.5))
                    .foregroundStyle(palette.ink3.color)
            }
            ConfigSwitch(
                isOn: Binding(
                    get: { on },
                    set: { _ in mailStore?.toggleCalendar(connected.id) }
                ),
                label: L10n.tr("Mostrar \(connected.title)")
            )
        }
        .padding(.leading, 26)
        .padding(.trailing, 15)
        .padding(.vertical, 7)
    }

    /// O bloco laranja que substitui a lista do Mac quando o macOS negou.
    private func permissionNotice(first: Bool) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.orange.color)
                .frame(width: 28, height: 28)
                .background(
                    palette.orange.color.opacity(0.16),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 7) {
                Text(L10n.tr("Sem permissão para o Calendário do Mac"))
                    .font(theme.sans.font(size: 14, weight: .semibold))
                    .foregroundStyle(palette.ink.color)
                Text(L10n.tr("O macOS negou o acesso, então as agendas deste Mac não aparecem. Autorize o OkamiUNI em Privacidade e Segurança ▸ Calendários."))
                    .font(theme.sans.font(size: 12.5))
                    .lineSpacing(12.5 * 0.45)
                    .foregroundStyle(palette.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(L10n.tr("Abrir os Ajustes do Sistema"), action: openPrivacySettings)
                        .buttonStyle(.plain)
                        .configPrimaryButton(
                            palette, font: theme.sans.font(size: 12.5, weight: .semibold),
                            radius: 10, horizontal: 13, vertical: 8
                        )
                    Button(L10n.tr("Tentar de novo"), action: requestCalendarAccess)
                        .buttonStyle(.plain)
                        .configQuietButton(
                            palette, font: theme.sans.font(size: 12.5, weight: .medium),
                            radius: 10, horizontal: 12, vertical: 7
                        )
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 15)
        .padding(.top, 13)
        .padding(.bottom, 14)
        .background(palette.orange.color.opacity(theme.isDark ? 0.07 : 0.05))
        .overlay(alignment: .top) { if !first { divider } }
    }

    private func connectRow(first: Bool) -> some View {
        Button { connecting = true } label: {
            HStack(spacing: 11) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.accentInk.color)
                    .frame(width: 28, height: 28)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(
                                palette.line.color,
                                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                            )
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.tr("Conectar outra agenda"))
                        .font(theme.sans.font(size: 13.5, weight: .semibold))
                        .foregroundStyle(palette.accentInk.color)
                    Text(L10n.tr("Google, iCloud, Outlook ou um servidor CalDAV"))
                        .font(theme.sans.font(size: 12))
                        .foregroundStyle(palette.ink3.color)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 11)
            .overlay(alignment: .top) { if !first { divider } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: 10)
    }

    // MARK: - Coluna 2 · Padrões e salas

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 13) {
            defaultsSection
            roomsSection
        }
    }

    @ViewBuilder
    private var defaultsSection: some View {
        if let preferences {
            VStack(alignment: .leading, spacing: 9) {
                ConfigBlockTitle(
                    text: L10n.tr("Padrões"),
                    note: L10n.tr("o que um evento novo já vem preenchido")
                )
                VStack(spacing: 0) {
                    defaultRow(L10n.tr("Agenda de eventos novos"), first: true) {
                        defaultCalendarPicker(preferences)
                    }
                    defaultRow(L10n.tr("Duração")) {
                        ConfigPicker(
                            options: CalendarPreferences.durationOptions.map {
                                ($0, durationLabel($0))
                            },
                            selection: Binding(
                                get: { preferences.durationMinutes },
                                set: { preferences.durationMinutes = $0 }
                            ),
                            accessibilityTitle: L10n.tr("Duração")
                        )
                    }
                    defaultRow(L10n.tr("Aviso")) {
                        ConfigPicker(
                            options: CalendarAlert.allCases.map { ($0, $0.label) },
                            selection: Binding(
                                get: { preferences.alert },
                                set: { preferences.alert = $0 }
                            ),
                            accessibilityTitle: L10n.tr("Aviso")
                        )
                    }
                    defaultRow(L10n.tr("A semana começa")) {
                        ConfigPicker(
                            options: CalendarWeekStart.allCases.map { ($0, $0.label) },
                            selection: Binding(
                                get: { preferences.weekStart },
                                set: { preferences.weekStart = $0 }
                            ),
                            accessibilityTitle: L10n.tr("A semana começa")
                        )
                    }
                    defaultRow(L10n.tr("Horário de trabalho")) {
                        ConfigPicker(
                            options: [(nil as WorkingHours?, L10n.tr("Sem realce"))]
                                + WorkingHours.options.map { (Optional($0), $0.label) },
                            selection: Binding(
                                get: { preferences.workingHours },
                                set: { preferences.workingHours = $0 }
                            ),
                            accessibilityTitle: L10n.tr("Horário de trabalho")
                        )
                    }
                }
                .configCard(palette, radius: 14, shadow: palette.sectionShadow)
            }
        }
    }

    private func defaultRow<Control: View>(
        _ label: String, first: Bool = false, @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(theme.sans.font(size: 13.5))
                .foregroundStyle(palette.ink2.color)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 7)
        .overlay(alignment: .top) { if !first { divider } }
    }

    private func defaultCalendarPicker(_ preferences: CalendarPreferences) -> some View {
        let writable = (mailStore?.calendarsForSidebar ?? []).filter(\.allowsModifications)
        let options: [(String?, String)] = [(nil, L10n.tr("A da conta"))]
            + writable.map { (Optional($0.id), $0.title) }
        let current = writable.first { $0.id == preferences.defaultCalendarID }
        return ConfigPicker(
            options: options,
            selection: Binding(
                get: { preferences.defaultCalendarID },
                set: { preferences.defaultCalendarID = $0 }
            ),
            accessibilityTitle: L10n.tr("Agenda de eventos novos")
        ) {
            HStack(spacing: 8) {
                Circle()
                    .fill((current.flatMap { TokenColor(css: $0.colorHex) } ?? palette.ink3).color)
                    .frame(width: 10, height: 10)
                Text(current?.title ?? L10n.tr("A da conta"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 190, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    @ViewBuilder
    private var roomsSection: some View {
        if let preferences {
            VStack(alignment: .leading, spacing: 9) {
                ConfigBlockTitle(
                    text: L10n.tr("Salas de reunião"),
                    note: L10n.tr("uma sala nova por evento")
                )
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text(L10n.tr("Sala padrão em eventos novos"))
                            .font(theme.sans.font(size: 13.5))
                            .foregroundStyle(palette.ink2.color)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        ConfigPicker(
                            options: [(nil as MeetingService?, L10n.tr("Nenhuma"))]
                                + MeetingService.allCases.map { (Optional($0), $0.label) },
                            selection: Binding(
                                get: { preferences.defaultRoom },
                                set: { preferences.defaultRoom = $0 }
                            ),
                            accessibilityTitle: L10n.tr("Sala padrão em eventos novos")
                        )
                    }
                    .padding(.horizontal, 15)
                    .padding(.vertical, 8)
                    ForEach(MeetingService.allCases) { roomRow($0) }
                }
                .configCard(palette, radius: 14, shadow: palette.sectionShadow)
                Text(L10n.tr("Cada um abre o login da sua conta no navegador — nada de client ID, segredo nem tenant."))
                    .font(theme.sans.font(size: 12))
                    .lineSpacing(12 * 0.5)
                    .foregroundStyle(palette.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    private func roomRow(_ service: MeetingService) -> some View {
        let state = connections?.state(of: service) ?? .unavailable
        return HStack(spacing: 11) {
            monogram(String(service.shortLabel.prefix(1)), size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(service.label)
                    .font(theme.sans.font(size: 13.5, weight: .semibold))
                    .foregroundStyle(palette.ink.color)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if case .waitingInBrowser = state {
                        Image(systemName: "circle.dotted")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(palette.accentInk.color)
                    } else {
                        Circle()
                            .fill(roomTone(state).color)
                            .frame(width: 6, height: 6)
                    }
                    Text(state.label)
                        .font(theme.sans.font(size: 12))
                        .foregroundStyle(roomTone(state).color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            roomActions(service, state: state)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 9)
        .overlay(alignment: .top) { divider }
    }

    @ViewBuilder
    private func roomActions(_ service: MeetingService, state: MeetingConnectionState) -> some View {
        switch MeetingRoomAction(state) {
        case .none:
            // **Sem botão.** Faltando o client ID, "Conectar" só poderia
            // falhar; a frase ao lado já diz o que está faltando.
            EmptyView()
        case .disconnect:
            Button(L10n.tr("Desconectar")) { connections?.disconnect(service) }
                .buttonStyle(.plain)
                .configQuietButton(
                    palette, font: theme.sans.font(size: 12.5, weight: .semibold),
                    radius: 10, horizontal: 13, vertical: 7
                )
        case .waiting:
            HStack(spacing: 7) {
                Button(L10n.tr("Cancelar")) { connections?.cancel(service) }
                    .buttonStyle(.plain)
                    .font(theme.sans.font(size: 12.5, weight: .medium))
                    .foregroundStyle(palette.ink3.color)
                Button(L10n.tr("Abrir de novo")) { connections?.connect(service) }
                    .buttonStyle(.plain)
                    .configQuietButton(
                        palette, font: theme.sans.font(size: 12.5, weight: .semibold),
                        radius: 10, horizontal: 13, vertical: 7
                    )
            }
        case .connect:
            Button(L10n.tr("Conectar")) { connections?.connect(service) }
                .buttonStyle(.plain)
                .configPrimaryButton(
                    palette, font: theme.sans.font(size: 12.5, weight: .semibold),
                    radius: 10, horizontal: 13, vertical: 7
                )
        }
    }

    // MARK: - Peças

    private func monogram(_ letter: String, size: CGFloat) -> some View {
        Text(letter)
            .font(theme.sans.font(size: 12, weight: .bold))
            .foregroundStyle(palette.ink2.color)
            .frame(width: size, height: size)
            .background(palette.field.color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(palette.line.color, lineWidth: Hairline.thickness(displayScale))
            }
    }

    private var divider: some View {
        Rectangle()
            .fill(palette.line.color)
            .frame(height: Hairline.thickness(displayScale))
    }

    private func tone(_ tone: AgendaSource.Tone) -> TokenColor {
        switch tone {
        case .green: palette.green
        case .orange: palette.orange
        case .quiet: palette.ink3
        }
    }

    private func roomTone(_ state: MeetingConnectionState) -> TokenColor {
        switch state {
        case .connected: palette.green
        case .waitingInBrowser: palette.accentInk
        case .failed: palette.orange
        case .disconnected, .unavailable: palette.ink3
        }
    }

    private func durationLabel(_ minutes: Int) -> String {
        minutes >= 60 && minutes % 60 == 0
            ? (minutes == 60 ? L10n.tr("1 hora") : L10n.tr("\(minutes / 60) horas"))
            : L10n.tr("\(minutes) min")
    }

    private func openPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func requestCalendarAccess() {
        guard let mailStore else { return }
        Task { await mailStore.refreshCalendar(requestAuthorization: true) }
    }
}

/// A folha "Conectar outra agenda": quatro caminhos, cada um dizendo o que vai
/// acontecer.
///
/// **Google** é o único que funciona hoje, e ele vai para a mesma folha de
/// adicionar conta que o resto da janela usa: uma agenda do Google é sempre a
/// agenda de uma caixa Google. iCloud e "Outro servidor CalDAV" ficam
/// explicados e desligados — ver a nota em cada um.
struct ConnectCalendarSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.configPalette) private var palette
    @Environment(\.displayScale) private var displayScale

    let close: () -> Void
    let addAccount: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            VStack(spacing: 2) {
                option(
                    monogram: "G",
                    title: "Google",
                    subtitle: L10n.tr("entra na sua conta Google no navegador"),
                    note: L10n.tr("Agenda e Meet"),
                    highlighted: true,
                    help: nil,
                    run: addAccount
                )
                option(
                    monogram: "i",
                    title: "iCloud",
                    subtitle: L10n.tr("seu Apple ID e uma senha de app"),
                    note: "CalDAV",
                    highlighted: false,
                    // O `CalDAVClient` aceita qualquer endereço, mas o app só
                    // sincroniza o CalDAV de uma **caixa de correio** já
                    // conectada, e `CalDAVPresets` conhece três servidores
                    // (Zoho, Yahoo, Fastmail). Uma agenda iCloud sem caixa
                    // iCloud não tem onde morar ainda.
                    help: L10n.tr("Ainda não: as agendas do iCloud entram pelo Calendário do Mac."),
                    run: nil
                )
                option(
                    monogram: "O",
                    title: L10n.tr("Outlook · Microsoft"),
                    subtitle: L10n.tr("entra na sua conta Microsoft no navegador"),
                    note: L10n.tr("Agenda e Teams"),
                    highlighted: false,
                    help: L10n.tr("em breve"),
                    run: nil
                )
                option(
                    monogram: "+",
                    title: L10n.tr("Outro servidor CalDAV"),
                    subtitle: L10n.tr("Fastmail, Yahoo, Zoho ou um endereço seu"),
                    note: L10n.tr("você digita o endereço"),
                    highlighted: false,
                    help: L10n.tr("Ainda não: a agenda vem junto com a caixa, em Adicionar conta."),
                    run: nil
                )
            }
            Text(L10n.tr("Se a conta de e-mail já está no OkamiUNI, a agenda dela entra sozinha — não precisa conectar de novo aqui. Senhas e tokens ficam no Keychain deste Mac."))
                .font(theme.sans.font(size: 12))
                .lineSpacing(12 * 0.5)
                .foregroundStyle(palette.ink3.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 13)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(palette.line.color)
                        .frame(height: Hairline.thickness(displayScale))
                }
        }
        .padding(.horizontal, 26)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(width: 560)
        .background(theme.glassWindow.color)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Conectar outra agenda"))
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(systemName: "calendar")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(palette.accentInk.color)
                .frame(width: 38, height: 38)
                .background(
                    palette.accentSoft.color,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("Conectar outra agenda"))
                    .font(theme.sans.font(size: 17, weight: .bold))
                    .tracking(-0.015 * 17)
                    .foregroundStyle(palette.ink.color)
                Text(L10n.tr("Você entra na sua conta no navegador. Nada de client ID nem segredo."))
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(palette.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.ink3.color)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusRing(cornerRadius: 10)
            .accessibilityLabel(L10n.tr("Fechar"))
            .keyboardShortcut(.cancelAction)
        }
    }

    private func option(
        monogram: String,
        title: String,
        subtitle: String,
        note: String,
        highlighted: Bool,
        help: String?,
        run: (() -> Void)?
    ) -> some View {
        Button { run?() } label: {
            HStack(spacing: 13) {
                Text(monogram)
                    .font(theme.sans.font(size: 13, weight: .bold))
                    .foregroundStyle(palette.ink2.color)
                    .frame(width: 32, height: 32)
                    .background(
                        palette.field.color,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(theme.sans.font(size: 14, weight: .semibold))
                        .foregroundStyle(palette.ink.color)
                    Text(help ?? subtitle)
                        .font(theme.sans.font(size: 12.5))
                        .foregroundStyle(palette.ink3.color)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 10)
                Text(note)
                    .font(theme.sans.font(size: 12))
                    .foregroundStyle(palette.ink3.color)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle((highlighted ? palette.accentInk : palette.ink3).color)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if highlighted {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(palette.accentSoft.color)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusRing(cornerRadius: 10)
        .disabled(run == nil)
        .opacity(run == nil ? 0.55 : 1)
    }
}
