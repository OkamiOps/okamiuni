import AppKit
import SwiftUI
import UNICore
import UNIDesign
import UNISync

/// Runtime and peer settings share the same provider-independent tools.
/// File pickers grant the UI access only for selecting and importing runtime code.
struct AgentConnectionsSettings: View {
    @Environment(\.theme) private var theme
    @Binding var configuration: AgentConnectionConfiguration
    @Binding var delegation: A2AConfiguration
    let credentials: (any AssistantCredentialStore)?
    @State private var feedback: String?
    @State private var checkingACP = false
    @State private var environmentText = ""
    @State private var argumentsText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(L10n.tr("Usar agente ACP nas conversas"), isOn: $configuration.enabled)
                .toggleStyle(.switch)
                .accessibilityIdentifier("assistant-acp-enabled")
            Text(L10n.tr("As mesmas ferramentas de email, anexos, rascunhos e agenda ficam disponíveis ao provedor conectado."))
                .font(theme.sans.font(size: 11.5)).foregroundStyle(theme.ink3.color)
                .fixedSize(horizontal: false, vertical: true)
            if configuration.enabled {
                SettingsLabeledRow(label: L10n.tr("Executável ACP")) {
                    HStack {
                        if let runtime = configuration.managedRuntime {
                            Text(runtime.displayName).font(theme.sans.font(size: 12, weight: .semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            TextField("/caminho/agente-acp", text: $configuration.executablePath)
                                .settingsTextField().accessibilityIdentifier("assistant-acp-path")
                        }
                        Button(L10n.tr("Escolher…")) { chooseExecutable() }.settingsQuietButton()
                    }
                }
                Text(L10n.tr("O agente roda em um processo auxiliar local e usa sua própria sessão. Escolha um runtime de confiança."))
                    .font(theme.sans.font(size: 11.5)).foregroundStyle(theme.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsLabeledRow(label: L10n.tr("Argumentos · um por linha")) {
                    TextEditor(text: $argumentsText)
                        .onChange(of: argumentsText) { _, value in
                            configuration.arguments = value.components(separatedBy: "\n").filter { !$0.isEmpty }
                        }
                        .settingsTextEditor(minHeight: 48)
                        .accessibilityLabel(L10n.tr("Argumentos do agente ACP"))
                }
                SettingsLabeledRow(label: L10n.tr("Ambiente · NOME=valor")) {
                    TextEditor(text: $environmentText)
                        .onChange(of: environmentText) { _, value in
                            var result: [String: String] = [:]
                            for line in value.components(separatedBy: "\n") {
                                let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                                if pair.count == 2 { result[String(pair[0])] = String(pair[1]) }
                            }
                            configuration.environment = result
                        }
                        .settingsTextEditor(minHeight: 48)
                        .accessibilityLabel(L10n.tr("Ambiente do agente ACP"))
                }
                Text(L10n.tr("Use apenas opções de runtime, como CODEX_HOME. Senhas e tokens não pertencem a este campo. A análise automática e a escrita mantêm o provedor principal."))
                    .font(theme.sans.font(size: 11.5)).foregroundStyle(theme.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
                Button(checkingACP ? L10n.tr("Conectando…") : L10n.tr("Testar conexão ACP")) { testACP() }
                    .settingsQuietButton().disabled(checkingACP)
                    .accessibilityIdentifier("assistant-acp-test")
            }
            Divider()
            Toggle(L10n.tr("Delegar tarefas a agentes A2A"), isOn: $delegation.enabled)
                .toggleStyle(.switch).accessibilityIdentifier("assistant-a2a-enabled")
            if delegation.enabled {
                Text(L10n.tr("Conecte agentes por Agent Card. Cada parceiro recebe somente a tarefa delegada; a caixa não é compartilhada automaticamente."))
                    .font(theme.sans.font(size: 11.5)).foregroundStyle(theme.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach($delegation.peers) { $peer in
                    A2APeerSettings(peer: $peer, credentials: credentials) {
                        delegation.peers.removeAll { $0.id == peer.id }
                    }
                }
                Button(L10n.tr("Adicionar agente A2A")) { delegation.peers.append(.init()) }
                    .settingsQuietButton().accessibilityIdentifier("assistant-a2a-add")
            }
            if let feedback {
                Text(feedback).font(theme.sans.font(size: 11.5)).foregroundStyle(theme.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.vertical, 8)
            .onAppear {
                environmentText = configuration.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
                argumentsText = configuration.arguments.joined(separator: "\n")
            }
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = L10n.tr("Escolher…")
        panel.message = L10n.tr("Escolha o executável do agente ACP.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        configuration.managedRuntime = nil
        configuration.executablePath = url.path
        feedback = nil
    }

    private func testACP() {
        checkingACP = true
        let configuration = configuration
        Task {
            defer { checkingACP = false }
            let server = LocalMCPServer(tools: []) { _, _ in throw AgentToolError.unknownTool }
            do {
                let endpoint = try await server.start()
                let client = ACPExternalRuntime(timeout: 30)
                let name = try await client.checkConnection(
                    configuration: configuration, mcpURL: endpoint.url, bearerToken: endpoint.bearerToken
                )
                await server.stop()
                feedback = L10n.tr("Conectado: \(name)")
            } catch {
                await server.stop()
                feedback = error.localizedDescription
            }
        }
    }
}

private struct A2APeerSettings: View {
    @Environment(\.theme) private var theme
    @Binding var peer: A2APeerConfiguration
    let credentials: (any AssistantCredentialStore)?
    let remove: () -> Void
    @State private var secret = ""
    @State private var status: String?
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField(L10n.tr("Nome do agente"), text: $peer.name).settingsTextField()
                Toggle(L10n.tr("Ativo"), isOn: $peer.enabled).toggleStyle(.switch)
                Button(action: remove) { Image(systemName: "trash") }.buttonStyle(.plain)
                    .accessibilityLabel(L10n.tr("Remover agente A2A"))
            }
            TextField("https://agent.example/.well-known/agent-card.json", text: $peer.cardURL)
                .settingsTextField().accessibilityLabel(L10n.tr("URL do Agent Card"))
                .onChange(of: peer.cardURL) { old, new in
                    if origin(old) != origin(new) { peer.credentialID = ""; secret = ""; status = nil }
                }
            SecureField(L10n.tr("Token opcional · guardado no Keychain"), text: $secret).settingsTextField()
            HStack {
                Button(L10n.tr("Guardar credencial")) { saveCredential() }.settingsQuietButton()
                    .disabled(secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || credentials == nil)
                Button(testing ? L10n.tr("Conectando…") : L10n.tr("Testar conexão")) { testConnection() }
                    .settingsQuietButton().disabled(testing)
                if !peer.credentialID.isEmpty {
                    Text(L10n.tr("Guardada no Keychain")).font(theme.sans.font(size: 10.5)).foregroundStyle(theme.ink3.color)
                }
            }
            if let status { Text(status).font(theme.sans.font(size: 11.5)).foregroundStyle(theme.ink2.color).fixedSize(horizontal: false, vertical: true) }
        }.padding(12).background(theme.surface2.color, in: RoundedRectangle(cornerRadius: 8))
    }

    private func origin(_ raw: String) -> String {
        guard let url = URLComponents(string: raw) else { return raw }
        return "\(url.scheme?.lowercased() ?? "")://\(url.host?.lowercased() ?? ""):\(url.port ?? (url.scheme == "https" ? 443 : 80))"
    }
    private func saveCredential() {
        do {
            _ = try peer.validated()
            guard let credentials else { throw AssistantCredentialStoreError.invalidAPIKey }
            let id = peer.credentialID.isEmpty ? "a2a-\(UUID().uuidString)" : peer.credentialID
            try credentials.storeAPIKey(secret, for: id)
            peer.credentialID = id
            secret = ""
            status = L10n.tr("Credencial guardada. Salve a configuração de IA para conservar o agente.")
        } catch { status = error.localizedDescription }
    }
    private func testConnection() {
        testing = true
        let peer = peer
        let credentials = credentials
        Task {
            defer { testing = false }
            do {
                let client = A2AClient(configuration: .init(enabled: true, peers: [peer]), credentialHeaders: { id in
                    guard !id.isEmpty else { return [:] }
                    guard let token = try credentials?.apiKey(for: id) else { throw AssistantCredentialStoreError.invalidAPIKey }
                    return ["Authorization": "Bearer " + token]
                })
                let card = try await client.discover(peerID: peer.id)
                status = L10n.tr("Conectado: \(card.name)")
            } catch { status = error.localizedDescription }
        }
    }
}
