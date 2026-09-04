import SwiftUI
import UNICore
import UNIDesign

/// A conversa inteira, **mais nova no topo**: a recente abre com o corpo
/// completo, as mais antigas ficam recolhidas embaixo. É a pilha do Gmail.
///
/// Sem árvore e sem preferência de "agrupar sim/não": os grandes empilham em
/// ordem, e é o que a conversa é.
///
/// **Toda** mensagem da pilha tem a linha de cabeçalho, aberta ou não —
/// inclusive a que o leitor abriu sozinho: sem cabeçalho não haveria onde
/// clicar para recolhê-la.
///
/// ## Por que é uma `View` própria, e não um método do `ReaderPane`
///
/// Porque o defeito desta tarefa mora **no clique**, e um clique só se prova
/// com o clique de verdade — a lição que `SwipeRehearsal` deixou no projeto.
/// Uma `View` com fronteira própria pode ser hospedada sozinha numa janela fora
/// da tela, com a primeira linha em `y = 0`, e receber um evento sintético
/// dentro do processo. Como método privado de uma tela de 900 linhas, a linha
/// da pilha só era alcançável adivinhando coordenadas. Ver
/// `ConversationStackClickTests`.
///
/// O estado de abertura **não** mora aqui: ele vem por `Binding` do
/// `ReaderPane`, porque quem precisa esquecê-lo ao trocar de conversa é o
/// leitor, e a conversa de uma mensagem só não desenha pilha nenhuma — ver
/// `ConversationStack.carried`.
struct ConversationStackView<Corpo: View>: View {
    @Environment(\.theme) private var theme

    let store: MailStore
    let conversa: Conversation
    @Binding var opened: ConversationStack.Opened?
    /// Os cartões e o corpo de uma mensagem aberta — o miolo do leitor, que
    /// continua sendo desenhado pelo `ReaderPane` para não haver uma segunda
    /// cópia dele que divirja no próximo conserto de espaçamento.
    @ViewBuilder let corpo: (Message) -> Corpo

    var body: some View {
        let abertas = ConversationStack.expanded(conversa, opened: opened)
        VStack(alignment: .leading, spacing: 0) {
            cabecalhoDaPilha
            ForEach(conversa.newestFirst) { message in
                let aberta = abertas.contains(message.id)
                VStack(alignment: .leading, spacing: 0) {
                    linha(message, aberta: aberta)
                    if aberta { corpo(message) }
                }
                // **Abrir uma mensagem da pilha é pedir o corpo dela.**
                //
                // Era este o defeito da tela do dono: clicar na linha recolhida
                // "não abria nada". A linha abria — e mostrava vazio. O pedido
                // de corpo era um `.task` pendurado no leitor inteiro, e o
                // leitor inteiro é **uma** mensagem, a selecionada. Nenhuma
                // outra da pilha chegava a pedir corpo nenhum, então
                // `MailStore.bodyLoad(for:)` continuava `nil` para ela — e
                // `nil` é o ramo que `ReaderPane.body(_:)` desenha como
                // `EmptyView`, de propósito, porque é o caso das fixtures do
                // Marco 1. Resultado: uma mensagem antiga de conta real (39 das
                // 83 do dono estão no banco sem corpo) expandia para nada.
                //
                // `id` com o `aberta` junto para o pedido sair no clique que
                // abre, e não na montagem da pilha: baixar de uma vez o corpo
                // de toda conversa longa que a pessoa passa os olhos seria uma
                // conexão por mensagem que ninguém pediu.
                .task(id: aberta ? message.id : nil) {
                    guard aberta else { return }
                    await store.loadBodyIfNeeded(message.id)
                }
            }
        }
        // A pilha nasce com a mais recente já expandida. Isso **é** ler a
        // última: o clique na linha da lista não precisa ser repetido no
        // cabeçalho da pilha — expandir e recolher a aberta era o único jeito
        // de o clique de "abrir" disparar.
        .task(id: conversa.key) {
            let abertasAgora = ConversationStack.expanded(conversa, opened: opened)
            guard abertasAgora.contains(conversa.latest.id) else { return }
            store.setRead(true, for: conversa)
        }
    }

