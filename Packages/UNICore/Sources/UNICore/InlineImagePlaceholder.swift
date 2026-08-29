import Foundation

/// O que fica no lugar de uma imagem embutida que não virou `data:`.
///
/// **Duas ausências diferentes, e por isso duas marcas.** Uma imagem pode faltar
/// porque não coube (estourou o teto de tamanho do sanitizador) ou porque ainda
/// não foi buscada — o caso do Gmail, que entrega a imagem embutida como
/// `attachmentId` e cobra uma segunda chamada por ela. As duas desenham o mesmo
/// vazio, mas só a segunda tem conserto, e quem lê o HTML gravado precisa
/// conseguir distinguir uma da outra: sem isso, ou o app rebusca para sempre a
/// imagem que nunca vai caber, ou nunca rebusca a que só faltava pedir.
///
/// A marca é um **fragmento** na própria `data:` URI. O motor de desenho ignora
/// o `#…` de uma `data:` (é sintaxe de URL, não da imagem), então a mensagem
/// desenha igual; e quem quiser saber se falta buscar alguma coisa lê o texto do
/// HTML, sem precisar de mais uma coluna no banco.
///
/// Mora em UNICore, e não em `UNISync.MimeSanitize`, porque quem faz a pergunta
/// é o `MessageStore`: é ele que decide se vale rebuscar o corpo de uma
/// mensagem que já tem HTML.
public enum InlineImagePlaceholder {

    /// Um GIF transparente de 1×1: o lugar da imagem continua no layout, o peso
    /// não. É o placeholder de sempre, e o valor não mudou.
    public static let vazio =
        "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"

    /// O mesmo vazio, marcado: **esta imagem existe e ainda não foi buscada**.
    public static let pendente = vazio + "#uni-inline-pendente"

    /// Este HTML tem imagem embutida esperando ser buscada?
    ///
    /// É a pergunta que faz o leitor pedir o corpo de novo para uma mensagem que
    /// já tem HTML — e que **não** a faz pedir por uma imagem que só era grande
    /// demais.
    public static func temPendente(_ html: String?) -> Bool {
        guard let html else { return false }
        return html.contains(pendente)
    }
}
