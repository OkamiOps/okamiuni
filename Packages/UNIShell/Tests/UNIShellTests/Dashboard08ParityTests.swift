import Foundation
import Testing
import UNICore
@testable import UNIShell

/// A régua do 08: **o desenho é a especificação**, então cada medida do Swift
/// é conferida contra o próprio `design/08-dashboard-ia.dc.html` — o número
/// lido do CSS de um lado, a constante de `DashboardMetrics` do outro.
/// Divergência é defeito com o número dos dois lados na mensagem.
@Suite("Dashboard 08 · paridade com o mockup")
struct Dashboard08ParityTests {

    /// O HTML aprovado, lido do repositório.
    static let html: String = {
        let raiz = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Dashboard08ParityTests.swift
            .deletingLastPathComponent()   // UNIShellTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // UNIShell
            .deletingLastPathComponent()   // Packages
        return (try? String(
            contentsOf: raiz.appendingPathComponent("design/08-dashboard-ia.dc.html"),
            encoding: .utf8
        )) ?? ""
    }()

    /// O primeiro grupo de captura de `pattern` sobre o HTML, como número.
    private func medida(_ pattern: String) throws -> Double {
        let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let html = Self.html
        let alcance = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: alcance),
              match.numberOfRanges > 1,
              let faixa = Range(match.range(at: 1), in: html),
              let valor = Double(html[faixa])
        else {
            Issue.record("o mockup não tem \(pattern) — a régua mudou de lugar?")
            return .nan
        }
        return valor
    }

    @Test("o mockup está no lugar")
    func mockupExists() {
        #expect(!Self.html.isEmpty)
        #expect(Self.html.contains("Comece por aqui"))
    }

    @Test("a moldura: padding 28 32 24")
    func contentPadding() throws {
        _ = try medida(#"padding: (28)px 32px 24px"#)
        #expect(DashboardMetrics.contentPadding.top == 28)
        #expect(DashboardMetrics.contentPadding.leading == 32)
        #expect(DashboardMetrics.contentPadding.bottom == 24)
    }

    @Test("o cabeçalho: saudação 22/600 e o relógio 11.5")
    func headerMeasures() throws {
        #expect(try medida(#"font-size: (22)px; font-weight: 600; letter-spacing: -0\.01em"#) == 22)
        #expect(DashboardMetrics.greetingSize == 22)
        #expect(try medida(#"gap: 18px; font-size: (11\.5)px; color: #55566A"#) == 11.5)
        #expect(DashboardMetrics.statusSize == 11.5)
        #expect(DashboardMetrics.headerGap == 18)
    }

    @Test("o herói: margem 22, pad 22 26, frase 20/500, botão 34")
    func heroMeasures() throws {
        #expect(try medida(#"margin-top: (22)px; padding: 22px 26px; background: #1A1209"#) == 22)
        #expect(DashboardMetrics.heroTopSpacing == 22)
        #expect(DashboardMetrics.heroPadding.top == 22)
        #expect(DashboardMetrics.heroPadding.leading == 26)
        #expect(try medida(#"font-size: (20)px; font-weight: 500; line-height: 1\.35"#) == 20)
        #expect(DashboardMetrics.heroSentenceSize == 20)
        #expect(try medida(#"height: (34)px; padding: 0 18px"#) == 34)
        #expect(DashboardMetrics.heroButtonHeight == 34)
        #expect(DashboardMetrics.heroButtonPadding == 18)
        #expect(try medida(#"align-items: center; gap: (28)px"#) == 28)
        #expect(DashboardMetrics.heroGap == 28)
    }

    @Test("as colunas: lista pad-right 32, prévia 360 + 32, dia 248 + 32")
    func columnMeasures() throws {
        #expect(try medida(#"padding-right: (32)px; overflow: hidden"#) == 32)
        #expect(DashboardMetrics.listTrailingPadding == 32)
        #expect(try medida(#"width: (360)px; flex: none;[^;]*; flex-direction: column; padding-left: 32px"#) == 360)
        #expect(DashboardMetrics.previewWidth == 360)
        #expect(DashboardMetrics.previewLeadingPadding == 32)
        #expect(try medida(#"width: (248)px; flex: none"#) == 248)
        #expect(DashboardMetrics.dayWidth == 248)
        #expect(DashboardMetrics.dayLeadingPadding == 32)
        // A hairline do dia leva a margem de 32 à esquerda.
        #expect(try medida(#"background: #1E1E2B; margin-top: 22px; margin-left: (32)px"#) == 32)
        #expect(DashboardMetrics.dayDividerLeadingSpacing == 32)
        // E as colunas começam 22 abaixo do herói.
        #expect(try medida(#"background: #1E1E2B; margin-top: (22)px"#) == 22)
        #expect(DashboardMetrics.columnsTopSpacing == 22)
    }

    @Test("o filtro: texto 13, gap 22, contagem 10.5, sublinhado 1.5")
    func filterMeasures() throws {
        #expect(try medida(#"\.flt \{ display: flex; align-items: baseline; gap: (22)px"#) == 22)
        #expect(DashboardMetrics.filterGap == 22)
        #expect(try medida(#"\.flt \{[^}]*font-size: (13)px"#) == 13)
        #expect(DashboardMetrics.filterTextSize == 13)
        #expect(try medida(#"\.flt em \{[^}]*font-size: (10\.5)px"#) == 10.5)
        #expect(DashboardMetrics.filterCountSize == 10.5)
        #expect(try medida(#"\.flt span\.on \{[^}]*border-bottom: (1\.5)px"#) == 1.5)
        #expect(DashboardMetrics.filterUnderlineThickness == 1.5)
        #expect(try medida(#"padding: (22)px 0 10px; border-bottom"#) == 22)
        #expect(DashboardMetrics.filterRowPadding.top == 22)
        #expect(DashboardMetrics.filterRowPadding.bottom == 10)
        // As contas: ponto de 7ø e nome 11.5, gap 14.
        #expect(try medida(#"width: (7)px; height: 7px; border-radius: 50%"#) == 7)
        #expect(DashboardMetrics.accountDotSide == 7)
        #expect(try medida(#"gap: (14)px; font-size: 11\.5px; color: #7B7C90"#) == 14)
        #expect(DashboardMetrics.accountGap == 14)
        #expect(DashboardMetrics.accountNameSize == 11.5)
    }

    @Test("a seção: pad 26 0 6, primeira 18, contagem mono 10")
    func sectionMeasures() throws {
        #expect(try medida(#"\.sec \{[^}]*padding: (26)px 0 6px"#) == 26)
        #expect(DashboardMetrics.sectionTopPadding == 26)
        #expect(DashboardMetrics.sectionBottomPadding == 6)
        #expect(try medida(#"padding-top: (18)px;"#) == 18)
        #expect(DashboardMetrics.firstSectionTopPadding == 18)
        #expect(try medida(#"\.sec \.n \{[^}]*font-size: (10)px"#) == 10)
        #expect(DashboardMetrics.sectionCountSize == 10)
    }

    @Test("a linha: grid 18 + 1fr, gap 12, pad 14 0 15, ponto 8ø, sangria 22")
    func rowMeasures() throws {
        #expect(try medida(#"\.row \{ padding: (14)px 0 15px"#) == 14)
        #expect(DashboardMetrics.rowTopPadding == 14)
        #expect(DashboardMetrics.rowBottomPadding == 15)
        #expect(try medida(#"grid-template-columns: (18)px 1fr; column-gap: 12px"#) == 18)
        #expect(DashboardMetrics.rowLeadingWidth == 18)
        #expect(DashboardMetrics.rowColumnGap == 12)
        #expect(try medida(#"\.row \.dot \{ width: (8)px"#) == 8)
        #expect(DashboardMetrics.rowDotSide == 8)
        #expect(try medida(#"\.row \.dot \{[^}]*margin-top: (6)px"#) == 6)
        #expect(DashboardMetrics.rowDotTopSpacing == 6)
        #expect(try medida(#"\.row\.sel \{[^}]*margin: 0 -(22)px"#) == 22)
        #expect(DashboardMetrics.selectionBleed == 22)
    }

    @Test("a tipografia da linha: remetente 13/600, conta 10, hora 11, assunto 15/500")
    func rowTypography() throws {
        #expect(try medida(#"\.row \.from \{[^}]*font-size: (13)px; font-weight: 600"#) == 13)
        #expect(DashboardMetrics.rowSenderSize == 13)
        #expect(try medida(#"\.row \.acct \{[^}]*font-size: (10)px"#) == 10)
        #expect(DashboardMetrics.rowAccountSize == 10)
        #expect(try medida(#"\.row \.time \{[^}]*font-size: (11)px"#) == 11)
        #expect(DashboardMetrics.rowTimeSize == 11)
        #expect(try medida(#"\.row \.subj \{ margin-top: (3)px"#) == 3)
        #expect(DashboardMetrics.rowSubjectTopSpacing == 3)
        #expect(try medida(#"\.row \.subj \{[^}]*font-size: (15)px; font-weight: 500"#) == 15)
        #expect(DashboardMetrics.rowSubjectSize == 15)
    }

    @Test("a linha ↳: margem 8, texto 13, ações 12.5/600 com gap 14")
    func proposalMeasures() throws {
        #expect(try medida(#"\.row \.ai \{ margin-top: (8)px"#) == 8)
        #expect(DashboardMetrics.proposalTopSpacing == 8)
        #expect(try medida(#"\.row \.ai \{[^}]*font-size: (13)px"#) == 13)
        #expect(DashboardMetrics.proposalTextSize == 13)
        #expect(try medida(#"\.row \.ai \.acts \{[^}]*gap: (14)px"#) == 14)
        #expect(DashboardMetrics.proposalActionGap == 14)
        #expect(try medida(#"\.row \.ai \.acts \{[^}]*font-size: (12\.5)px"#) == 12.5)
        #expect(DashboardMetrics.proposalActionSize == 12.5)
    }

    @Test("o rodapé da lista: pad-top 14, texto 12.5")
    func listFooterMeasures() throws {
        #expect(try medida(#"padding-top: (14)px; font-size: 12\.5px; line-height: 1\.5"#) == 14)
        #expect(DashboardMetrics.listFooterTopPadding == 14)
        #expect(DashboardMetrics.listFooterSize == 12.5)
    }

    @Test("a prévia: assunto 17/500, cartão 22 acima com pad 16 18, corpo 14")
    func previewMeasures() throws {
        #expect(try medida(#"font-size: (17)px; font-weight: 500; line-height: 1\.3"#) == 17)
        #expect(DashboardMetrics.previewSubjectSize == 17)
        #expect(try medida(#"margin-top: (22)px; padding: 16px 18px; background: #0B0B12"#) == 22)
        #expect(DashboardMetrics.draftCardTopSpacing == 22)
        #expect(DashboardMetrics.draftCardPadding.top == 16)
        #expect(DashboardMetrics.draftCardPadding.leading == 18)
        #expect(try medida(#"margin-top: 12px; font-size: (14)px; line-height: 1\.65"#) == 14)
        #expect(DashboardMetrics.draftBodySize == 14)
        #expect(DashboardMetrics.draftBodyTopSpacing == 12)
        // As ações do cartão: 16 acima, gap 18, Enviar 30 de altura.
        #expect(try medida(#"margin-top: (16)px; display: flex; align-items: center; gap: 18px"#) == 16)
        #expect(DashboardMetrics.draftActionsTopSpacing == 16)
        #expect(DashboardMetrics.draftActionsGap == 18)
        #expect(try medida(#"\.btn \{ height: (30)px; padding: 0 14px"#) == 30)
        #expect(DashboardMetrics.sendButtonHeight == 30)
        #expect(DashboardMetrics.buttonPadding == 14)
        #expect(try medida(#"\.btn \{[^}]*font-size: (12\.5)px"#) == 12.5)
        #expect(DashboardMetrics.actionTextSize == 12.5)
        // "O que ele escreveu": resumo 13.5/1.6 e o "Ler o email inteiro".
        #expect(try medida(#"margin-top: 8px; font-size: (13\.5)px; line-height: 1\.6"#) == 13.5)
        #expect(DashboardMetrics.wroteSummarySize == 13.5)
        #expect(DashboardMetrics.wroteSummaryTopSpacing == 8)
        #expect(try medida(#"margin-top: (10)px; font-size: 12\.5px; font-weight: 600; color: #7B7C90"#) == 10)
        #expect(DashboardMetrics.readWholeTopSpacing == 10)
    }

    @Test("o dia: título 13/600, evento 44 + 1fr, hora 11.5, bloco 6/-12/12")
    func dayMeasures() throws {
        #expect(try medida(#"\.ev \{ display: grid; grid-template-columns: (44)px 1fr"#) == 44)
        #expect(DashboardMetrics.eventHourWidth == 44)
        #expect(try medida(#"\.ev \{[^}]*column-gap: (12)px; padding: 10px 0"#) == 12)
        #expect(DashboardMetrics.eventColumnGap == 12)
        #expect(DashboardMetrics.eventVerticalPadding == 10)
        #expect(try medida(#"\.ev \.h \{[^}]*font-size: (11\.5)px"#) == 11.5)
        #expect(DashboardMetrics.eventHourSize == 11.5)
        #expect(try medida(#"\.ev \.n \{[^}]*font-size: (13)px"#) == 13)
        #expect(DashboardMetrics.eventTitleSize == 13)
        #expect(try medida(#"\.ev \.s \{[^}]*font-size: (11\.5)px"#) == 11.5)
        #expect(DashboardMetrics.eventSubSize == 11.5)
        #expect(try medida(#"\.ev\.plan \{[^}]*margin: (6)px -12px; padding: 12px 12px"#) == 6)
        #expect(DashboardMetrics.planBlockVerticalMargin == 6)
        #expect(DashboardMetrics.planBlockBleed == 12)
        #expect(DashboardMetrics.planBlockPadding == 12)
        // "Agora": pad 8 0.
        #expect(try medida(#"gap: 8px; padding: (8)px 0"#) == 8)
        #expect(DashboardMetrics.nowVerticalPadding == 8)
        #expect(try medida(#"opacity: (0\.5)"#) == 0.5)
        #expect(DashboardMetrics.nowLineOpacity == 0.5)
        // Lista 14 abaixo do título 13/600.
        #expect(DashboardMetrics.dayTitleSize == 13)
        #expect(DashboardMetrics.dayListTopSpacing == 14)
    }

    @Test("o botão Perguntar: right 24, bottom 20, 36 alto, raio 18, ícone 15")
    func askButtonMeasures() throws {
        #expect(try medida(#"right: (24)px; bottom: 20px"#) == 24)
        #expect(DashboardMetrics.askButtonTrailing == 24)
        #expect(DashboardMetrics.askButtonBottom == 20)
        #expect(try medida(#"height: (36)px; padding: 0 14px 0 12px; border-radius: 18px"#) == 36)
        #expect(DashboardMetrics.askButtonHeight == 36)
        #expect(DashboardMetrics.askButtonLeadingPadding == 12)
        #expect(DashboardMetrics.askButtonTrailingPadding == 14)
        #expect(DashboardMetrics.askButtonRadius == 18)
        #expect(try medida(#"gap: (9)px; height: 36px"#) == 9)
        #expect(DashboardMetrics.askButtonGap == 9)
        #expect(try medida(#"svg width="(15)""#) == 15)
        #expect(DashboardMetrics.askIconSize == 15)
        #expect(try medida(#"box-shadow: 0 (10)px 30px rgba\(0,0,0,0\.55\)"#) == 10)
        #expect(DashboardMetrics.askShadowY == 10)
        #expect(DashboardMetrics.askShadowOpacity == 0.55)
        #expect(DashboardMetrics.askLabelSize == 12.5)
        #expect(DashboardMetrics.askShortcutSize == 10)
    }
}
