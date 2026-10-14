import SwiftUI
import UNICore
import UNIDesign
import UNISync

/// Gestos: duas prévias grandes de uma mensagem sendo arrastada, as duas
/// listas reordenáveis embaixo, o destino de "Mover para" por conta, e o
/// restaurar padrão.
///
/// A prévia é o ensino: o desenho mostra o arrasto **longo** para a direita
/// disparando a primeira ação da lista, e o arrasto **curto** para a esquerda
/// revelando as três. Era um cartão de ensaio que desenhava as duas faixas
/// coladas numa linha só, e ninguém aprendia qual gesto fazia o quê.
struct ConfigGestures: View {
    @Environment(\.theme) private var theme
    @Environment(\.configPalette) private var palette
    @Environment(\.displayScale) private var displayScale

    let store: SwipeSettingsStore?
    let moveDestinations: [SwipeMoveDestination]
    @State private var limitWarning: String?

    var body: some View {
        ScrollView {
            if let store {
                VStack(alignment: .leading, spacing: 18) {
                    preview(store: store, side: .leading)
                    preview(store: store, side: .trailing)
                    HStack(alignment: .top, spacing: ConfigMetrics.columnGap) {
                        sideList(store: store, side: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        sideList(store: store, side: .trailing)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    destinations(store: store)
                    footer(store: store)
                }
                .frame(maxWidth: ConfigMetrics.contentMaxWidth, alignment: .leading)
            } else {
                Text(L10n.tr("O armazenamento de preferências de arraste ainda não foi conectado."))
                    .font(theme.sans.font(size: 13))
                    .foregroundStyle(palette.ink3.color)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: As prévias

    private func preview(store: SwipeSettingsStore, side: SwipeSide) -> some View {
        let actions = store.configuration.actions(on: side)
        return VStack(alignment: .leading, spacing: 8) {
            Text(side == .leading
                 ? L10n.tr("Arrasto longo para a direita → dispara a primeira ação da lista")
                 : L10n.tr("Arrasto curto para a esquerda ← mostra as três; o longo dispara a primeira"))
                .font(theme.sans.font(size: 12.5))
                .foregroundStyle(palette.ink3.color)
            GeometryReader { proxy in
                if side == .leading {
                    leadingPreview(actions: actions, width: proxy.size.width)
                } else {
                    trailingPreview(actions: actions, width: proxy.size.width)
                }
            }
            .frame(height: 62)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .modifier(ConditionalShadow(layers: palette.cardShadow))
        }
    }

    /// O arrasto longo: a mensagem já saiu 196pt para a direita e a faixa da
    /// primeira ação ocupa o que ela deixou.
    private func leadingPreview(actions: [SwipeAction], width: CGFloat) -> some View {
        let first = actions.first
        return ZStack(alignment: .leading) {
            (first.map { ConfigSwipePalette.color(for: $0) } ?? palette.off.color)
            HStack(spacing: 10) {
                Image(systemName: first?.symbol(for: ConfigSwipeSample.message) ?? "minus")
                    .font(.system(size: 16, weight: .semibold))
                Text(first?.settingsLabel ?? L10n.tr("Nenhuma ação"))
                    .font(theme.sans.font(size: 14, weight: .semibold))
            }
            .foregroundStyle(Color.white)
            .padding(.leading, 22)

            messageCard(alignment: .leading)
                .frame(width: width)
                .offset(x: 196)
                .shadow(color: .black.opacity(0.14), radius: 12, x: -8)
        }
        .frame(width: width, height: 62, alignment: .leading)
    }

    /// O arrasto curto: as três faixas aparecem à direita e a mensagem andou o
    /// bastante para revelá-las.
    private func trailingPreview(actions: [SwipeAction], width: CGFloat) -> some View {
        let reveal = CGFloat(max(actions.count, 1)) * 86
        return ZStack(alignment: .trailing) {
            palette.tile.color
            HStack(spacing: 0) {
                ForEach(actions) { action in
                    VStack(spacing: 3) {
                        Image(systemName: action.symbol(for: ConfigSwipeSample.message))
                            .font(.system(size: 14, weight: .semibold))
                        Text(action.settingsLabel)
                            .font(theme.sans.font(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(Color.white)
                    .frame(width: 86, height: 62)
                    .background(ConfigSwipePalette.color(for: action))
                }
            }

            messageCard(alignment: .trailing)
                .frame(width: width)
                .offset(x: -reveal)
                .shadow(color: .black.opacity(0.14), radius: 12, x: 8)
        }
        .frame(width: width, height: 62, alignment: .trailing)
    }

    private func messageCard(alignment: HorizontalAlignment) -> some View {
        HStack(spacing: 14) {
            if alignment == .trailing { Spacer(minLength: 0) }
            if alignment == .leading { avatar }
            VStack(alignment: alignment == .leading ? .leading : .trailing, spacing: 2) {
                Text(ConfigSwipeSample.who)
                    .font(theme.sans.font(size: 14, weight: .semibold))
                    .foregroundStyle(palette.ink.color)
                Text(ConfigSwipeSample.subject)
                    .font(theme.sans.font(size: 13))
                    .foregroundStyle(palette.ink3.color)
                    .lineLimit(1)
            }
            if alignment == .trailing { avatar }
            if alignment == .leading { Spacer(minLength: 0) }
        }
        .padding(.horizontal, 20)
        .frame(height: 62)
        .background(palette.card.color)
    }

    private var avatar: some View {
        Text("M")
            .font(theme.sans.font(size: 13, weight: .semibold))
            .foregroundStyle(Color.white)
            .frame(width: 32, height: 32)
            .background(palette.orange.color, in: Circle())
    }

    // MARK: As listas

    private func sideList(store: SwipeSettingsStore, side: SwipeSide) -> some View {
        let actions = store.configuration.actions(on: side)
        let room = SwipeConfiguration.maxPerSide - actions.count
        return VStack(alignment: .leading, spacing: 0) {
            ConfigBlockTitle(text: side == .leading
                             ? L10n.tr("→ Para a direita")
                             : L10n.tr("← Para a esquerda"))
                .padding(.bottom, 4)
            ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                actionRow(store: store, side: side, action: action, index: index, total: actions.count)
            }
            addRow(store: store, side: side, room: room, current: actions)
        }
    }

    private func actionRow(
        store: SwipeSettingsStore, side: SwipeSide, action: SwipeAction, index: Int, total: Int
    ) -> some View {
        HStack(spacing: 12) {
            // A alça do desenho. Reordenar por menu, e não por arrastar: um
            // arrasto dentro de uma lista de três linhas é mais fácil de errar
            // do que de acertar, e pelo menu o teclado também alcança.
            Menu {
                Button(L10n.tr("Mover para cima")) { move(store: store, side: side, from: index, to: index - 1) }
                    .disabled(index == 0)
                Button(L10n.tr("Mover para baixo")) { move(store: store, side: side, from: index, to: index + 1) }
                    .disabled(index == total - 1)
                Divider()
                Button(L10n.tr("Tirar daqui"), role: .destructive) {
                    remove(store: store, side: side, action: action)
                }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.ink3.color)
                    .frame(width: 14, height: 14)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(L10n.tr("Reordenar \(action.settingsLabel)"))

            Image(systemName: action.symbol(for: ConfigSwipeSample.message))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 28, height: 28)
                .background(
                    ConfigSwipePalette.color(for: action),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )

            Text(action.settingsLabel)
                .font(theme.sans.font(size: 14, weight: .medium))
                .foregroundStyle(palette.ink.color)
            Spacer(minLength: 0)
            Text(note(store: store, side: side, action: action, index: index))
                .font(theme.sans.font(size: 12.5))
                .foregroundStyle(palette.ink3.color)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.line.color).frame(height: Hairline.thickness(displayScale))
        }
    }

    private func note(
        store: SwipeSettingsStore, side: SwipeSide, action: SwipeAction, index: Int
    ) -> String {
        if index == 0 { return L10n.tr("no arrasto longo") }
        if action == .moveToDestination {
            let count = store.configuration.destinations(on: side).count
            return count == 0 ? L10n.tr("sem destino") : L10n.tr("destino por conta")
        }
        if action == .later { return L10n.tr("até amanhã") }
        return ""
    }

    @ViewBuilder
    private func addRow(
        store: SwipeSettingsStore, side: SwipeSide, room: Int, current: [SwipeAction]
    ) -> some View {
        let available = SwipeAction.allCases.filter { candidate in
            guard !current.contains(candidate) else { return false }
            // "Mover para" só entra quando existe pasta real para onde levar.
            return candidate != .moveToDestination || !moveDestinations.isEmpty
        }
        if room > 0, !available.isEmpty {
            Menu {
                ForEach(available) { candidate in
                    Button(candidate.settingsLabel) { add(store: store, side: side, action: candidate) }
                }
            } label: {
                Text(L10n.tr("+ Adicionar ação · cabe mais \(room)"))
                    .font(theme.sans.font(size: 13, weight: .medium))
                    .foregroundStyle(palette.accentInk.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                    .overlay(alignment: .top) {
                        Rectangle().fill(palette.line.color).frame(height: Hairline.thickness(displayScale))
                    }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        } else {
            Text(L10n.tr("As \(SwipeConfiguration.maxPerSide) já estão em uso"))
                .font(theme.sans.font(size: 13, weight: .medium))
                .foregroundStyle(palette.ink3.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .overlay(alignment: .top) {
                    Rectangle().fill(palette.line.color).frame(height: Hairline.thickness(displayScale))
                }
        }
    }

    // MARK: O destino de "Mover para"

    @ViewBuilder
    private func destinations(store: SwipeSettingsStore) -> some View {
        let accounts = destinationAccounts(store: store)
        if !accounts.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ConfigBlockTitle(
                    text: L10n.tr("“Mover para” pede um destino por conta"),
                    note: L10n.tr("cada caixa leva para a pasta dela")
                )
                .padding(.bottom, 4)
                ForEach(accounts, id: \.id) { account in
                    ConfigRow(label: account.label, verticalPadding: 10) {
                        HStack(spacing: 10) {
                            ForEach(SwipeSide.allCases, id: \.self) { side in
                                ConfigPicker(
                                    options: [(nil as String?, L10n.tr("Não usar"))]
                                        + account.destinations.map { (Optional($0.id), $0.displayName) },
                                    selection: Binding(
                                        get: {
                                            store.configuration
                                                .destination(on: side, for: account.id)?.id
                                        },
                                        set: { id in
                                            let destination = account.destinations.first { $0.id == id }
                                            if !store.setMoveDestination(
                                                destination, on: side, for: account.id
                                            ) {
                                                limitWarning = L10n.tr("Este gesto já tem \(SwipeConfiguration.maxPerSide) ações. Remova uma para adicionar Mover.")
                                            } else {
                                                limitWarning = nil
                                            }
                                        }
                                    ),
                                    accessibilityTitle: "\(side.label) · \(account.label)"
                                )
                            }
                        }
                    }
                }
                if let limitWarning {
                    Text(limitWarning)
                        .font(theme.sans.font(size: 12.5, weight: .medium))
                        .foregroundStyle(palette.red.color)
                        .padding(.top, 8)
                }
            }
        }
    }

    private struct DestinationAccount {
        let id: String
        let label: String
        let destinations: [SwipeMoveDestination]
    }

    private func destinationAccounts(store: SwipeSettingsStore) -> [DestinationAccount] {
        var grouped = Dictionary(grouping: moveDestinations, by: \.accountID)
        for side in SwipeSide.allCases {
            for destination in store.configuration.destinations(on: side).values {
                if !(grouped[destination.accountID]?.contains(destination) ?? false) {
                    grouped[destination.accountID, default: []].append(destination)
                }
            }
        }
        return grouped.map { accountID, destinations in
            DestinationAccount(
                id: accountID,
                label: destinations.compactMap(\.accountLabel).first ?? accountID,
                destinations: destinations.sorted {
                    $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                }
            )
        }
        .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private func footer(store: SwipeSettingsStore) -> some View {
        HStack(spacing: 16) {
            Text(L10n.tr("Você pode deixar um lado sem ações."))
                .font(theme.sans.font(size: 12.5))
                .foregroundStyle(palette.ink3.color)
            Spacer(minLength: 0)
            Button(L10n.tr("Restaurar padrão")) { store.resetToDefault() }
                .buttonStyle(.plain)
                .font(theme.sans.font(size: 13))
                .foregroundStyle(palette.ink3.color)
        }
        .padding(.top, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.line.color).frame(height: Hairline.thickness(displayScale))
        }
    }

    // MARK: As escritas

    private func move(store: SwipeSettingsStore, side: SwipeSide, from: Int, to: Int) {
        var next = store.configuration.actions(on: side)
        guard next.indices.contains(from), next.indices.contains(to) else { return }
        let moved = next.remove(at: from)
        next.insert(moved, at: to)
        store.setActions(next, on: side)
    }

    private func add(store: SwipeSettingsStore, side: SwipeSide, action: SwipeAction) {
        var next = store.configuration.actions(on: side)
        guard next.count < SwipeConfiguration.maxPerSide else { return }
        next.append(action)
        store.setActions(next, on: side)
    }

    private func remove(store: SwipeSettingsStore, side: SwipeSide, action: SwipeAction) {
        store.setActions(
            store.configuration.actions(on: side).filter { $0 != action },
            on: side
        )
    }
}

/// A mensagem de exemplo das prévias. Uma só, para as duas faixas falarem da
/// mesma coisa.
enum ConfigSwipeSample {
    static let who = L10n.tr("Marina Costa")
    static let subject = L10n.tr("Agenda da próxima semana — consegue terça?")

    /// Uma mensagem de verdade só para os rótulos e símbolos que dependem do
    /// estado dela (ler/não ler, estrela). Nenhuma ação é executada aqui.
    static var message: Message {
        Message(
            id: "config-gestos-amostra",
            accountID: "amostra",
            from: Contact(name: who, address: "marina@exemplo.com"),
            receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
            subject: subject,
            snippet: subject,
            body: [],
            tags: [],
            bucket: .today,
            isRead: false,
            summary: nil,
            detectedEvent: nil
        )
    }
}

/// As cores das faixas de arrasto, como o mock as escreve. Elas são cores de
/// **significado** — verde arquiva, vermelho apaga — e por isso não saem dos
/// tokens de tema: um tema roxo não deve pintar a Lixeira de roxo.
enum ConfigSwipePalette {
    static func color(for action: SwipeAction) -> Color {
        switch action {
        case .archive: Color(.sRGB, red: 16 / 255, green: 185 / 255, blue: 129 / 255)
        case .toggleRead: Color(.sRGB, red: 59 / 255, green: 130 / 255, blue: 246 / 255)
        case .later: Color(.sRGB, red: 245 / 255, green: 158 / 255, blue: 11 / 255)
        case .today: Color(.sRGB, red: 14 / 255, green: 165 / 255, blue: 233 / 255)
        case .trash: Color(.sRGB, red: 239 / 255, green: 68 / 255, blue: 68 / 255)
        case .toggleFlag: Color(.sRGB, red: 234 / 255, green: 179 / 255, blue: 8 / 255)
        case .moveToDestination: Color(.sRGB, red: 139 / 255, green: 92 / 255, blue: 246 / 255)
        }
    }
}
