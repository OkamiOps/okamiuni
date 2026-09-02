import Foundation
import UNICore

/// As decisões do leitor de HTML, escritas como funções puras.
///
/// **Elas moram fora da `WebView` de propósito.** O que decide se uma mensagem
/// pode buscar uma imagem na rede, e o que decide para onde vai um clique num
/// link, são as duas regras que mais custam se estiverem erradas — e as duas
/// que um teste de `View` não alcança. Aqui elas são texto entrando e decisão
/// saindo: a `WebView` só as obedece.
enum ReaderHTMLPolicy {

    /// Expressões imutáveis do leitor. Compilá-las em cada recomposição de uma
    /// newsletter era trabalho de CPU no ator principal sem nenhuma entrada
    /// nova; agora cada uma é compilada uma vez por processo.
    private static let referenciaRemota = try! NSRegularExpression(
        pattern: #"(?i)\b(?:src|srcset|background|poster)\s*=\s*(?:[\"'])?(?:(?:https?:)?//)|url\(\s*(?:[\"'])?(?:(?:https?:)?//)"#
    )
    private static let atributoRemoto = try! NSRegularExpression(
        pattern: #"(?i)\b(src|background|poster)\s*=\s*(?:\"(?:(?:https?:)?//)[^\"]*\"|'(?:(?:https?:)?//)[^']*'|(?:(?:https?:)?//)[^\s>]+)"#
    )
    private static let srcsetRemoto = try! NSRegularExpression(
        pattern: #"(?i)\bsrcset\s*=\s*(?:\"[^\"]*(?:(?:https?:)?//)[^\"]*\"|'[^']*(?:(?:https?:)?//)[^']*'|[^\s>]*(?:(?:https?:)?//)[^\s>]*)"#
    )
    private static let urlRemota = try! NSRegularExpression(
        pattern: #"(?i)url\(\s*(?:[\"'])?(?:(?:https?:)?//)[^\"'\s)]+(?:[\"'])?\s*\)"#
    )
    /// `src="http://…"`, `src='http://…'` e `src=http://…` — não `href`.
    private static let httpEmAtributo = try! NSRegularExpression(
        pattern: #"(?i)(\b(?:src|background|poster)\s*=\s*[\"']?)http://(?!127\.0\.0\.1)(?!localhost)(?!\[::1\])"#
    )
    /// `url(http://…)`, com aspas, `&quot;` ou `&#39;` — o fundo do Google Play.
    private static let httpEmURL = try! NSRegularExpression(
        pattern: #"(?i)(url\(\s*(?:[\"']|&(?:#(?:34|39)|quot|apos);)?)http://(?!127\.0\.0\.1)(?!localhost)(?!\[::1\])"#
    )
    private static let srcsetAtributo = try! NSRegularExpression(
        pattern: #"(?i)\bsrcset\s*=\s*(\"[^\"]*\"|'[^']*')"#
    )

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

