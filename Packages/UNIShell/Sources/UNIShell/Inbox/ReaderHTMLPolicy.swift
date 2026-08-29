import Foundation

/// As decisões do leitor de HTML, escritas como funções puras.
///
/// **Elas moram fora da `WebView` de propósito.** O que decide se uma mensagem
/// pode buscar uma imagem na rede, e o que decide para onde vai um clique num
/// link, são as duas regras que mais custam se estiverem erradas — e as duas
/// que um teste de `View` não alcança. Aqui elas são texto entrando e decisão
/// saindo: a `WebView` só as obedece.
enum ReaderHTMLPolicy {

    // MARK: - Nada de rede, por padrão

    /// A lista de regras que a `WebView` compila antes de desenhar qualquer
    /// coisa: **tudo o que for `http` ou `https` é barrado**.
    ///
    /// Não é excesso de zelo. A imagem remota de um email é o pixel de
    /// rastreio: quem a carrega diz ao remetente que a mensagem foi aberta,
    /// quando, de qual endereço IP e com qual cliente — e basta abrir a
    /// mensagem, não é preciso clicar em nada. Bloqueado é o padrão certo;
    /// carregar é uma escolha da pessoa, por mensagem, e ela não fica guardada
    /// em lugar nenhum.
    ///
    /// O filtro é o esquema, e não uma lista de tipos de recurso: bloquear
    /// "imagem, folha de estilo, fonte" deixaria de fora o tipo que o WebKit
    /// inventar amanhã. O que a mensagem já tem embutido (`data:`) não passa
    /// por aqui e continua desenhando.
    static let regraDeBloqueio = """
        [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]
        """

    /// O identificador da lista compilada, guardado no armazém do WebKit.
    ///
    /// Versionado no nome: compilar sobre um identificador que já existe com
    /// **outro** conteúdo é o caminho para uma máquina continuar rodando a
    /// regra da versão passada depois de uma atualização.
    static let identificadorDaRegra = "okamiuni-bloqueio-remoto-v1"

    /// A mensagem pede alguma coisa de fora?
    ///
    /// É o que decide se a faixa "Imagens remotas bloqueadas · Carregar"
    /// aparece. Mostrá-la em toda mensagem seria ruído — a maioria não pede
    /// nada —, e escondê-la numa que pede deixaria a pessoa sem saber por que o
    /// email está esburacado.
    ///
    /// O `href` de um link **não** conta: ele não é carregado ao abrir, é
    /// seguido ao clicar, e contá-lo poria a faixa em cima de toda mensagem com
    /// um link dentro.
    static func pedeRecursoRemoto(_ html: String) -> Bool {
        let baixo = html.lowercased()
        var procura = baixo.startIndex
        while let achado = baixo.range(of: "http", range: procura..<baixo.endIndex) {
            procura = achado.upperBound
            let resto = baixo[achado.lowerBound...]
            guard resto.hasPrefix("http://") || resto.hasPrefix("https://") else { continue }
            // Doze caracteres para trás bastam para `href=` com aspas e espaço,
            // e não alcançam o atributo anterior.
            let inicio = baixo.index(
                achado.lowerBound, offsetBy: -12, limitedBy: baixo.startIndex
            ) ?? baixo.startIndex
            let antes = baixo[inicio..<achado.lowerBound]
            if antes.contains("href=") { continue }
            return true
        }
        return false
    }

    // MARK: - Para onde vai um clique

    /// O que fazer com uma navegação que a `WebView` anuncia.
    enum Navegacao: Equatable {
        /// A carga do próprio documento (`about:blank` / `data:`). É a única
        /// coisa que a `WebView` tem permissão de mostrar.
        case permitir
        /// Um link de verdade: sai daqui e vai para o navegador da pessoa.
        case abrirNoNavegador(URL)
        /// Qualquer outra coisa — `file:`, um esquema de aplicativo, um clique
        /// sem destino. Não navega e não abre nada.
        case recusar
    }

    /// **A `WebView` nunca navega.** Ela desenha uma mensagem e só; qualquer
    /// destino de verdade vai para o navegador padrão.
    ///
    /// É o que impede um link de trocar o conteúdo do painel por uma página de
    /// terceiro — que passaria a rodar com as permissões da nossa `WebView`, e
    /// dentro do leitor de email da pessoa, com a cara do leitor de email da
    /// pessoa. Um phishing não precisa de mais do que isso.
    static func decide(url: URL?) -> Navegacao {
        guard let url, let esquema = url.scheme?.lowercased() else { return .recusar }
        switch esquema {
        case "about", "data":
            return .permitir
        case "http", "https", "mailto", "tel":
            return .abrirNoNavegador(url)
        default:
            return .recusar
        }
    }

    // MARK: - Caber sem cortar

    /// O menor fator de escala que este leitor aplica. Abaixo dele o texto do
    /// email deixa de ser legível, e um email ilegível não é melhor do que um
    /// email cortado — mas nenhum email real chega perto: uma newsletter mede
    /// 600 ou 640 pontos, e o painel do leitor não fica abaixo de uns 380.
    static let escalaMinima: CGFloat = 0.4

