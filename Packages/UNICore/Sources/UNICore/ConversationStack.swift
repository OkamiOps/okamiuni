import Foundation

/// Quais mensagens da conversa estão abertas na pilha do leitor.
///
/// **Duas regras, e as duas estavam erradas na tela do dono.** A pilha abria a
/// mensagem que o leitor tinha selecionada — que nem sempre é a mais recente
/// (o "Ir para o email de origem" seleciona a **primeira** da conversa, e é
/// assim que "Lembrete rápido" abria com a original de 15 de julho aberta e a
/// resposta de 16 embaixo, recolhida). E clicar numa mensagem só sabia
/// **abrir**: `expandedIDs.insert` não tem volta, então a pilha só crescia.
///
/// Mora em `UNICore`, fora da `View`, pela razão de sempre nesta base: `View`
/// é `@MainActor` implícito no Swift 6, e um `static` lá dentro trapa quando um
/// teste nonisolated o chama. Ver `docs/decisoes-de-engenharia.md`.
public enum ConversationStack {

    /// Quem nasce aberta quando a conversa abre: **a mais recente, e só ela**.
    ///
    /// A mais recente é a que a pessoa veio ler — é o que a linha da lista
    /// descreve, e é o que Gmail, Zoho e Mail abrem. As anteriores ficam
    /// recolhidas, como contexto que se abre quando fizer falta.
    ///
    /// Não depende da seleção do leitor de propósito: a seleção é o caminho
    /// pelo qual a conversa foi aberta (a linha da lista, uma busca, o
    /// compromisso da agenda apontando para a mensagem que o gerou), e nenhum
    /// desses caminhos deveria mudar qual mensagem a conversa mostra primeiro.
    public static func initialExpanded(_ conversation: Conversation) -> Set<String> {
        [conversation.latest.id]
    }

    /// O clique numa mensagem da pilha: abre a recolhida, **recolhe a aberta**.
    ///
    /// Sem trava de "ao menos uma aberta": recolher todas é um estado legítimo
    /// — é a conversa inteira vista de cima, que é exatamente para o que a
    /// pilha serve. Uma trava faria o clique na única aberta não fazer nada, o
    /// mesmo silêncio que este conserto veio tirar.
    public static func toggle(_ messageID: String, in expanded: Set<String>) -> Set<String> {
        var novo = expanded
        if novo.contains(messageID) {
            novo.remove(messageID)
        } else {
            novo.insert(messageID)
        }
        return novo
    }
}
