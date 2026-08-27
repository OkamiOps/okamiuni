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

    /// Tamanhos do protótipo, na linha citada no brief.
    public enum Size {
        public static let composer = CGSize(width: 820, height: 660)   // linha 790
        public static let newMessage = CGSize(width: 820, height: 620) // linha 368
        public static let message = CGSize(width: 800, height: 600)    // linha 745
        /// O protótipo diz `width: 560px; max-height: 86%` — 86% da janela
        /// principal, que não existe como conceito para uma janela de verdade.
        /// A largura é literal; a altura vira o padrão de abertura e o usuário
        /// redimensiona. 86% de 916 (a altura padrão da principal) = 788.
        public static let event = CGSize(width: 560, height: 788)
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
