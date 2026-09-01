import SwiftUI
import UNICore
import UNIDesign
import UNISync

/// Remetentes da conta. Os aliases do Gmail entram sozinhos no sync; aqui
/// dá para buscar de novo, marcar o padrão e acrescentar um à mão.
struct AliasSettingsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let model: AccountsModel
    @State private var selectedID: String?
    @State private var query = ""
    @State private var draftAddress = ""
    @State private var draftName = ""
    @State private var feedback: String?
    @State private var feedbackIsError = false
    @State private var fetching = false

    var body: some View {
        HStack(spacing: 0) {
            accountList
                .frame(width: 218)
                .background(theme.surface2.color)
            Rectangle()
                .fill(theme.line.color)
                .frame(width: Hairline.thickness(displayScale))
            editor
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.paper.color)
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: model.statuses) { _, _ in selectFirstIfNeeded() }
        .onChange(of: selectedID) { _, id in
            query = ""
            draftAddress = ""
            draftName = ""
            feedback = nil
            if let id, let status = model.statuses.first(where: { $0.accountID == id }),
               status.provider == .gmail {
                Task { await fetchGmail(status, silent: status.sendAliases.isEmpty) }
            }
        }
        .task(id: selectedID) {
            guard let status = selected, status.provider == .gmail else { return }
            await fetchGmail(status, silent: true)
        }
    }

    private var accountList: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text("CONTAS")
                        .capsLabel(size: 8.5)
                    Text("\(model.statuses.count)")
                        .font(theme.mono.font(size: 9, weight: .semibold))
                        .foregroundStyle(theme.accent.color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(theme.accentSoft.color, in: Capsule())
                }
                Text("Os aliases do Gmail entram no sync. Aqui você escolhe o padrão.")
                    .font(theme.sans.font(size: 10))
                    .foregroundStyle(theme.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 12)
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(model.statuses) { status in
                        Button {
                            selectedID = status.accountID
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "paperplane")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(
                                        selectedID == status.accountID
                                            ? theme.accent.color : theme.ink3.color
                                    )
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(status.address)
                                        .font(theme.sans.font(size: 11.5, weight: .medium))
                                        .foregroundStyle(theme.ink.color)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(aliasSummary(status))
                                        .font(theme.sans.font(size: 10))
                                        .foregroundStyle(theme.ink3.color)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 9)
                            .frame(height: 46)
                            .background(
                                selectedID == status.accountID ? theme.surface3.color : Color.clear,
                                in: RoundedRectangle(cornerRadius: 9)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                        .focusRing(cornerRadius: 9)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let selected {
            VStack(alignment: .leading, spacing: 0) {
                header(selected)
                Rectangle()
                    .fill(theme.line.color)
                    .frame(height: Hairline.thickness(displayScale))
                if fetching && selected.sendAliases.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Buscando aliases no Gmail…")
                            .font(theme.sans.font(size: 12.5))
                            .foregroundStyle(theme.ink3.color)
                    }
                    .padding(24)
                    Spacer(minLength: 0)
                } else {
                    list(selected)
                }
            }
        } else {
            SettingsEmptyState(
                symbol: "paperplane",
                title: "Nenhuma conta disponível",
                text: "Adicione uma conta antes de configurar remetentes."
            )
        }
    }

    private func header(_ status: AccountStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("REMETENTES")
                        .capsLabel(size: 8.5)
                    Text(status.address)
                        .font(theme.sans.font(size: 16, weight: .semibold))
                        .foregroundStyle(theme.ink.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(aliasSummary(status))
                        .font(theme.sans.font(size: 11.5))
                        .foregroundStyle(theme.ink3.color)
                }
                Spacer(minLength: 8)
                if status.provider == .gmail {
                    Button {
                        Task { await fetchGmail(status, silent: false) }
                    } label: {
                        Text(fetching ? "Atualizando…" : "Atualizar")
                    }
                    .settingsQuietButton()
                    .disabled(fetching || model.isBusy)
                }
            }
            TextField("Filtrar endereço…", text: $query)
                .settingsTextField()
            if let feedback {
                Text(feedback)
                    .font(theme.sans.font(size: 12))
                    .foregroundStyle(feedbackIsError ? theme.ink.color : theme.ink3.color)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func list(_ status: AccountStatus) -> some View {
        let rows = visibleRows(status)
        return VStack(spacing: 0) {
            HStack {
                Text("Endereço")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Padrão")
                    .frame(width: 72, alignment: .trailing)
            }
            .font(theme.sans.font(size: 10, weight: .medium))
            .foregroundStyle(theme.ink4.color)
            .padding(.horizontal, 20)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows, id: \.address) { row in
                        aliasLine(row, on: status)
                        Rectangle()
                            .fill(theme.line2.color)
                            .frame(height: Hairline.thickness(displayScale))
                    }
                    if rows.isEmpty {
                        Text(query.isEmpty ? "Nenhum alias nesta conta." : "Nada com este filtro.")
                            .font(theme.sans.font(size: 12.5))
                            .foregroundStyle(theme.ink3.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.top, 16)
                    }
                    addRow
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                }
            }
        }
    }

    private func aliasLine(_ row: Row, on status: AccountStatus) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.address)
                    .font(theme.sans.font(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.ink.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !row.caption.isEmpty {
                    Text(row.caption)
                        .font(theme.sans.font(size: 10.5))
                        .foregroundStyle(theme.ink4.color)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button {
                Task { await setDefault(row.locked ? nil : row.address, on: status) }
            } label: {
                Image(systemName: row.isDefault ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(row.isDefault ? theme.accent.color : theme.ink4.color)
            }
            .buttonStyle(.plain)
            .focusRing(cornerRadius: 8)
            .help(row.isDefault ? "Remetente padrão" : "Usar como padrão")
            .accessibilityLabel(row.isDefault ? "Padrão" : "Usar como padrão")
            .frame(width: 28)
            if !row.locked {
                Button {
                    Task { await remove(row.address, on: status) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.ink4.color)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .focusRing(cornerRadius: 6)
                .help("Remover da lista")
                .accessibilityLabel("Remover \(row.address)")
            } else {
                Color.clear.frame(width: 22, height: 22)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 40)
        .contentShape(Rectangle())
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            TextField("Nome (opcional)", text: $draftName)
                .settingsTextField()
                .frame(maxWidth: 160)
            TextField("alias@seudominio.com", text: $draftAddress)
                .settingsTextField()
            Button("Adicionar") { Task { await addAlias() } }
                .settingsPrimaryButton()
                .disabled(!canAdd || model.isBusy)
        }
    }

    private struct Row: Hashable {
        let address: String
        let caption: String
        let isDefault: Bool
        let locked: Bool
    }

    private func visibleRows(_ status: AccountStatus) -> [Row] {
        let termo = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let principal = Row(
            address: status.address,
            caption: "Conta principal",
            isDefault: !status.sendAliases.contains(where: \.isDefault),
            locked: true
        )
        let extras = status.sendAliases
            .sorted { $0.address.localizedCaseInsensitiveCompare($1.address) == .orderedAscending }
            .map { alias in
                Row(
                    address: alias.address,
                    caption: alias.displayName,
                    isDefault: alias.isDefault,
                    locked: false
                )
            }
        let all = [principal] + extras
        guard !termo.isEmpty else { return all }
        return all.filter {
            $0.address.lowercased().contains(termo) || $0.caption.lowercased().contains(termo)
        }
    }

    private var selected: AccountStatus? {
        model.statuses.first { $0.accountID == selectedID }
    }

    private var canAdd: Bool {
        SendAlias.parse(draftAddress) != nil
    }

    private func aliasSummary(_ status: AccountStatus) -> String {
        let n = status.sendAliases.count
        if n == 0 { return "Só o endereço principal" }
        return n == 1 ? "1 alias" : "\(n) aliases"
    }

    private func selectFirstIfNeeded() {
        if selectedID == nil || !model.statuses.contains(where: { $0.accountID == selectedID }) {
            selectedID = model.statuses.first?.accountID
        }
    }

    private func addAlias() async {
        guard let selected, let address = SendAlias.parse(draftAddress) else { return }
        if address.lowercased() == selected.address.lowercased() {
            report("Este já é o endereço da conta.", error: true)
            return
        }
        if selected.sendAliases.contains(where: { $0.address.lowercased() == address.lowercased() }) {
            report("Este alias já está na lista.", error: true)
            return
        }
        var next = selected.sendAliases
        next.append(SendAlias(
            address: address,
            displayName: draftName.trimmingCharacters(in: .whitespacesAndNewlines),
            origin: .manual
        ))
        guard await model.updateSendAliases(accountID: selected.accountID, aliases: next) else {
            report(model.lastError?.errorDescription ?? "Não foi possível gravar.", error: true)
            return
        }
        draftAddress = ""
        draftName = ""
        report("Alias adicionado.", error: false)
    }

    private func remove(_ address: String, on status: AccountStatus) async {
        let next = status.sendAliases.filter { $0.address.lowercased() != address.lowercased() }
        guard await model.updateSendAliases(accountID: status.accountID, aliases: next) else {
            report(model.lastError?.errorDescription ?? "Não foi possível remover.", error: true)
            return
        }
    }

    private func setDefault(_ address: String?, on status: AccountStatus) async {
        let next = status.sendAliases.map {
            $0.withDefault($0.address.lowercased() == address?.lowercased())
        }
        guard await model.updateSendAliases(accountID: status.accountID, aliases: next) else {
            report(model.lastError?.errorDescription ?? "Não foi possível gravar o padrão.", error: true)
            return
        }
    }

    private func fetchGmail(_ status: AccountStatus, silent: Bool) async {
        fetching = true
        defer { fetching = false }
        let antes = status.sendAliases.count
        guard await model.refreshGmailSendAliases(accountID: status.accountID) else {
            if !silent {
                report(model.lastError?.errorDescription ?? "Não foi possível ler os aliases do Gmail.", error: true)
            }
            return
        }
        let depois = model.statuses.first(where: { $0.accountID == status.accountID })?.sendAliases.count ?? antes
        if !silent || depois != antes {
            report(
                depois == 0
                    ? "O Gmail não devolveu aliases para esta conta."
                    : (depois == 1 ? "1 alias do Gmail." : "\(depois) aliases do Gmail."),
                error: false
            )
        }
    }

    private func report(_ text: String, error: Bool) {
        feedback = text
        feedbackIsError = error
    }
}