    /// De quanto o documento tem de encolher para caber no painel.
    ///
    /// **O defeito que ela conserta.** O email de marketing traz o próprio
    /// layout — uma tabela de 600 ou 640 pontos de largura fixa — e a `WebView`
    /// desenha na largura que o painel tem. Quando o painel é mais estreito, a
    /// diferença não vira barra de rolagem (a folha declara `overflow: hidden`,
    /// porque quem rola é o leitor): vira **corte**. Foi o que o dono viu lado a
    /// lado com o Gmail — "Olá, Marcos" virando "Olá", e a borda direita da
    /// mensagem decepada.
    ///
    /// Encolher, e não espremer. O email tem uma largura que é dele — o
    /// remetente a desenhou —, e o que muda aqui é a régua, não o desenho.
    ///
    /// Nunca **aumenta**: um email estreito num painel largo fica do tamanho que
    /// o remetente pediu, centrado pelo próprio HTML, como no webmail.
    static func escala(painel: CGFloat, conteudo: CGFloat) -> CGFloat {
        guard painel > 0, conteudo > painel else { return 1 }
        return max(escalaMinima, painel / conteudo)
    }

    /// A altura da `WebView`, em pontos, a partir do que o documento mediu.
    ///
    /// A medida do documento vem em pixels de CSS, e com escala aplicada um
    /// pixel de CSS deixa de valer um ponto — usar o número cru deixaria uma
    /// tira de vazio embaixo de toda newsletter encolhida, do tamanho exato do
    /// que foi encolhido.
    static func altura(documento: CGFloat, escala: CGFloat) -> CGFloat {
        max(1, (documento * escala).rounded(.up))
    }

    // MARK: - O documento

    /// De que cores o documento é desenhado.
    enum Paleta: Equatable {
        /// Os tokens do tema — a mensagem não disse nada sobre cor, e ela fica
        /// com a cara do app.
        case doTema
        /// Papel branco com tinta escura, **mesmo no tema escuro**.
        case papel
    }

    /// A mensagem escolheu as cores dela?
    ///
    /// Quando escolheu, ela é desenhada em papel branco mesmo no tema escuro.
    /// Parece contra-intuitivo e é o contrário: um email do provedor com fundo
    /// declarado e texto escuro, posto sobre o fundo escuro do app, vira texto
    /// invisível em metade dos blocos e ilegível na outra — o remetente pintou
    /// metade da tela e nós pintaríamos a outra. Quem não declarou cor nenhuma
    /// (a mensagem simples, escrita à mão) segue o tema e fica bonita nos dois.
    ///
    /// É a mesma escolha que o Mail.app faz, e pela mesma razão.
    static func paleta(para html: String) -> Paleta {
        let baixo = html.lowercased()
        for marca in ["bgcolor", "background-color", "background:", "color:"] {
            if baixo.contains(marca) { return .papel }
        }
        return .doTema
    }

    /// O documento que a `WebView` carrega: o HTML da mensagem embrulhado no
    /// mínimo de folha de estilo que o faz caber e ser legível.
    ///
    /// - Parameters:
    ///   - fundo, tinta, link: as cores, em CSS, já resolvidas pelo tema.
    ///   - fonte: a família da tipografia do leitor.
    ///
    /// A folha vai **antes** da do remetente e com seletores de elemento, que é
    /// a especificidade mais baixa que existe: tudo o que a mensagem declarar
    /// ganha do que está aqui. Isto é piso, não opinião.
    static func documento(
        html: String, fundo: String, tinta: String, link: String, fonte: String
    ) -> String {
        let papel = paleta(para: html) == .papel
        let corDeFundo = papel ? "#ffffff" : fundo
        let corDaTinta = papel ? "#1a1a1a" : tinta
        let corDoLink = papel ? "#1155cc" : link
        // `light dark` no tema, `light` no papel: declarar `dark` numa página
        // que vai ser branca faria o WebKit recolorir os controles e as bordas
        // de sistema dela para escuro sobre branco.
        let esquema = papel ? "light" : "light dark"
        return """
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
            :root { color-scheme: \(esquema); }
            html { background: \(corDeFundo); color: \(corDaTinta); -webkit-text-size-adjust: 100%; }
            body {
              margin: 0; padding: 0; background: transparent; color: \(corDaTinta);
              font-family: \(fonte); font-size: 16px; line-height: 1.68;
              overflow-wrap: break-word; word-break: break-word;
            }
            /* A imagem de 900px de uma newsletter não pode empurrar o painel
               para o lado: o leitor rola para baixo, e só.

               O `table` continua aqui, e medido: ele **não** espreme a tabela de
               largura declarada de um email de marketing — ela sai daqui com os
               640 pontos que o remetente pediu, e é a `WebView` inteira que
               encolhe para caber (ver `escala(painel:conteudo:)`). */
            img, video, table { max-width: 100%; }
            img { height: auto; }
            table { border-collapse: collapse; }
            a { color: \(corDoLink); }
            /* A `WebView` não rola: quem rola é o leitor, e a altura dela
               acompanha o conteúdo. */
            html, body { overflow: hidden !important; }
            </style>
            \(html)
            """
    }
}
