import Foundation
import UNICore

/// Onde uma mensagem do servidor cai na triagem do Marco 1.
///
/// **É projeção, não espelho.** O servidor tem pastas e rótulos; o app tem
/// quatro caixas de triagem mais a lixeira. A tradução acontece **na entrada**,
/// uma vez, e é gravada em `message.bucket` — a UI nunca reprojeta nada, e é
/// por isso que a lista abre instantânea.
///
/// Escrever de volta no servidor é do Marco 3. Aqui a estrada é de mão única.
public enum TriageProjection {
    /// O nome que a pasta/rótulo de "Depois" tem no servidor.
    // A MESMA constante da pasta IMAP — uma fonte só, para o nome nunca
    // divergir entre o rótulo do Gmail e a pasta `OkamiUNI/Depois`.
    public static let laterLabelName = FolderRoles.laterFolderName

    public static func bucket(role: FolderRole) -> TriageBucket? {
        switch role {
        case .inbox: .today
        case .later: .later
        case .archive: .archived
        case .trash: .trash
        // Enviadas ficam **fora** da triagem. A caixa não existe no shell do
        // Marco 1, e enfiá-las em Arquivado encheria a caixa do que a pessoa
        // escreveu, não do que ela recebeu.
        case .sent: nil
        // Pasta que a pessoa criou não tem papel nosso, e "arquivada" é a
        // resposta certa: a mensagem existe, não está na entrada, não está na
        // lixeira. Some da triagem só o que ela mandou sumir.
        //
        // Esta linha já foi código morto: o filtro do `InitialLoader` excluía
        // `.other` antes de chegar aqui, e só o teste-tabela a cobria. Desde que
        // o IMAP passou a carregar as pastas do usuário (como o Gmail sempre
        // fez), ela tem caminho de produção — e o nome da pasta vem junto, como
        // etiqueta, por `tag(folderRole:folderName:)`.
        case .other: .archived
        }
    }

    /// A etiqueta que uma pasta empresta às mensagens dela — ou `nil`.
    ///
    /// **Uma regra, um lugar.** A pergunta "o que a pessoa organizou por conta
    /// própria entra na triagem, e como?" já teve duas respostas opostas neste
    /// pacote: o Gmail incluía todo rótulo do usuário (caindo em Arquivado pelo
    /// `return .archived` do fim) e o IMAP **excluía** explicitamente toda pasta
    /// sem papel nosso. A mesma pessoa, com uma pasta "Faturas" nas duas contas,
    /// via as faturas do Gmail em Arquivado e nenhuma das do IMAP.
    ///
    /// A resposta escolhida é a do Gmail: pasta do usuário entra, em Arquivado
    /// (`bucket(role: .other)`), e o nome dela vira etiqueta — sem isso, entrar
    /// em Arquivado perderia a única informação que a pasta carregava.
    ///
    /// As nossas cinco não viram etiqueta: o nome delas é estrutura, e já está
    /// dito pelo `bucket`. "Arquivo" etiquetado como "Arquivo" é ruído.
    /// Sem `tintHex`: a etiqueta herda o `ink3` do tema. A cor por conta já é a
    /// da conta, e inventar uma segunda cor aqui seria decisão de design que
    /// ninguém tomou.
    public static func tag(folderRole: FolderRole, folderName: String) -> Tag? {
        guard folderRole == .other else { return nil }
        let limpo = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return limpo.isEmpty ? nil : Tag(name: limpo)
    }

