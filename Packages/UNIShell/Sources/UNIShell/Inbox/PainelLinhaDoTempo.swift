import AppKit
import SwiftUI
import UNICore
import UNIDesign

/// A linha do tempo horizontal do "Plano de hoje": o dia inteiro numa densidade
/// fixa, duas trilhas, e a rolagem em vez do encolhimento.
///
/// Em cima o que **já está marcado** (`agenda`), embaixo o que a IA propõe e o
/// que vence (`você`). A posição de cada bloco é a que o `PlanoDoDia` calcula —
/// a `View` não faz conta de horário, só mede o texto e desenha.
///
/// **Por que rola.** A janela que se estreitava para caber na largura punha
/// 24 h em 1380 pt, e nessa densidade um compromisso de meia hora tem 28 pt:
/// coube "09:30" e não coube "Odette". O eixo agora tem 3312 pt, o painel
/// mostra o pedaço que cabe, e ao aparecer ele rola para deixar o agora a 35%
/// da largura visível — o que já passou fica atrás, o que vem fica à frente.
struct PainelLinhaDoTempo: View {

    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let blocos: [PlanoDoDia.Bloco]
    let nowMinute: Int
    /// Clique num bloco proposto — "Ajustar" abre o seletor de hora.
    let onTapProposto: (PlanoDoDia.Bloco) -> Void

    private let alturaDoBloco: CGFloat = 28
    /// A folga entre a trilha da agenda e a trilha "você".
    private let entreTrilhas: CGFloat = 10
    private let topoDaAgenda: CGFloat = 12
    /// Quanto sobra abaixo da última trilha para a linha do eixo e as horas.
    private let rodapeDoEixo: CGFloat = 40
    private let larguraDosRotulos: CGFloat = 46
    /// O esmaecimento das bordas: 24 pt dizendo que o eixo continua.
    private let esmaecimento: CGFloat = 24

    var body: some View {
        let desenho = Desenho(
            agenda: postos(.agenda), voce: postos(.voce),
            alturaDoBloco: alturaDoBloco, topoDaAgenda: topoDaAgenda,
            entreTrilhas: entreTrilhas, rodapeDoEixo: rodapeDoEixo
        )
        HStack(alignment: .top, spacing: 0) {
            rotulos(desenho)
            eixo(desenho)
        }
        .frame(height: desenho.altura)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Linha do tempo de hoje")
    }

    // MARK: - As medidas do quadro

    /// Onde cada trilha começa e onde o eixo cai, depois de as sub-linhas
    /// dizerem quanta altura elas precisam.
    private struct Desenho {
        let agenda: [Posicionado]
        let voce: [Posicionado]
        let topoDaAgenda: CGFloat
        let topoDoVoce: CGFloat
        let linhaDoEixo: CGFloat
        let altura: CGFloat
        /// A largura rolável. É o eixo do dia, **mais** o que passar dele: o
        /// voo das 23h30 escreve o nome depois da meia-noite, e um conteúdo do
        /// tamanho exato do eixo cortava esse nome ao meio.
        let largura: CGFloat

        init(
            agenda: [Posicionado], voce: [Posicionado],
            alturaDoBloco: CGFloat, topoDaAgenda: CGFloat,
            entreTrilhas: CGFloat, rodapeDoEixo: CGFloat
        ) {
            self.agenda = agenda
            self.voce = voce
            self.topoDaAgenda = topoDaAgenda
            let passo = CGFloat(PlanoDoDia.alturaDaSubLinha)
            func altura(_ postos: [Posicionado]) -> CGFloat {
                let linhas = (postos.map(\.posto.subLinha).max() ?? 0) + 1
                return alturaDoBloco + CGFloat(linhas - 1) * passo
            }
            topoDoVoce = topoDaAgenda + altura(agenda) + entreTrilhas
            linhaDoEixo = topoDoVoce + altura(voce) + 12
            self.altura = linhaDoEixo + rodapeDoEixo
            let ultimoFim = (agenda + voce)
                .map { $0.posto.x + $0.posto.largura }.max() ?? 0
            // A sobra é o esmaecimento (24) mais folga: sem ela o último
            // bloco acaba **debaixo** do véu da borda, e a palavra desbotada
            // lê como texto cortado em vez de "o eixo continua".
            largura = CGFloat(max(PlanoDoDia.larguraDoEixo, ultimoFim) + 40)
        }

        func topo(da trilha: PlanoDoDia.Trilha) -> CGFloat {
            trilha == .agenda ? topoDaAgenda : topoDoVoce
        }
    }

    private struct Posicionado {
        let bloco: PlanoDoDia.Bloco
        let posto: PlanoDoDia.Posto
    }