    /// Um pixel transparente local no lugar de uma imagem bloqueada. O filtro
    /// de conteúdo continua sendo a barreira de rede; este valor evita que o
    /// WebKit desenhe o ícone quebrado ("?") enquanto a pessoa ainda não
    /// autorizou imagens remotas.
    static let imagemRemotaBloqueada =
        "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="

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
        // `//cdn.exemplo.com/logo.png` herda o protocolo do documento. No
        // leitor, porém, continua sendo rede e também precisa trazer a faixa
        // de privacidade. Procuramos somente atributos que carregam recursos
        // e `url(...)`: um `href` protocol-relative ainda é só um link.
        return aparece(referenciaRemota, em: html)
    }

    /// Neutraliza as fontes remotas no próprio documento antes de ele entrar
    /// na WebView. A content-rule bloqueia a saída, mas deixar o `<img>` com a
    /// URL bloqueada faz o WebKit mostrar o seu ícone de imagem quebrada.
    ///
    /// É intencionalmente limitado a atributos que carregam recurso e a
    /// `url(...)`; links (`href`) nunca são alterados.
    private static func neutralizaRecursosRemotos(_ html: String) -> String {
        let fonte = imagemRemotaBloqueada
        var resultado = substitui(
            atributoRemoto,
            em: html,
            por: "$1=\"\(fonte)\""
        )
        // `srcset` pode carregar uma URL remota sem que o `src` do fallback
        // seja escolhido. Quando há uma URL remota no conjunto, a imagem
        // inteira fica neutra até a pessoa permitir a carga.
        resultado = substitui(
            srcsetRemoto,
            em: resultado,
            por: "srcset=\"\(fonte)\""
        )
        return substitui(
            urlRemota,
            em: resultado,
            por: "url('\(fonte)')"
        )
    }

    /// Fecha o que o gerador (e, em mensagens já gravadas, o varredor) deixou
    /// como `<="" div="">`. Sem isto, o `display:none` do pré-cabeçalho de
    /// marketing engole logo, código e tabela — o email da Hostinger abria em
    /// branco com o Gmail ao lado mostrando o código.
    /// Recurso `http://` vira `https://`. O ATS do macOS recusa HTTP claro, e o
    /// WebKit desenha o "?" quebrado: o alerta do Google Play era
    /// `http://www.gstatic.com/…/alert_outline.png` ao lado do logo em HTTPS.
    ///
    /// Só atributo que **carrega** (`src`, `srcset`, `background`, `poster`,
    /// `url(...)`). `href` continua o destino que o remetente escreveu.
    /// Loopback fica: é o servidor de ensaio das imagens remotas.
    static func promoveHTTPS(_ html: String) -> String {
        var resultado = substitui(httpEmAtributo, em: html, por: "$1https://")
        resultado = substitui(httpEmURL, em: resultado, por: "$1https://")
        return promoveHTTPSNoSrcset(resultado)
    }

    private static func promoveHTTPSNoSrcset(_ html: String) -> String {
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let achados = srcsetAtributo.matches(in: html, range: range)
        guard !achados.isEmpty else { return html }
        var resultado = html
        for achado in achados.reversed() {
            guard let trecho = Range(achado.range, in: resultado) else { continue }
            let promovido = resultado[trecho].replacingOccurrences(
                of: "http://", with: "https://", options: [.caseInsensitive]
            )
            // Loopback no srcset de ensaio: devolve o que tirou.
            let corrigido = promovido
                .replacingOccurrences(of: "https://127.0.0.1", with: "http://127.0.0.1")
                .replacingOccurrences(of: "https://localhost", with: "http://localhost", options: [.caseInsensitive])
            resultado.replaceSubrange(trecho, with: corrigido)
        }
        return resultado
    }

    static func recuperaFechamentosQuebrados(_ html: String) -> String {
        fechamentoQuebrado.stringByReplacingMatches(
            in: html,
            range: NSRange(html.startIndex..<html.endIndex, in: html),
            withTemplate: "</$1>"
        )
    }

    private static let fechamentoQuebrado = try! NSRegularExpression(
        pattern: #"<=""\s+([A-Za-z][A-Za-z0-9]*)="">"#
    )

    private static func aparece(_ expression: NSRegularExpression, em text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.firstMatch(in: text, range: range) != nil
    }

    private static func substitui(
        _ expression: NSRegularExpression,
        em text: String,
        por replacement: String
    ) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }

    // MARK: - Para onde vai um clique

    /// O que fazer com uma navegação que a `WebView` anuncia.
    enum Navegacao: Equatable {
        /// A carga do próprio documento (`about:blank` / `data:`). É a única
        /// coisa que a `WebView` tem permissão de mostrar.
        case permitir
        /// Um link de verdade: sai daqui e vai para o navegador da pessoa.
        case abrirNoNavegador(URL)
        /// Sim / Não / Talvez do HTML do Google Agenda: a WebView não navega
        /// e o RSVP entra pela mesma fila do cartão.
        case rsvp(InviteRSVPResponse)
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
        if let resposta = rsvp(from: url) { return .rsvp(resposta) }
        if esquema == "about" || esquema == "data" { return .permitir }
        // A lista dos esquemas que saem para o mundo mora em
        // `UNICore.LinkDoCorpo` desde que o menu do link passou a precisar dela.
        // Uma fonte só: com duas, o menu ofereceria "Abrir" para um esquema que
        // esta política recusa — ou o contrário, que é pior.
        return LinkDoCorpo.esquemasAbriveis.contains(esquema)
            ? .abrirNoNavegador(url)
            : .recusar
    }

    /// `action=RESPOND&rst=1|2|3` no Calendar do Google. Sem JavaScript no
    /// leitor, o botão Sim/Não/Talvez do HTML só vive se o `href` for este
    /// contrato — e aí a resposta é nossa, não uma aba do navegador.
    static func rsvp(from url: URL) -> InviteRSVPResponse? {
        guard isGoogleCalendarRSVP(url) else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func valor(_ nome: String) -> String? {
            items.first { $0.name.caseInsensitiveCompare(nome) == .orderedSame }?.value
        }
        switch valor("rst") {
        case "1": return .accepted
        case "2": return .declined
        case "3": return .tentative
        default: return nil
        }
    }

    private static func isGoogleCalendarRSVP(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased()
        let noCalendar = host == "calendar.google.com"
            || host.hasSuffix(".calendar.google.com")
            || ((host == "google.com" || host.hasSuffix(".google.com")) && path.contains("/calendar"))
        guard noCalendar else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let action = items.first {
            $0.name.caseInsensitiveCompare("action") == .orderedSame
        }?.value?.uppercased()
        let rst = items.contains { $0.name.caseInsensitiveCompare("rst") == .orderedSame }
        return action == "RESPOND" || rst
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

    // MARK: - Medir o nosso, não o do remetente

    /// O identificador do invólucro que o leitor põe em volta da mensagem.
    ///
    /// Um `id`, e não uma classe: é a especificidade mais alta que existe sem
    /// `!important`, e nenhum seletor que o remetente escreva a alcança.
    static let involucro = "uni-root"

    /// A pergunta que o leitor faz ao documento para saber a altura dele.
    ///
    /// **O defeito que ela conserta: o email que abre num vazio total.** O email
    /// de marketing chega com `height: 100% !important` **na linha do próprio
    /// `<body>`** — praxe do gênero, e o caso do dono tinha isso e mais
    /// `width: 100% !important; min-width: 100%`. A `WebView` do leitor nasce
    /// com um fio de altura (`ReaderHTMLSection` começa com `altura = 1`, porque
    /// a altura é justamente o que ainda vai ser medido), o documento sai do
    /// `MimeSanitize` sem `<!DOCTYPE>` — ele descarta as declarações junto com o
    /// resto —, e em modo de compatibilidade a porcentagem do `body` resolve
    /// contra a área visível. "100% de um fio" é um fio: `documentElement.
    /// scrollHeight` devolvia **1**, a `WebView` ficava com 1 ponto de altura, e
    /// as 44 mil letras do email eram uma linha em branco.
    ///
    /// A M3-18 já tinha desconfiado da medição e a inocentou — mas com um
    /// documento simples, sem `height: 100%`. A pergunta estava certa; era o
    /// documento da sonda que não tinha a armadilha.
    ///
    /// **A saída é medir uma coisa nossa.** O conteúdo da mensagem vai dentro de
    /// um `<div id="uni-root">` que o leitor mesmo põe (ver `documento(...)`), e
    /// é a altura dele que responde. O que o remetente declara sobre `html` e
    /// `body` deixa de importar: o invólucro está **dentro** do `body`, e mede o
    /// que o conteúdo de fato ocupa, colapsado ou não.
    ///
    /// Neutralizar por folha de estilo — `html, body { height: auto !important }`
    /// — foi tentado e **não funciona**: o `!important` de um atributo `style`
    /// ganha do `!important` de qualquer folha de autor, por definição da
    /// cascata. Medido na sonda, e não deduzido.
    ///
    /// E `Math.max` com a medida antiga porque as duas respondem coisas
    /// diferentes: o invólucro não enxerga o que escapa dele (um posicionamento
    /// absoluto pendurado no `body`), e a medida antiga não enxerga o conteúdo
    /// quando o `body` colapsa **e recorta**. Quem manda é a maior — o email não
    /// pode ficar curto por nenhum dos dois motivos.
    ///
    /// São, de propósito, duas defesas para o mesmo caso: o `overflow: visible`
    /// que `documento(...)` devolve ao `body` já faz o conteúdo transbordado
    /// contar na medida antiga. Uma cobre a outra, e a suíte derruba cada uma
    /// separadamente.
    static let medidaDaAltura = """
        (function () {
          var doc = document.documentElement.scrollHeight;
          var raiz = document.getElementById('\(involucro)');
          if (!raiz) { return doc; }
          return Math.max(doc, Math.ceil(raiz.getBoundingClientRect().height));
        })()
        """

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
        for marca in [
            "bgcolor", "background-color", "background:", "background=",
            "color:", "color=", "prefers-color-scheme",
        ] {
            if baixo.contains(marca) { return .papel }
        }
        return .doTema
    }

    /// A paleta efetiva: a escolha da pessoa, ou a que o HTML pede.
    static func paleta(para html: String, forçada: Paleta?) -> Paleta {
        forçada ?? paleta(para: html)
    }

    /// Papel, ou tema claro: o WebView **não** pode herdar o dark do app.
    /// Senão `@media (prefers-color-scheme: dark)` do remetente pinta tinta
    /// clara em cima da tabela branca — o convite do Calendar ilegível.
    static func esquemaClaro(
        html: String, fundo: String, tinta: String, paleta forçada: Paleta? = nil
    ) -> Bool {
        paleta(para: html, forçada: forçada) == .papel || !paginaEscura(fundo: fundo, tinta: tinta)
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
        html: String, fundo: String, tinta: String, link: String, fonte: String,
        larguraDeLeitura: CGFloat = ReaderPane.readingWidth,
        bloqueiaRemotas: Bool = false,
        paleta forçada: Paleta? = nil
    ) -> String {
        let consertado = recuperaFechamentosQuebrados(html)
        let preparado = bloqueiaRemotas ? consertado : promoveHTTPS(consertado)
        let conteudo = bloqueiaRemotas ? neutralizaRecursosRemotos(preparado) : preparado
        let papel = paleta(para: conteudo, forçada: forçada) == .papel
        // Só quando a pessoa pediu "Como o tema" num HTML que já tinha cor:
        // a folha inicial perde para `bgcolor` e para o `@media dark` do
        // Calendar. A folha extra, **depois** do remetente, pinta fundo e
        // tinta do app por cima — senão o Meta não muda e o convite some.
        let restyleTema = forçada == .doTema
        // **A coluna de leitura, e só para quem não trouxe desenho.**
        //
        // O email escrito à mão que chega em HTML é texto corrido, e sem limite
        // ele atravessa o painel inteiro — a linha de 700 pontos que o
        // protótipo recusa com `max-width: 64ch` no parágrafo. O email de
        // marketing é o contrário: ele traz a própria largura, centrada, e
        // espremê-lo numa coluna quebraria o desenho do remetente.
        //
        // A pergunta que separa os dois já existe e já é testada: quem declarou
        // cor declarou desenho (ver `paleta(para:)`). É o mesmo sinal, usado
        // para a mesma coisa — de quem é o desenho desta mensagem.
        let coluna = papel
            ? ""
            : "\n  max-width: \(Int(larguraDeLeitura))px;"
        let corDeFundo = papel ? "#ffffff" : fundo
        let corDaTinta = papel ? "#1a1a1a" : tinta
        let corDoLink = papel ? "#1155cc" : link
        // Papel é sempre `light only`. Sem `only`, o WebKit no app escuro
        // ainda honra `prefers-color-scheme: dark` do remetente e clareia
        // o texto em cima do fundo branco da tabela. O tema **já** pintou
        // fundo e tinta: pedir `light dark` usa CanvasText ≈ #fff.
        let esquema = papel
            ? "light only"
            : (paginaEscura(fundo: fundo, tinta: tinta) ? "dark" : "light")
        let metaEsquema = papel ? "light" : (paginaEscura(fundo: fundo, tinta: tinta) ? "dark" : "light")
        // Depois do HTML do remetente, para ganhar da folha dele que pede dark.
        let travaPapel = papel
            ? "<style>\n:root, html { color-scheme: light only !important; }\n</style>"
            : ""
        let travaTema = restyleTema
            ? folhaDoTema(fundo: corDeFundo, tinta: corDaTinta, link: corDoLink)
            : ""
        return """
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="color-scheme" content="\(metaEsquema)">
            <meta name="supported-color-schemes" content="\(metaEsquema)">
            <style>
            :root { color-scheme: \(esquema); }
            html { background: \(corDeFundo); color: \(corDaTinta); -webkit-text-size-adjust: 100%; }
            body {
              margin: 0; padding: 0; background: transparent; color: \(corDaTinta);
              font-family: \(fonte); font-size: 16px; line-height: 1.68;
              overflow-wrap: break-word;\(coluna)
            }
            /* A imagem de 900px de uma newsletter não pode empurrar o painel
               para o lado: o leitor rola para baixo, e só.

               **Tabela fica de fora de propósito.** Espremer `table` na largura
               do painel — e deixar o motor partir palavra no meio da célula —
               é o que pintou "Status" letra a letra no email do GitHub Actions:
               a coluna fluida passa a ter min-content de um caractere. Quem
               faz caber um layout de 640 é a régua (`escala(painel:conteudo:)`),
               não o espremer da célula. */
            img, video { max-width: 100%; }
            img { height: auto; }
            table { border-collapse: collapse; }
            a { color: \(corDoLink); }
            /* A `WebView` não rola: quem rola é o leitor, e a altura dela
               acompanha o conteúdo. */
            html { overflow: hidden !important; }
            /* **E o `body` não recorta.** O email que declara a própria altura
               (`height: 100% !important` na linha, e o quadro nascendo com um
               fio) deixaria o conteúdo do lado de fora de um `body` de um ponto
               — e com `overflow: hidden` ali, do lado de fora quer dizer
               invisível. Quem esconde o que sobra é o `html`, que é quem define
               a rolagem da área visível; o `body` só precisa não atrapalhar. */
            body { overflow: visible !important; }
            /* O invólucro do leitor: um bloco e nada mais. É ele que a régua
               mede (ver `medidaDaAltura`), e por isso ele não pode virar outra
               coisa por causa de um `div { display: ... }` do remetente — daí o
               `id`, que ganha de qualquer seletor que a mensagem escreva. */
            /* Sem `color` no id: a especificidade do `#uni-root` ganhava das
               classes do remetente e pintava a tinta do tema em cima da
               tabela branca — "Quando" e a lista de convidados ilegíveis. */
            #\(involucro) { display: block; }
            /* Alguns emails (2FA, banco) declaram `user-select: none`. Sem
               isto o código na tela não se seleciona nem com o WebView
               aceitando foco. */
            html, body, #\(involucro), #\(involucro) * {
              -webkit-user-select: text !important;
              user-select: text !important;
            }
            </style>
            <div id="\(involucro)">\(conteudo)</div>
            \(travaPapel)
            \(travaTema)
            """
    }

    /// Folha que ganha do HTML do remetente. Vai depois dele, com `!important`,
    /// porque `bgcolor="#ffffff"` e `.txt { color:#e8eaed !important }` no
    /// `@media (prefers-color-scheme: dark)` ganham da folha inicial.
    static func folhaDoTema(fundo: String, tinta: String, link: String) -> String {
        """
        <style id="uni-tema">
        :root, html { color-scheme: \(paginaEscura(fundo: fundo, tinta: tinta) ? "dark" : "light") only !important; }
        html, body, #\(involucro) {
          background: \(fundo) !important;
          color: \(tinta) !important;
        }
        #\(involucro), #\(involucro) *:not(img):not(svg):not(video):not(canvas) {
          color: \(tinta) !important;
        }
        #\(involucro) a, #\(involucro) a * { color: \(link) !important; }
        #\(involucro) table, #\(involucro) td, #\(involucro) th, #\(involucro) tr,
        #\(involucro) div, #\(involucro) p, #\(involucro) span, #\(involucro) font,
        #\(involucro) center, #\(involucro) section, #\(involucro) article,
        #\(involucro) header, #\(involucro) main, #\(involucro) [bgcolor] {
          background-color: transparent !important;
          background-image: none !important;
        }
        </style>
        """
    }

    /// Fundo mais escuro que a tinta: a página já é dark, e o WebKit não pode
    /// "completar" o esquema invertendo o texto para branco de sistema.
    static func paginaEscura(fundo: String, tinta: String) -> Bool {
        luma(tinta) > luma(fundo)
    }

    private static func luma(_ css: String) -> Double {
        let c = rgb(css)
        return 0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2
    }

    private static func rgb(_ css: String) -> (Double, Double, Double) {
        let s = css.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("#") {
            var hex = String(s.drop(while: { $0 == "#" })).prefix(while: { $0.isHexDigit })
            if hex.count == 3 {
                hex = hex.map { String(repeating: $0, count: 2) }.joined()[...]
            }
            guard hex.count >= 6,
                  let r = Int(hex.prefix(2), radix: 16),
                  let g = Int(hex.dropFirst(2).prefix(2), radix: 16),
                  let b = Int(hex.dropFirst(4).prefix(2), radix: 16)
            else { return (0.5, 0.5, 0.5) }
            return (Double(r) / 255, Double(g) / 255, Double(b) / 255)
        }
        let nums = s.split { !$0.isNumber && $0 != "." }.compactMap { Double($0) }
        guard nums.count >= 3 else { return (0.5, 0.5, 0.5) }
        let scale: Double = (nums[0] > 1 || nums[1] > 1 || nums[2] > 1) ? 255 : 1
        return (nums[0] / scale, nums[1] / scale, nums[2] / scale)
    }
}
