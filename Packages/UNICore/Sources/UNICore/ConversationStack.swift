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

    /// O que o leitor guarda entre um clique e o seguinte: quais mensagens
    /// estão abertas, **e de qual conversa esse estado é**.
    ///
    /// A chave junto não é contabilidade: sem ela, o conjunto de ids da
    /// conversa anterior valeria na seguinte, e uma conversa nova nasceria com
    /// o recorte de outra.
    public struct Opened: Sendable, Hashable {
        public let conversationKey: String
        public let ids: Set<String>

        public init(conversationKey: String, ids: Set<String>) {
            self.conversationKey = conversationKey
            self.ids = ids
        }
    }

    /// Quais mensagens desta conversa estão abertas agora.
    ///
    /// Sem estado guardado — ou com estado de **outra** conversa — vale o
    /// começo: a mais recente aberta, e só ela.
    public static func expanded(_ conversation: Conversation, opened: Opened?) -> Set<String> {
        guard let opened, opened.conversationKey == conversation.key else {
            return initialExpanded(conversation)
        }
        return opened.ids
    }

    /// O estado que **atravessa** uma troca de conversa: nenhum.
    ///
    /// Era esta a outra metade da tela do dono. A M3-10 passou a permitir
    /// recolher a última aberta (e com razão: clicar na única aberta tinha de
    /// fazer alguma coisa), mas o estado "tudo recolhido" ficava guardado com a
    /// chave da conversa. Ir para outra conversa só o **escondia** —
    /// `expanded` já ignora estado de chave alheia —, e voltar o encontrava
    /// inteiro: a conversa reabria com as três linhas recolhidas e nenhum corpo
    /// à vista, que foi exatamente o print.
    ///
    /// Voltar a uma conversa é abri-la, e abrir é a mais recente aberta. Dentro
    /// da mesma conversa nada se perde: quem abriu uma mensagem antiga da pilha
    /// e clicou noutra linha da mesma conversa continua lendo o que estava
    /// lendo.
    public static func carried(_ opened: Opened?, to conversation: Conversation) -> Opened? {
        guard let opened, opened.conversationKey == conversation.key else { return nil }
        return opened
    }
}