    /// A posição de cada bloco de uma trilha. A `View` mede o texto; a regra de
    /// onde ele cai é do `PlanoDoDia`.
    private func postos(_ trilha: PlanoDoDia.Trilha) -> [Posicionado] {
        let daTrilha = blocos.filter { $0.trilha == trilha }
        guard !daTrilha.isEmpty else { return [] }
        let postos = PlanoDoDia.postos(daTrilha.map { bloco in
            (
                id: bloco.id, startMinute: bloco.startMinute,
                minutes: bloco.minutes, tituloEmPontos: Double(larguraDoTexto(bloco))
            )
        })
        let porID = Dictionary(uniqueKeysWithValues: daTrilha.map { ($0.id, $0) })
        return postos.compactMap { posto in
            porID[posto.id].map { Posicionado(bloco: $0, posto: posto) }
        }
    }

    // MARK: - Os rótulos das trilhas

    /// Os nomes das trilhas, em versalete, **fora** da rolagem: eles dizem de
    /// quem é a linha, e uma legenda que sai da tela ao rolar não diz nada.
    private func rotulos(_ desenho: Desenho) -> some View {
        ZStack(alignment: .topLeading) {
            Text("agenda")
                .capsLabel(size: 9)
                .foregroundStyle(theme.ink3.color)
                .offset(y: desenho.topoDaAgenda + 8)
            Text("você")
                .capsLabel(size: 9)
                .foregroundStyle(theme.accentInk.color)
                .offset(y: desenho.topoDoVoce + 8)
        }
        .frame(width: larguraDosRotulos, height: desenho.altura, alignment: .topLeading)
    }

    // MARK: - O eixo que rola

