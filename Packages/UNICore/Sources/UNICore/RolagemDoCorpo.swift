import Foundation

/// "Tem mais coisa abaixo?" — a pergunta que a prévia precisava responder
/// **na tela**, e não só no gesto.
///
/// O corpo do email já rolava; o que faltava era dizer isso. Numa proposta
/// longa, a última linha visível ficava cortada ao meio logo acima da fileira
/// de botões, sem esmaecimento e sem barra: parecia o fim do email. Para quem
/// perde o fio de leitura, texto que some sem avisar é pior do que texto
/// comprido — a pessoa age achando que leu tudo.
///
/// A decisão é aritmética e mora aqui, fora da `View`, pelo contrato de
/// `docs/decisoes-de-engenharia.md`.
public enum RolagemDoCorpo {

    /// Abaixo disto é sobra de arredondamento de layout, não conteúdo. Sem a
    /// margem, meio ponto de diferença acende o aviso num email que cabe
    /// inteiro — e um aviso que aparece à toa deixa de ser lido.
    public static let margem: CGFloat = 4

    public static func temMaisAbaixo(
        conteudo: CGFloat, visivel: CGFloat, deslocamento: CGFloat
    ) -> Bool {
        conteudo - visivel - deslocamento > margem
    }
}
