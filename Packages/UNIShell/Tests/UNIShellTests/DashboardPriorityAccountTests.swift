import Foundation
import Testing
import UNICore
@testable import UNIShell

/// A linha de PRIORIDADES diz de qual caixa a mensagem veio.
///
/// A queixa do dono foi literal: "eu não sei qual a caixa". Ele tem três
/// contas, e só a prévia dizia — no cabeçalho "PRÉVIA · VANTION". A linha
/// tinha a barra de tinta e mais nada, e tinta sozinha é uma cor que a pessoa
/// precisa decorar.
@Suite("A linha de prioridade mostra a conta")
struct DashboardPriorityAccountTests {

    @Test("a leitura em voz alta nomeia a conta")
    func vozAltaNomeiaAConta() {
        let label = DashboardMetrics.rowAccessibilityLabel(
            sender: "Jack Whitmore", subject: "Pode confirmar sexta?",
            reason: .needsReply, account: "vantion"
        )
        #expect(label.contains("vantion"))
        #expect(label.contains("Jack Whitmore"))
        #expect(label.contains("Precisa resposta"))
    }

    @Test("sem conta conhecida, a leitura não inventa nem deixa vírgula solta")
    func semContaNaoInventa() {
        let label = DashboardMetrics.rowAccessibilityLabel(
            sender: "Jack", subject: "Oi", reason: .today, account: ""
        )
        #expect(!label.hasSuffix(", "))
        #expect(!label.contains(", ,"))
    }

    @Test("a marca da conta é curta e em versalete — não cabe endereço inteiro")
    func marcaECurta() {
        #expect(DashboardMetrics.accountMark(host: "vantion", address: "x@vantion.com.br") == "VANTION")
        // Sem marca de host, o domínio serve: o que não vale é a linha ficar muda.
        #expect(DashboardMetrics.accountMark(host: "", address: "marcos@okamiops.com") == "OKAMIOPS")
        #expect(DashboardMetrics.accountMark(host: "", address: "") == "")
        // Marca comprida é cortada: a linha tem remetente, assunto e hora, e
        // um selo de vinte caracteres empurraria os três.
        #expect(DashboardMetrics.accountMark(host: "umhostbemcompridomesmo", address: "").count <= 10)
    }

    @Test("o chip do disparo é discreto, e o da resposta não")
    func disparoEDiscreto() {
        #expect(DashboardMetrics.chipRole(for: .broadcast) == .quiet)
        #expect(DashboardMetrics.chipRole(for: .needsReply) == .warning)
    }
}
