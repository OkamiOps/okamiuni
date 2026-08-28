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
    public static let laterLabelName = "OkamiUNI/Depois"

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
        case .other: .archived
        }
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

    /// O id do rótulo "Depois", se ele já existir na conta.
    ///
    /// Ausente é o normal numa instalação nova, e não é erro: neste marco a
    /// pasta só é **lida**. Criá-la é do Marco 3, junto com a escrita.
    public static func laterLabelID(in labels: [GmailLabel]) -> String? {
        labels.first { $0.name == laterLabelName }?.id
    }
}
