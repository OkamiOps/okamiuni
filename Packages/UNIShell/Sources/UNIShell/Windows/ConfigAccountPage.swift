import SwiftUI
import UNICore
import UNIDesign
import UNISync

/// A página de uma conta. Ela absorve o que eram três seções separadas —
/// Agenda, Assinaturas e Remetentes — porque as três eram, na verdade,
/// perguntas sobre **uma conta**, e a pessoa tinha de ir a três lugares para
/// responder sobre a mesma caixa.
///
/// Duas colunas: à esquerda o que a conta faz (sincroniza, calendários, sala
/// de reunião, quem envia); à direita como ela chega ao outro lado (a
/// assinatura dentro de um e-mail de verdade) e a zona calma de remover.
struct ConfigAccountPage: View {
    @Environment(\.theme) private var theme
    @Environment(\.configPalette) private var palette
    @Environment(\.displayScale) private var displayScale

    let model: AccountsModel
    let status: AccountStatus
    let mailStore: MailStore?
    let meetingRooms: MeetingRoomSettingsStore?
    let remove: () -> Void
    @State private var editingSignature = false
    /// As conexões das salas de reunião (cliente e segredo de Zoom, Teams e
    /// Zoho) e o gerenciador completo de remetentes continuam existindo: o
    /// desenho não lhes deu um lugar na página, e escondê-los seria perder
    /// função. Cada um abre da linha a que pertence.
    @State private var editingRooms = false
    @State private var editingAliases = false
    @State private var addingAlias = false
    @State private var newAliasName = ""
    @State private var newAliasAddress = ""

    var body: some View {
        // A coluna da direita precisa de altura para a zona de remover encostar
        // no pé, como no desenho. Por isso o `ScrollView` ocupa a altura toda e
        // o conteúdo se estica dentro dela.
        GeometryReader { proxy in
            ScrollView {
                HStack(alignment: .top, spacing: ConfigMetrics.columnGap) {
                    leftColumn.frame(maxWidth: .infinity, alignment: .leading)
                    rightColumn.frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.bottom, 4)
                .frame(minHeight: proxy.size.height - 4, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .sheet(isPresented: $editingSignature) {
            ConfigSignatureSheet(model: model, accountID: status.accountID) {
                editingSignature = false
            }
        }
        .sheet(isPresented: $editingRooms) {
            ConfigSheet(title: L10n.tr("Salas de reunião")) { editingRooms = false } content: {
                AgendaSettingsView(rooms: meetingRooms, accounts: [status])
            }
        }
        .sheet(isPresented: $editingAliases) {
            ConfigSheet(title: L10n.tr("Quem envia por esta conta")) { editingAliases = false } content: {
                AliasSettingsView(model: model)
            }
        }
    }

    // MARK: A coluna da esquerda

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConfigBlockTitle(text: L10n.tr("O que sincroniza")).padding(.bottom, 4)
            syncRow(
                symbol: "envelope",
                label: L10n.tr("E-mail"),
                note: folderNote
            )
            syncRow(
                symbol: "calendar",
                label: L10n.tr("Agenda"),
                note: calendarNote
            )

            ConfigBlockTitle(text: L10n.tr("Calendários desta conta"))
                .padding(.top, 22)
                .padding(.bottom, 4)
            if accountCalendars.isEmpty {
                Text(L10n.tr("Nenhum calendário desta conta está visível no Mac."))
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(palette.ink3.color)
                    .padding(.vertical, 10)
            } else {
                ForEach(accountCalendars) { calendarRow($0) }
            }

            meetingRoomRow
                .padding(.top, 22)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ConfigBlockTitle(text: L10n.tr("Quem envia por esta conta"))
                Button(L10n.tr("Gerenciar")) { editingAliases = true }
                    .buttonStyle(.plain)
                    .font(theme.sans.font(size: 12.5, weight: .medium))
                    .foregroundStyle(palette.ink3.color)
            }
            .padding(.top, 22)
            .padding(.bottom, 4)
            ForEach(senders) { aliasRow($0) }
            newAliasRow
        }
    }