    /// **Quantas mensagens esta conversa tem, dito em voz alta.**
    ///
    /// O defeito da tela do dono: as duas mensagens recolhidas do Zoho eram
    /// dois fios no topo do leitor, e ele não percebeu que havia mais. A pilha
    /// existia e não se anunciava. Agora ela abre com a contagem, no rótulo em
    /// versalete que a barra lateral e a janela de compromisso já usam para
    /// dizer de que é a seção que vem abaixo — nenhum desenho novo.
    ///
    /// A frase é a mesma do selo da lista (M3-9), e é de propósito: a pessoa lê
    /// "3 mensagens nesta conversa" no `help` da linha da caixa e encontra a
    /// mesma frase quando abre.
    private var cabecalhoDaPilha: some View {
        Text(Self.contagem(conversa.messages.count))
            .capsLabel(size: 9.5)
            .padding(.horizontal, 28)
            .frame(height: Self.alturaDoCabecalho, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface2.color)
            .hairline(theme.line, edges: .bottom)
    }

    /// "3 mensagens nesta conversa". `nonisolated` e `static` porque o que a
    /// pessoa lê é comportamento — o teste a afirma sem montar leitor.
    nonisolated static func contagem(_ quantas: Int) -> String {
        L10n.tr("\(quantas) mensagens nesta conversa")
    }

    /// A linha clicável de uma mensagem da pilha. Clicar abre a recolhida e
    /// recolhe a aberta — e abrir **é** ler. A mais recente lê a conversa
    /// inteira; uma antiga, só ela. É a mesma regra de `MailStore.select`.
    private func linha(_ message: Message, aberta: Bool) -> some View {
        Button {
            let ids = ConversationStack.toggle(
                message.id, in: ConversationStack.expanded(conversa, opened: opened)
            )
            opened = ConversationStack.Opened(conversationKey: conversa.key, ids: ids)
            if ids.contains(message.id) {
                // Abrir a mais recente é ler a conversa. Uma antiga continua
                // sendo só ela — a mesma regra de `MailStore.select(message:)`.
                if message.id == conversa.latest.id {
                    store.setRead(true, for: conversa)
                } else {
                    store.setRead(true, for: message.id)
                }
            }
        } label: {
            cabecalho(message, aberta: aberta)
        }
        .buttonStyle(.plain)
        .focusRing(in: Rectangle())
        .help(aberta ? L10n.tr("Recolher esta mensagem da conversa") : L10n.tr("Abrir esta mensagem da conversa"))
    }

    /// A linha de cabeçalho de uma mensagem da pilha. Recolhida, ela mostra a
    /// primeira linha do texto ao lado do nome; aberta, o nome e a data bastam
    /// — o texto está logo abaixo.
    private func cabecalho(_ message: Message, aberta: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(message.from.name.isEmpty ? message.from.address : message.from.name)
                .font(theme.sans.font(size: 12.5, weight: message.isRead ? .medium : .semibold))
                .foregroundStyle(theme.ink.color)
                .lineLimit(1)
                .fixedSize()
            if !aberta {
                Text(ReaderPane.primeiraLinha(de: message))
                    .font(theme.sans.font(size: 12))
                    .foregroundStyle(theme.ink3.color)
                    .lineLimit(1)
            }
            Spacer(minLength: 10)
            Text(message.receivedAt, format: .dateTime.day().month(.abbreviated).hour().minute())
                .font(theme.mono.font(size: 10))
                .foregroundStyle(theme.ink4.color)
                .fixedSize()
        }
        .padding(.horizontal, 28)
        .frame(height: Self.alturaDaLinha)
        .frame(maxWidth: .infinity, alignment: .leading)
        // **Recolhida tem fundo; aberta é o papel do leitor.** Era o segundo
        // motivo de a pilha passar despercebida: as linhas recolhidas tinham a
        // mesma cor do corpo e só uma hairline entre elas, e três fios de 38pt
        // sobre o mesmo papel não se leem como três mensagens. O fundo é o da
        // barra lateral e da barra de título — a cor que esta base já usa para
        // "isto é moldura, não conteúdo".
        .background(aberta ? Color.clear : theme.surface2.color)
        .contentShape(Rectangle())
        .hairline(theme.line, edges: .bottom)
    }

    /// A altura da linha de cabeçalho, em pontos. Nomeada porque o ensaio de
    /// clique precisa saber onde a segunda linha começa.
    static var alturaDaLinha: CGFloat { 38 }

    /// A altura do cabeçalho da pilha — a linha da contagem, acima de tudo.
    /// Nomeada pela mesma razão: é o deslocamento de toda linha abaixo dela.
    static var alturaDoCabecalho: CGFloat { 26 }
}
