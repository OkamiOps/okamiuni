import Foundation

/// Quais seções da janela do compromisso estão abertas.
///
/// **As duas nascem recolhidas, e é pedido do dono.** Um convite de verdade tem
/// oito participantes: a lista deles tomava a janela inteira, e o que a pessoa
/// abriu a janela para ver — quando, onde, o link — ficava espremido em cima,
/// com a rolagem toda gasta em avatares. A seção "o que gerou este
/// compromisso", com a linha do email e a nota de origem soltas, comia o resto.
///
/// Recolhida, cada seção é uma linha de cabeçalho que **conta** o que esconde
/// ("Participantes · 8", "O que gerou · email de 21 de jul."), e o clique nela
/// abre. É o mesmo idioma da faixa de resposta do leitor (M3-12) e da pilha de
/// conversa (M3-9/M3-11): o cabeçalho é o controle, e o estado não atravessa a
/// abertura seguinte — abrir a janela é começar de novo.
///
/// Mora em `UNICore`, fora da `View`, pela razão de sempre nesta base: `View` é
/// `@MainActor` implícito no Swift 6, e um `static` lá dentro trapa quando um
/// teste nonisolated o chama. Ver `docs/decisoes-de-engenharia.md`.
public struct EventSections: Sendable, Hashable {

    /// A lista de participantes está aberta?
    public var participants: Bool
    /// "O que gerou este compromisso" está aberta?
    public var origin: Bool

    /// **Recolhidas** é o estado de nascimento — o padrão de todo lugar que
    /// não diz o contrário. Os parâmetros existem para o teste montar o outro
    /// estado sem alternar duas vezes.
    public init(participants: Bool = false, origin: Bool = false) {
        self.participants = participants
        self.origin = origin
    }

    public mutating func toggleParticipants() { participants.toggle() }
    public mutating func toggleOrigin() { origin.toggle() }

    /// Quem a seção de participantes desenha.
    ///
    /// Recolhida mostra **o organizador, e só ele**: é a linha que responde
    /// "de quem é esta reunião" sem custar oito. Vazia continua vazia — um
    /// `prefix` numa lista vazia é uma lista vazia, e não uma linha em branco.
    public static func visibleGuests(_ guests: [EventPerson], expanded: Bool) -> [EventPerson] {
        expanded ? guests : Array(guests.prefix(1))
    }

    /// Quantas linhas a seção recolhida deixa de fora. É o número que o
    /// cabeçalho usa para dizer o que está escondendo.
    public static func hiddenGuestCount(_ guests: [EventPerson], expanded: Bool) -> Int {
        max(0, guests.count - visibleGuests(guests, expanded: expanded).count)
    }

    /// O cabeçalho de "o que gerou": ele diz **de quando** é o email, para a
    /// seção recolhida ainda responder alguma coisa.
    ///
    /// Sem linha de email (um compromisso que a IA detectou, ou o de série
    /// recorrente) fica o título de sempre — inventar "email de …" onde não há
    /// email seria o cabeçalho mentindo sobre o que esconde.
    public static func originHeader(_ thread: [EventThreadEntry]) -> String {
        guard let email = thread.first(where: { $0.kind == .email }), !email.when.isEmpty else {
            return "O que gerou este compromisso"
        }
        return "O que gerou · email de \(email.when)"
    }
}