    /// A mesma projeção, pelos rótulos do Gmail.
    ///
    /// A ordem de precedência é o que importa aqui, e cada degrau custou um
    /// defeito para alguém em algum cliente:
    /// 1. `SENT` sai de tudo — o que a pessoa escreveu não é triagem dela.
    /// 2. `TRASH` ganha de tudo o que sobra — uma mensagem apagada continua
    ///    carregando `INBOX` por um tempo, e se `INBOX` vencesse ela voltaria
    ///    para Hoje. Apagar tem de parecer apagar.
    /// 3. `OkamiUNI/Depois` ganha de `INBOX` — é decisão explícita da pessoa,
    ///    tomada nesta ferramenta; `INBOX` é só "ainda não triada".
    /// 4. `INBOX` → Hoje.
    /// 5. O resto → Arquivado.
    public static func bucket(gmailLabelIDs: [String], laterLabelID: String?) -> TriageBucket? {
        let rotulos = Set(gmailLabelIDs)
        if rotulos.contains("SENT") { return nil }
        if rotulos.contains("TRASH") { return .trash }
        if let laterLabelID, rotulos.contains(laterLabelID) { return .later }
        if rotulos.contains("INBOX") { return .today }
        return .archived
    }

    // MARK: As bandeiras

    /// Se a mensagem já foi lida, pelos rótulos do Gmail.
    ///
    /// **A ausência de `UNREAD` é que significa lida** — o Gmail não tem um
    /// rótulo `READ`. Invertida, a regra faria toda a caixa nascer não lida e
    /// o contador de Hoje abrir mentindo em cima do número que a pessoa vê no
    /// navegador.
    ///
    /// Aqui, e não no `GmailMessageParser`: o parser devolve os rótulos como
    /// eles vieram, e é a **entrada** que projeta — a mesma estrada de mão
    /// única do `bucket`. E aqui, e não no `InitialLoader`: uma regra escrita
    /// dentro do laço da carga não tem como ser testada sem banco nem rede, e
    /// a carga do Marco 3 a copiaria em vez de a herdar.
    public static func isRead(gmailLabelIDs: [String]) -> Bool {
        !gmailLabelIDs.contains("UNREAD")
    }

    /// Se a mensagem está sinalizada, pelos rótulos do Gmail.
    ///
    /// `STARRED` é a estrela do Gmail, e ela é a mesma coisa que a bandeira
    /// desta ferramenta: sinalizar é estado da mensagem, e a linha da lista o
    /// mostra. Deixá-la de fora faria a estrela que a pessoa pôs no navegador
    /// sumir ao abrir o app — perda silenciosa de uma decisão dela.
    public static func isFlagged(gmailLabelIDs: [String]) -> Bool {
        gmailLabelIDs.contains("STARRED")
    }

    /// As mesmas duas bandeiras, pelas flags do IMAP.
    ///
    /// **Mesmo tipo, e não uma segunda regra.** O IMAP diz o contrário do
    /// Gmail — ele tem `\Seen` para lida, onde o Gmail tem `UNREAD` para não
    /// lida — e é exatamente por isso que as duas traduções moram lado a lado:
    /// escritas em arquivos diferentes, uma seria invertida em relação à outra
    /// sem que ninguém percebesse, e a caixa IMAP abriria toda lida enquanto a
    /// do Gmail abria toda não lida.
    ///
    /// A comparação é em caixa baixa porque `\SEEN`, `\Seen` e `\seen` são a
    /// mesma flag no RFC 3501, e servidor que manda em maiúsculas existe.
    public static func isRead(imapFlags: [String]) -> Bool {
        dobra(imapFlags).contains("\\seen")
    }

    /// `\Flagged` é a bandeira do IMAP — a mesma coisa que a estrela do Gmail
    /// e que a bandeira desta ferramenta.
    public static func isFlagged(imapFlags: [String]) -> Bool {
        dobra(imapFlags).contains("\\flagged")
    }

    private static func dobra(_ flags: [String]) -> Set<String> {
        Set(flags.map { $0.lowercased() })
    }

    /// O id do rótulo "Depois", se ele já existir na conta.
    ///
    /// Ausente é o normal numa instalação nova, e não é erro: neste marco a
    /// pasta só é **lida**. Criá-la é do Marco 3, junto com a escrita.
    public static func laterLabelID(in labels: [GmailLabel]) -> String? {
        labels.first { $0.name == laterLabelName }?.id
    }
}
