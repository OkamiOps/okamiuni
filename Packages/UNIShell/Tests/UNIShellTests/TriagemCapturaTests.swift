import Foundation
import SwiftUI
import Testing
import UNICore
import UNIDesign
import UNISync
@testable import UNIShell

/// As duas telas da queixa, desenhadas para serem **olhadas**.
///
/// Não é teste de pixel: é o par de PNGs que responde às duas perguntas em
/// dois segundos — "dá para dizer o que é gente e o que é máquina?" e "dá para
/// dizer de qual caixa cada um veio?". Roda com `UNI_RENDER_DIR` apontado para
/// onde os arquivos devem sair; sem a variável, ele só confirma que as duas
/// desenham.
@Suite("Capturas da triagem")
@MainActor
struct TriagemCapturaTests {

    private static let agora = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("a faixa de atenção e a coluna de prioridades desenham nos dois temas")
    func capturas() throws {
        for (nome, tema) in [("okami", Theme.okami), ("tinta", Theme.tinta)] {
            #expect(Render.snapshot(
                FaixaDeAtencaoEnsaio(),
                named: "faixa-atencao-\(nome)",
                size: CGSize(width: 520, height: 400), theme: tema
            ) != nil)
            #expect(Render.snapshot(
                ColunaDePrioridadesEnsaio(),
                named: "prioridades-\(nome)",
                size: CGSize(width: 460, height: 760), theme: tema
            ) != nil)
        }
    }

    /// As três faixas que a janela pode desenhar, uma sobre a outra: a que
    /// oferece Reconectar, a que explica por que não oferece, e a conta sã.
    private struct FaixaDeAtencaoEnsaio: View {
        @Environment(\.theme) private var theme

        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                faixa(status(erro: .autenticacao))
                faixa(status(erro: .semClientID))
                faixa(status(erro: nil))
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(theme.paper.color)
        }

        private func faixa(_ s: AccountStatus) -> some View {
            AccountAttentionBandEnsaio(status: s)
        }

        private func status(erro: SyncError?) -> AccountStatus {
            AccountStatus(
                accountID: "conta-a", address: "marcos@okamiops.com", hostMark: "okamiops",
                state: erro == nil ? .ativa : .erroDeAutenticacao,
                messageCount: 1_446,
                lastSyncedAt: erro == nil ? TriagemCapturaTests.agora : nil,
                error: erro, progress: nil, pendingOperations: erro == nil ? 0 : 1,
                provider: .gmail
            )
        }
    }

    /// A coluna com os sete e-mails da captura do dono, em três contas.
    private struct ColunaDePrioridadesEnsaio: View {
        @Environment(\.theme) private var theme

        var body: some View {
            let focus = DashboardFocus.snapshot(
                messages: Self.seteEmTresContas,
                agenda: [], pending: [], nowMinute: 720,
                now: TriagemCapturaTests.agora
            )
            return VStack(alignment: .leading, spacing: 0) {
                Text("PRIORIDADES · \(focus.mail.count)").capsLabel()
                    .padding(.bottom, 8)
                ForEach(focus.mail) { item in
                    DashboardRow(
                        row: DayPlan.Row(
                            id: item.id, item: item,
                            why: item.reason.label,
                            proposal: .keep(messageID: item.id, why: item.reason.label)
                        ),
                        tint: Self.tint(item.message.accountID, dark: theme.isDark),
                        accountMark: Self.marca(item.message.accountID),
                        usedAgenda: false,
                        isSelected: item.id == focus.mail.first?.id,
                        isConfirmingSend: false,
                        today: TriagemCapturaTests.agora,
                        onSelect: {}, onOpen: {},
                        onPrimary: {}, onSecondary: {},
                        onConfirmSend: {}, onCancelSend: {}
                    )
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(theme.paper.color)
        }

        private static func marca(_ accountID: String) -> String {
            DashboardMetrics.accountMark(host: accountID, address: "")
        }

        private static func tint(_ accountID: String, dark: Bool) -> Color {
            let indice = ["okamiops": 0, "vantion": 2, "gmail": 5][accountID] ?? 0
            let par = AccountTint.pair(forIndex: indice)
            return TokenColor(css: dark ? par.dark : par.light)?.color ?? .gray
        }

        /// Os sete da captura, espalhados pelas três contas dele.
        static let seteEmTresContas: [Message] = {
            let agora = TriagemCapturaTests.agora
            func msg(
                _ id: String, _ conta: String, _ nome: String, _ endereco: String,
                _ assunto: String, marcas: BulkMailMarks = [],
                intent: MessageTriage.Intent = .request, needsReply: Bool = true,
                minutos: Double, prazo: DetectedDeadline? = nil
            ) -> Message {
                Message(
                    id: id, accountID: conta,
                    from: Contact(name: nome, address: endereco),
                    receivedAt: agora.addingTimeInterval(-minutos * 60),
                    subject: assunto, snippet: assunto, body: [],
                    tags: [], bucket: .today, isRead: false,
                    summary: nil, detectedEvent: nil,
                    triage: MessageTriage(
                        needsReply: needsReply, intent: intent, urgency: .normal, deadline: prazo
                    ),
                    bulkMarks: marcas
                )
            }
            return [
                msg(
                    "resend", "gmail", "Resend", "onboarding@resend.dev", "Welcome to Resend!",
                    marcas: [.listUnsubscribe], intent: .transactional, minutos: 30
                ),
                msg(
                    "zoho", "gmail", "Zoho", "marketing@zoho.com",
                    "Quando surge uma nova necessidade, onde você procura a solução?",
                    marcas: [.listUnsubscribe, .listID, .precedence],
                    intent: .newsletter, minutos: 60
                ),
                msg(
                    "upwork", "gmail", "Upwork", "do-not-reply@upwork.com",
                    "Invitation to Interview for: Software Testing",
                    marcas: [.noReplySender, .autoSubmitted], minutos: 90
                ),
                msg(
                    "cats9th", "okamiops", "Cats9th", "contato@cats9th.com",
                    "Proposta de parceria para o segundo semestre", minutos: 240
                ),
                msg(
                    "jack", "okamiops", "Jack Whitmore", "jack@whitmore.co",
                    "Pode confirmar sexta?", minutos: 300,
                    prazo: DetectedDeadline(
                        date: agora.addingTimeInterval(20 * 3_600), evidence: "sexta"
                    )
                ),
                msg(
                    "jayden", "vantion", "Jayden Sutherland", "jayden@sutherland.co",
                    "Retomando nosso assunto de ontem", minutos: 360
                ),
                msg(
                    "vantion", "vantion", "Formulário Vantion", "site@vantion.com.br",
                    "Novo contato pelo formulário do site",
                    intent: .lead, minutos: 420
                ),
            ]
        }()
    }
}

/// A faixa da janela de Contas, isolada para a captura.
///
/// Cópia do desenho da janela, e não a janela inteira: a captura precisa das
/// três faixas lado a lado, e a janela só mostra uma por vez. O que ela **não**
/// duplica é decisão nenhuma — ação, destaque e nota saem de `AccountsCopy`,
/// que é a mesma fonte que a janela usa.
private struct AccountAttentionBandEnsaio: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let status: AccountStatus

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Circle()
                .fill(AccountsCopy.isFailing(status) ? theme.danger.color : theme.success.color)
                .frame(width: 10, height: 10)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 5) {
                Text(AccountsCopy.isFailing(status) ? "A conta precisa de atenção" : "Conta conectada")
                    .font(theme.sans.font(size: 13, weight: .semibold))
                    .foregroundStyle(theme.ink.color)
                Text(AccountsCopy.status(status, now: Date(), calendar: .current))
                    .font(theme.sans.font(size: 11.5))
                    .foregroundStyle(AccountsCopy.isFailing(status) ? theme.danger.color : theme.ink3.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let nota = AccountsCopy.reconnectBlockedNote(for: status) {
                    Text(nota)
                        .font(theme.sans.font(size: 11.5))
                        .foregroundStyle(theme.ink3.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if AccountsCopy.isFailing(status) {
                    HStack(spacing: 8) {
                        let acoes = AccountsCopy.actions(for: status).filter { $0 != .remove }
                        ForEach(Array(acoes.enumerated()), id: \.element) { indice, acao in
                            Text(acao.label)
                                .font(theme.sans.font(size: 12, weight: .semibold))
                                .foregroundStyle(indice == 0 ? theme.onAccent.color : theme.accent.color)
                                .padding(.horizontal, 13)
                                .frame(height: 28)
                                .background(
                                    indice == 0 ? theme.accent.color : theme.surface2.color,
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(
                                            indice == 0 ? theme.accent.color : theme.line2.color,
                                            lineWidth: Hairline.thickness(displayScale)
                                        )
                                }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 4)
                    Text("Remover conta…")
                        .font(theme.sans.font(size: 12, weight: .medium))
                        .foregroundStyle(theme.danger.color)
                        .padding(.top, 6)
                }
            }
        }
    }
}
