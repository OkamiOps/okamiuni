import SwiftUI
import UNICore

/// As quatro janelas do protótipo, pelo identificador de cena.
///
/// Cada uma é uma **janela de verdade** — cena SwiftUI com `openWindow`, não
/// folha dentro da principal. O protótipo as chama de "em janela" e desenha
/// sombra e raio próprios; numa cena real quem desenha isso é o macOS.
///
/// O valor que cada cena carrega é sempre um `String` (id de mensagem, id de
/// compromisso, id de conta) porque `WindowGroup(id:for:)` exige um valor
/// `Codable & Hashable`, e um `Message` inteiro não é o que deve atravessar:
/// a janela relê do `MailStore` e continua vendo a mensagem atualizada quando
/// a triagem a move.
public enum UNIWindow {
    /// 03 Composer em janela — 820×660. Valor: id da mensagem respondida.
    public static let composer = "uni.composer"
    /// 06 Nova mensagem — 820×620. Valor: id da conta que envia ("" = a primeira).
    public static let newMessage = "uni.newMessage"
    /// 05 Email em janela — 800×600. Valor: id da mensagem.
    public static let message = "uni.message"
    /// 04 Detalhe do compromisso — 560 de largura. Valor: id do compromisso.
    public static let event = "uni.event"
    /// A janela de Configurações. Sem valor: ela é uma só.
    public static let accounts = "uni.accounts"
    /// 10 Assistente destacado — 460×620. Sem valor: é uma só por app, e a
    /// conversa que ela mostra vem da `AssistantSession`, não da cena.
    public static let assistant = "uni.assistant"

    /// Tamanhos do protótipo, na linha citada no brief.
    public enum Size {
        /// **980×700, a medida do mock `Compositor.dc.html`** (linha 18) —
        /// e não os 820×660 do protótipo antigo. O cabeçalho do mock põe De,
        /// Para e Assunto em linhas de texto com ações à direita, e a barra de
        /// formatação mostra os catorze ícones numa linha só: em 820 ela
        /// quebrava em duas. As duas janelas passam a ter a mesma medida,
        /// porque passaram a ter o mesmo desenho.
        public static let composer = CGSize(width: 980, height: 700)
        public static let newMessage = CGSize(width: 980, height: 700)
        /// **880×720**, a medida do desenho dos modais
        /// (`ModalJanelas.dc.html`, bloco "MENSAGEM EM JANELA") — e não os
        /// 800×600 do protótipo antigo. O leitor redesenhado tem o corpo em
        /// 15/1.65 numa coluna de 660 com 40 de recuo lateral: em 800 a coluna
        /// não cabia e a linha do assunto quebrava em duas.
        public static let message = CGSize(width: 880, height: 720)
        /// O protótipo diz `width: 560px; max-height: 86%` — 86% da janela
        /// principal, que não existe como conceito para uma janela de verdade.
        /// A largura é literal; a altura vira o padrão de abertura e o usuário
        /// redimensiona. 86% de 916 (a altura padrão da principal) = 788.
        /// **640 de largura**, do desenho dos modais (`ModalAgenda.dc.html`,
        /// bloco "COMPROMISSO ABERTO") — e não os 560 do protótipo antigo. O
        /// bloco da contagem põe "COMEÇA EM / 12 min" ao lado do botão
        /// Entrar de 26 de recuo, e em 560 os dois disputavam a linha.
        ///
        /// A altura de **abertura** passou de 788 para 640, na proporção do
        /// cartão do desenho (640 de largura por pouco mais de 600 de alto).
        /// Os 788 vinham de "86% da janela principal", medida de um protótipo
        /// em que o compromisso era um modal dentro dela; numa janela de
        /// verdade eles abriam 250pt de fundo vazio abaixo do conteúdo de um
        /// compromisso comum. Continua redimensionável.
        public static let event = CGSize(width: 640, height: 640)

        /// A navegação de Configurações soma 176pt, e a seção Contas preserva
        /// sua lista lateral de 218pt. 960 deixa detalhe útil para as duas
        /// colunas e 680 abre espaço para prompt, regras e assinaturas sem
        /// transformar a janela em uma folha apertada.
        public static let accounts = CGSize(width: 960, height: 680)

        /// `design/10-assistente-janela.dc.html`: 460 × 620, literal.
        public static let assistant = CGSize(width: 460, height: 620)
    }

    /// Marco 1 não tem rede. Enviar fecha a janela e registra no console —
    /// limite de marco, não de fidelidade: a janela fica visualmente completa.
    ///
    /// Vai para `stderr`, não para `print`: `stdout` é bufferizado quando não é
    /// terminal, e a linha se perdia quando o app era encerrado — justamente
    /// quando alguém foi conferir se o "Enviar" tinha registrado alguma coisa.
    public static func logSend(_ what: String) {
        fputs("[OkamiUNI] Marco 1 não envia nada pela rede. \(what)\n", stderr)
    }
}