    private func syncRow(symbol: String, label: String, note: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.ink2.color)
                .frame(width: 17, height: 17)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(theme.sans.font(size: 14, weight: .medium))
                    .foregroundStyle(palette.ink.color)
                Text(note)
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(palette.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            // A conta sincroniza as duas coisas enquanto existe; desligar uma
            // delas não é uma preferência que o app guarda. O interruptor é
            // desenhado ligado e **não** finge ser clicável.
            ConfigSwitchStatic(on: true, label: label)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) { divider }
    }

    private func calendarRow(_ calendar: ConnectedCalendar) -> some View {
        let on = mailStore?.isCalendarEnabled(calendar.id) ?? true
        let tint = TokenColor(css: calendar.colorHex) ?? palette.accent
        return Button { mailStore?.toggleCalendar(calendar.id) } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(on ? tint.color : Color.clear)
                    .frame(width: 16, height: 16)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(tint.color, lineWidth: 1.5)
                    }
                    .overlay {
                        if on {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .heavy))
                                .foregroundStyle(Color.white)
                        }
                    }
                Text(calendar.title)
                    .font(theme.sans.font(size: 14))
                    .foregroundStyle((on ? palette.ink : palette.ink3).color)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(calendar.allowsModifications ? "" : L10n.tr("só leitura"))
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(palette.ink3.color)
            }
            .padding(.vertical, 10)
            .overlay(alignment: .top) { divider }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(calendar.title)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private var meetingRoomRow: some View {
        ConfigRow(
            label: L10n.tr("Sala de reunião"),
            note: needsRoomConnection
                ? L10n.tr("este serviço precisa da API dele — toque em Conectar")
                : L10n.tr("entra em todo compromisso novo desta conta"),
            verticalPadding: 12
        ) {
            if needsRoomConnection {
                Button(L10n.tr("Conectar")) { editingRooms = true }
                    .buttonStyle(.plain)
                    .font(theme.sans.font(size: 13, weight: .medium))
                    .foregroundStyle(palette.accentInk.color)
            }
            if let meetingRooms {
                ConfigPicker(
                    options: [(nil as MeetingService?, L10n.tr("Nenhuma"))]
                        + MeetingService.allCases.map { (Optional($0), $0.label) },
                    selection: Binding(
                        get: { meetingRooms.profile(for: status.accountID).defaultService },
                        set: { meetingRooms.setDefault($0, for: status.accountID) }
                    ),
                    accessibilityTitle: L10n.tr("Sala de reunião")
                ) {
                    let service = meetingRooms.profile(for: status.accountID).defaultService
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill((service == nil ? palette.ink3 : palette.green).color)
                            .frame(width: 8, height: 8)
                        Text(service?.label ?? L10n.tr("Nenhuma"))
                    }
                }
            } else {
                Text(L10n.tr("indisponível nesta janela"))
                    .font(theme.sans.font(size: 13))
                    .foregroundStyle(palette.ink3.color)
            }
        }
    }

    private func aliasRow(_ alias: SendAlias) -> some View {
        Button { makeDefault(alias) } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            (alias.isDefault ? palette.accent : palette.off).color,
                            lineWidth: alias.isDefault ? 5.5 : 1.5
                        )
                        .frame(width: 18, height: 18)
                    if alias.isDefault {
                        Circle().fill(palette.onAccent.color).frame(width: 8, height: 8)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(alias.displayName.isEmpty ? alias.address : alias.displayName)
                        .font(theme.sans.font(size: 14, weight: .medium))
                        .foregroundStyle(palette.ink.color)
                        .lineLimit(1)
                    Text(alias.address)
                        .font(theme.mono.font(size: 12))
                        .foregroundStyle(palette.ink3.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Text(aliasNote(alias))
                    .font(theme.sans.font(size: 12.5))
                    .foregroundStyle(palette.ink3.color)
            }
            .padding(.vertical, 11)
            .overlay(alignment: .top) { divider }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(alias.address)
        .accessibilityAddTraits(alias.isDefault ? [.isSelected] : [])
    }

    @ViewBuilder
    private var newAliasRow: some View {
        if addingAlias {
            VStack(alignment: .leading, spacing: 8) {
                TextField(L10n.tr("Nome exibido"), text: $newAliasName)
                    .textFieldStyle(.roundedBorder)
                TextField("nome@empresa.com", text: $newAliasAddress)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 9) {
                    Button(L10n.tr("Adicionar")) { commitAlias() }
                        .buttonStyle(.plain)
                        .configPrimaryButton(
                            palette, font: theme.sans.font(size: 13, weight: .semibold),
                            radius: 9, horizontal: 13, vertical: 7
                        )
                        .disabled(!canCommitAlias)
                    Button(L10n.tr("Cancelar")) { cancelAlias() }
                        .buttonStyle(.plain)
                        .font(theme.sans.font(size: 13))
                        .foregroundStyle(palette.ink3.color)
                    Spacer(minLength: 0)
                }
            }
            .padding(.vertical, 11)
            .overlay(alignment: .top) { divider }
        } else {
            Button { addingAlias = true } label: {
                Text(L10n.tr("+ Alias novo"))
                    .font(theme.sans.font(size: 13, weight: .medium))
                    .foregroundStyle(palette.accentInk.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 11)
                    .overlay(alignment: .top) { divider }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: A coluna da direita

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ConfigBlockTitle(text: L10n.tr("Assinatura, como ela chega"))
                Button(L10n.tr("Editar assinatura")) { editingSignature = true }
                    .buttonStyle(.plain)
                    .font(theme.sans.font(size: 13, weight: .medium))
                    .foregroundStyle(palette.accentInk.color)
            }
            .padding(.bottom, 10)

            signaturePreview

            Text(signatureNote)
                .font(theme.sans.font(size: 12.5))
                .foregroundStyle(palette.ink3.color)
                .padding(.top, 10)
                .padding(.horizontal, 2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 24)

            removeZone
        }
    }

    /// A assinatura **dentro** de um e-mail: cabeçalho apagado, uma linha de
    /// resposta e a assinatura no lugar em que ela vai chegar. É o que o
    /// desenho pede, e é mais honesto do que uma caixa de texto: a pessoa vê o
    /// que o outro lado vê.
    private var signaturePreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("M")
                    .font(theme.sans.font(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 30, height: 30)
                    .background(palette.orange.color, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.tr("Para quem você responde"))
                        .font(theme.sans.font(size: 13, weight: .semibold))
                        .foregroundStyle(palette.ink.color)
                    Text(L10n.tr("Re: um assunto qualquer"))
                        .font(theme.sans.font(size: 12))
                        .foregroundStyle(palette.ink3.color)
                }
                Spacer(minLength: 0)
                Text("10:42")
                    .font(theme.mono.font(size: 11))
                    .foregroundStyle(palette.ink3.color)
            }
            .opacity(0.55)

            Rectangle().fill(palette.line.color).frame(height: 1)

            Text(L10n.tr("Fechado! Te mando a proposta ainda hoje à tarde. Abraço,"))
                .font(theme.sans.font(size: 13.5))
                .lineSpacing(13.5 * 0.5)
                .foregroundStyle(palette.ink2.color)

            signatureBody
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .configCard(palette, radius: 14)
    }

    @ViewBuilder
    private var signatureBody: some View {
        let lines = signatureLines
        if lines.isEmpty {
            Text(L10n.tr("Esta conta ainda não tem assinatura."))
                .font(theme.sans.font(size: 13))
                .foregroundStyle(palette.ink3.color)
                .padding(.top, 2)
        } else {
            HStack(alignment: .top, spacing: 14) {
                Text(ConfigAccountTint.initial(for: status))
                    .font(theme.sans.font(size: 17, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 44, height: 44)
                    .background(ConfigAccountTint.color(for: status, theme: theme), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(theme.sans.font(
                                size: index == 0 ? 14 : 13,
                                weight: index == 0 ? .semibold : .regular
                            ))
                            .foregroundStyle(signatureInk(index: index, line: line).color)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
    }

    private func signatureInk(index: Int, line: String) -> TokenColor {
        if index == 0 { return palette.ink }
        // Uma linha com endereço ou telefone é o contato: o desenho a pinta no
        // acento, que é também como ela chega num cliente de e-mail.
        if line.contains("@") || line.contains("http") || line.rangeOfCharacter(from: .decimalDigits) != nil {
            return palette.accentInk
        }
        return palette.ink2
    }

    private var removeZone: some View {
        HStack(alignment: .center, spacing: 16) {
            Button { remove() } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("Remover deste Mac"))
                        .font(theme.sans.font(size: 13.5, weight: .medium))
                        .foregroundStyle(palette.red.color)
                    Text(L10n.tr("não apaga nada no servidor; só desconecta aqui"))
                        .font(theme.sans.font(size: 12))
                        .foregroundStyle(palette.ink3.color)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            Text(serverLine)
                .font(theme.mono.font(size: 12))
                .foregroundStyle(palette.ink3.color)
        }
        .padding(.top, 13)
        .overlay(alignment: .top) { divider }
    }

    // MARK: Os fatos

    private var divider: some View {
        Rectangle()
            .fill(palette.line.color)
            .frame(height: Hairline.thickness(displayScale))
    }

    private var folders: [MailFolder] {
        mailStore?.folders(of: status.accountID) ?? []
    }

    private var folderNote: String {
        folders.isEmpty
            ? L10n.tr("\(status.messageCount) mensagens guardadas neste Mac")
            : L10n.tr("\(folders.count) pastas, todas sincronizadas")
    }

    private var calendarNote: String {
        let count = accountCalendars.count
        return count == 0
            ? L10n.tr("nenhum calendário desta conta no Mac")
            : L10n.tr("\(count) calendários, marcados abaixo")
    }

    /// Os calendários desta conta. A correspondência é por **identidade**: o
    /// calendário OkamiUNI da caixa, os CalDAV sincronizados por ela, e os do
    /// EventKit cuja origem é o endereço da conta. Nada de inferir por nome.
    private var accountCalendars: [ConnectedCalendar] {
        guard let mailStore else { return [] }
        let mailboxID = ConnectedCalendar.mailboxID(forAccountID: status.accountID)
        return mailStore.calendarsForSidebar.filter { calendar in
            if calendar.id == mailboxID { return true }
            if ConnectedCalendar.calDAVAccountID(from: calendar.id) == status.accountID { return true }
            return calendar.source.localizedCaseInsensitiveContains(status.address)
        }
    }

    /// Quem envia: o endereço principal mais os aliases guardados. O principal
    /// aparece sempre, mesmo quando a conta nunca teve alias nenhum.
    private var senders: [SendAlias] {
        let aliases = status.sendAliases
        if aliases.contains(where: { $0.address.caseInsensitiveCompare(status.address) == .orderedSame }) {
            return aliases
        }
        let principal = SendAlias(
            address: status.address,
            displayName: status.hostMark.capitalized,
            isDefault: !aliases.contains { $0.isDefault }
        )
        return [principal] + aliases
    }

    private func aliasNote(_ alias: SendAlias) -> String {
        if alias.isDefault { return L10n.tr("padrão") }
        return alias.origin == .gmail ? L10n.tr("verificado") : ""
    }

    private var signatureLines: [String] {
        status.emailSignature.plainText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var signatureNote: String {
        let signature = status.emailSignature
        let characters = signature.plainText.count
        let images = signature.inlineResources.count
        if characters == 0 && images == 0 {
            return L10n.tr("Entraria uma vez em cada mensagem e resposta desta conta.")
        }
        return images == 0
            ? L10n.tr("Entra uma vez em cada mensagem e resposta desta conta. \(characters) caracteres.")
            : L10n.tr("Entra uma vez em cada mensagem e resposta desta conta. \(characters) caracteres · \(images) imagem(ns).")
    }

    private var serverLine: String {
        let auth = status.provider == .imap ? L10n.tr("senha") : "OAuth"
        return "\(status.imap?.host ?? status.hostMark) · \(auth)"
    }

    /// O serviço escolhido fala por API e ainda não tem cliente e segredo.
    private var needsRoomConnection: Bool {
        guard let meetingRooms,
              let service = meetingRooms.profile(for: status.accountID).defaultService,
              service.needsAPIConnection
        else { return false }
        return !meetingRooms.isConnected(service)
    }

    private var canCommitAlias: Bool {
        newAliasAddress.contains("@") && !newAliasAddress.hasPrefix("@") && !newAliasAddress.hasSuffix("@")
    }

    private func commitAlias() {
        guard canCommitAlias else { return }
        let alias = SendAlias(
            address: newAliasAddress.trimmingCharacters(in: .whitespaces),
            displayName: newAliasName.trimmingCharacters(in: .whitespaces),
            isDefault: false
        )
        var next = status.sendAliases
        next.append(alias)
        let id = status.accountID
        Task { await model.updateSendAliases(accountID: id, aliases: next) }
        cancelAlias()
    }

    private func cancelAlias() {
        addingAlias = false
        newAliasName = ""
        newAliasAddress = ""
    }

    private func makeDefault(_ alias: SendAlias) {
        let next = senders.map {
            SendAlias(
                address: $0.address,
                displayName: $0.displayName,
                isDefault: $0.address == alias.address,
                origin: $0.origin
            )
        }
        let id = status.accountID
        Task { await model.updateSendAliases(accountID: id, aliases: next) }
    }
}

/// Um interruptor que mostra um estado **sem** prometer que muda.
///
/// A conta sincroniza e-mail e agenda enquanto ela existe; não há preferência
/// guardada para desligar um dos dois. Desenhar um `ConfigSwitch` clicável ali
/// seria um botão mudo — por isso este, que é só o desenho, não recebe clique e
/// se anuncia como estado para o leitor de tela.
struct ConfigSwitchStatic: View {
    @Environment(\.configPalette) private var palette
    let on: Bool
    let label: String

    var body: some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill((on ? palette.accent : palette.off).color)
            Circle()
                .fill(Color.white)
                .frame(width: 18, height: 18)
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                .padding(2)
        }
        .frame(width: 38, height: 22)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(on ? L10n.tr("sincronizando") : L10n.tr("parado"))
    }
}

/// O editor de assinatura, aberto a partir da página da conta e preso nela.
struct ConfigSignatureSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.configPalette) private var palette
    let model: AccountsModel
    let accountID: String
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.tr("Editar assinatura"))
                    .font(theme.sans.font(size: 15, weight: .semibold))
                    .foregroundStyle(palette.ink.color)
                Spacer(minLength: 0)
                Button(L10n.tr("Pronto"), action: close)
                    .buttonStyle(.plain)
                    .configPrimaryButton(
                        palette, font: theme.sans.font(size: 13, weight: .semibold),
                        radius: 9, horizontal: 14, vertical: 7
                    )
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            SignatureSettingsView(model: model, accountID: accountID)
        }
        .frame(width: 840, height: 640)
    }
}