    private func eixo(_ desenho: Desenho) -> some View {
        ScrollViewReader { leitor in
            ScrollView(.horizontal) {
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(theme.line.color)
                        .frame(height: Hairline.thickness(displayScale))
                        .offset(y: desenho.linhaDoEixo)
                    horas(desenho)
                    ForEach(desenho.agenda + desenho.voce, id: \.bloco.id) { posto in
                        desenha(posto, em: desenho)
                    }
                    agora(desenho)
                    marcaDoAgora
                }
                .frame(
                    width: desenho.largura,
                    height: desenho.altura, alignment: .topLeading
                )
            }
            .scrollIndicators(.hidden)
            .onAppear {
                // Sem animação: a linha do tempo já nasce no lugar certo, em
                // vez de deslizar sozinha assim que o painel abre.
                leitor.scrollTo(Self.ancoraDoAgora, anchor: UnitPoint(x: 0.35, y: 0))
            }
        }
        .frame(height: desenho.altura)
        .overlay(alignment: .leading) { veu(.leading) }
        .overlay(alignment: .trailing) { veu(.trailing) }
    }

    private static let ancoraDoAgora = "linha-do-tempo-agora"

    /// A âncora da rolagem. É uma view de verdade no fluxo — `offset` moveria o
    /// desenho sem mover o quadro, e `scrollTo` rolaria para o lugar errado.
    private var marcaDoAgora: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: CGFloat(PlanoDoDia.x(nowMinute)), height: 1)
            Color.clear.frame(width: 1, height: 1).id(Self.ancoraDoAgora)
            Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
    }

    /// O esmaecimento das bordas: o eixo continua para os dois lados, e é isto
    /// que diz isso sem uma barra de rolagem atravessada no desenho.
    private func veu(_ borda: HorizontalAlignment) -> some View {
        LinearGradient(
            colors: [theme.surface.color, theme.surface.color.opacity(0)],
            startPoint: borda == .leading ? .leading : .trailing,
            endPoint: borda == .leading ? .trailing : .leading
        )
        .frame(width: esmaecimento)
        .allowsHitTesting(false)
    }

    private func horas(_ desenho: Desenho) -> some View {
        ForEach(PlanoDoDia.horasDoEixo, id: \.self) { minuto in
            // 24 h é meia-noite do dia seguinte, e o eixo escreve "24" em vez
            // de um segundo "00" que pareceria o começo.
            Text(String(format: "%02d", minuto / 60))
                .font(theme.mono.font(size: 10))
                .foregroundStyle(theme.ink4.color)
                .fixedSize()
                .offset(x: CGFloat(PlanoDoDia.x(minuto)) - 8, y: desenho.linhaDoEixo + 8)
        }
    }

    // MARK: - O bloco

    @ViewBuilder
    private func desenha(_ posicionado: Posicionado, em desenho: Desenho) -> some View {
        let bloco = posicionado.bloco
        let posto = posicionado.posto
        let y = desenho.topo(da: bloco.trilha)
            + CGFloat(posto.subLinha) * CGFloat(PlanoDoDia.alturaDaSubLinha)

        HStack(spacing: Self.entreTituloEDuracao) {
            // Sempre o título, inteiro: a largura foi calculada para ele caber.
            // "Te…", ou um chip escrito "01:00", não dizem o que está agendado.
            Text(bloco.title)
                .font(theme.sans.font(size: Self.tamanhoDoTitulo, weight: .semibold))
                .foregroundStyle(cor(bloco))
                .lineLimit(1)
                .fixedSize()
            if !bloco.duration.isEmpty {
                Text(bloco.duration)
                    .font(theme.mono.font(size: Self.tamanhoDaDuracao))
                    .foregroundStyle(
                        bloco.tipo == .proposto ? theme.accentInk.color : theme.ink4.color
                    )
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, CGFloat(PlanoDoDia.respiroDoBloco) / 2)
        .frame(width: CGFloat(posto.largura), height: alturaDoBloco, alignment: .leading)
        .background(fundo(bloco))
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusSmall))
        .overlay { borda(bloco) }
        .offset(x: CGFloat(posto.x), y: y)
        .contentShape(Rectangle())
        .onTapGesture { if bloco.tipo == .proposto { onTapProposto(bloco) } }
        .help(rotulo(bloco))
        .accessibilityLabel(rotulo(bloco))
    }

    private static let tamanhoDoTitulo: CGFloat = 11.5
    private static let tamanhoDaDuracao: CGFloat = 9.5
    private static let entreTituloEDuracao: CGFloat = 6

    /// Quanto o bloco precisa para escrever o que tem a escrever.
    ///
    /// Medir tipo é coisa do AppKit, e é a única razão de esta `View` conhecer
    /// `NSFont`: o `PlanoDoDia` recebe o número pronto e decide o resto.
    private func larguraDoTexto(_ bloco: PlanoDoDia.Bloco) -> CGFloat {
        var largura = Self.medida(
            bloco.title, familia: theme.sans,
            tamanho: Self.tamanhoDoTitulo, peso: .semibold
        )
        if !bloco.duration.isEmpty {
            largura += Self.entreTituloEDuracao + Self.medida(
                bloco.duration, familia: theme.mono,
                tamanho: Self.tamanhoDaDuracao, peso: .regular
            )
        }
        return largura
    }

    private static func medida(
        _ texto: String, familia: FontFamily, tamanho: CGFloat, peso: NSFont.Weight
    ) -> CGFloat {
        let fonte = nsFont(familia, tamanho: tamanho, peso: peso)
        let medido = (texto as NSString)
            .size(withAttributes: [.font: fonte]).width
        return ceil(medido)
    }

    /// O `NSFont` equivalente ao token do tema. Cai no do sistema quando a face
    /// do desenho não está instalada — que é exatamente o que
    /// `FontFamily.font(size:weight:)` faz na hora de desenhar.
    private static func nsFont(
        _ familia: FontFamily, tamanho: CGFloat, peso: NSFont.Weight
    ) -> NSFont {
        let resolvido = tamanho * familia.scale
        if let nome = familia.name, FontRegistry.isAvailable(nome),
           let fonte = NSFontManager.shared.font(
               withFamily: nome,
               traits: peso >= .semibold ? .boldFontMask : [],
               weight: peso >= .semibold ? 8 : 5,
               size: resolvido
           )
        {
            return fonte
        }
        return .systemFont(ofSize: resolvido, weight: peso)
    }

    private func cor(_ bloco: PlanoDoDia.Bloco) -> Color {
        switch bloco.tipo {
        case .compromisso: theme.ink.color
        case .proposto: theme.accentInk.color
        case .prazo: theme.warning.color
        }
    }

    private func fundo(_ bloco: PlanoDoDia.Bloco) -> Color {
        switch bloco.tipo {
        case .compromisso: theme.btn.color
        case .proposto: theme.accentSoft.color
        // O prazo é vazado: ele não ocupa tempo, ele acaba.
        case .prazo: .clear
        }
    }

    @ViewBuilder
    private func borda(_ bloco: PlanoDoDia.Bloco) -> some View {
        let forma = RoundedRectangle(cornerRadius: theme.radiusSmall)
        let espessura = Hairline.thickness(displayScale)
        switch bloco.tipo {
        case .compromisso:
            forma.strokeBorder(theme.btnLine.color, lineWidth: espessura)
        case .proposto:
            forma.strokeBorder(
                theme.accentLine.color,
                style: StrokeStyle(lineWidth: espessura, dash: [3, 3])
            )
        case .prazo:
            forma.strokeBorder(theme.warning.color.opacity(0.4), lineWidth: espessura)
        }
    }

    private func rotulo(_ bloco: PlanoDoDia.Bloco) -> String {
        let hora = MinuteFormat.clock(bloco.startMinute)
        switch bloco.tipo {
        case .compromisso: return "\(hora), \(bloco.title)"
        case .proposto: return "Proposto às \(hora), \(bloco.title)"
        case .prazo: return "Prazo às \(hora), \(bloco.title)"
        }
    }

    /// O marcador do agora: linha de 1.5 em accent com o ponto de 7 em cima.
    private func agora(_ desenho: Desenho) -> some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(theme.accent.color)
                .frame(width: 1.5, height: desenho.linhaDoEixo - 4)
            Circle()
                .fill(theme.accent.color)
                .frame(width: 7, height: 7)
                .offset(y: -4)
        }
        .offset(x: CGFloat(PlanoDoDia.x(nowMinute)) - 0.75, y: 4)
        .accessibilityLabel("Agora")
    }
}
