import Foundation

/// O link do corpo do email: **para onde ele vai**, escrito de um jeito que
/// não dá para confundir, e o que o app oferece sobre ele.
///
/// ## Por que existe
///
/// O dono viu duas coisas erradas no mesmo gesto. O botão direito sobre um link
/// do corpo abria o menu do `NSTextView` — "Abrir Link / Buscar com Google /
/// Serviços / Fala" —, cinza do sistema em cima de uma interface com 26 temas.
/// E o clique esquerdo abria o navegador **na hora**, sem dizer para onde.
///
/// As duas correções precisam da mesma resposta: *qual é o destino de verdade?*
/// Ela não é o texto da âncora (o email escolhe esse texto) nem a URL inteira
/// lida de ponta a ponta (ninguém lê). É o **anfitrião**, isolado do resto — e
/// é isso que este arquivo calcula.
///
/// ## Por que em `UNICore`
///
/// É aritmética sobre uma URL: não abre janela, não toca em AppKit e é onde o
/// caso que motivou a tarefa pode ser provado por escrito —
/// `https://banco.com@malicioso.example` tem anfitrião `malicioso.example`, e
/// quem lê "banco.com" na frente já foi enganado. `View` é `@MainActor`
/// implícito no Swift 6, e um `static` lá dentro trapa em teste nonisolated
/// (`docs/decisoes-de-engenharia.md`).
///
/// ## O que ele **não** faz
///
/// Não decide o que pode abrir — isso continua sendo `ReaderHTMLPolicy.decide`,
/// no leitor. `esquemasAbriveis` é a lista que aquela política consulta: uma
/// fonte só, para as duas não divergirem no primeiro conserto. Afrouxar aqui
/// afrouxaria lá, e o teste de ambos os lados tranca isso.
public enum LinkDoCorpo {

    /// Os esquemas que saem para fora do app. **É a lista de
    /// `ReaderHTMLPolicy.decide`**, que a importa daqui.
    ///
    /// `about:` e `data:` ficam de fora de propósito: eles são a carga do
    /// próprio documento do leitor, não um destino em que se clica.
    public static let esquemasAbriveis: Set<String> = ["http", "https", "mailto", "tel"]

    /// Este endereço pode sair para o mundo?
    public static func abrivel(_ url: URL?) -> Bool {
        guard let esquema = url?.scheme?.lowercased() else { return false }
        return esquemasAbriveis.contains(esquema)
    }

    // MARK: - O destino, fatiado para leitura

    /// O endereço partido em três, para o anfitrião poder ser desenhado em
    /// destaque no meio do resto.
    ///
    /// Ler a URL inteira num corpo só é o mesmo que não a mostrar: o olho para
    /// no começo, e o começo é justamente a parte que o disfarce controla.
    public struct Destino: Sendable, Hashable {
        /// Tudo que vem antes do anfitrião — esquema e, quando existe, o
        /// usuário embutido: `"https://banco.com@"`.
        public let prefixo: String
        /// O anfitrião de verdade. Vazio em `tel:`, que não tem um.
        public let anfitriao: String
        /// Porta, caminho, consulta e fragmento.
        public let resto: String
        /// Algum rótulo do anfitrião é IDN (`xn--`).
        public let punycode: Bool
        /// Tem usuário antes do `@` — a forma clássica de fazer um domínio
        /// conhecido aparecer onde o site fica.
        public let usuarioEmbutido: Bool

        public init(
            prefixo: String,
            anfitriao: String,
            resto: String,
            punycode: Bool,
            usuarioEmbutido: Bool
        ) {
            self.prefixo = prefixo
            self.anfitriao = anfitriao
            self.resto = resto
            self.punycode = punycode
            self.usuarioEmbutido = usuarioEmbutido
        }

        /// O endereço por extenso, do jeito que ele é.
        public var porExtenso: String { prefixo + anfitriao + resto }

        /// O destino tem algo que **engana quem lê**. Não quer dizer que seja
        /// malicioso; quer dizer que a leitura ingênua erra, e por isso o
        /// cartão avisa.
        public var disfarcado: Bool { punycode || usuarioEmbutido }

        /// A frase do aviso, quando há um. Uma por motivo, na ordem em que
        /// enganam.
        public var aviso: String? {
            if usuarioEmbutido {
                return "O que está antes do @ é usuário, não é o site."
            }
            if punycode {
                return "Domínio IDN (punycode): letras de outro alfabeto podem imitar o nome."
            }
            return nil
        }
    }

    /// Fatia o endereço. `nil` para o que o leitor não abre — o mesmo corte de
    /// `ReaderHTMLPolicy.decide`, para que o recusado não gere menu nem
    /// confirmação.
    public static func destino(de url: URL) -> Destino? {
        guard abrivel(url), let esquema = url.scheme?.lowercased() else { return nil }
        if esquema == "mailto" { return destinoDeCorreio(url) }
        if esquema == "tel" {
            return Destino(
                prefixo: "tel:",
                anfitriao: "",
                resto: url.absoluteString.dropFirst("tel:".count).description,
                punycode: false,
                usuarioEmbutido: false
            )
        }
        let partes = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let anfitriao = ascii(anfitriao: partes?.percentEncodedHost ?? "")
        var prefixo = "\(esquema)://"
        var usuario = false
        if let user = partes?.percentEncodedUser, !user.isEmpty {
            usuario = true
            prefixo += user
            if let senha = partes?.percentEncodedPassword, !senha.isEmpty {
                // A senha vira asteriscos: mostrar a de um link de email é
                // pôr credencial de terceiro na tela sem motivo nenhum.
                prefixo += ":" + String(repeating: "•", count: min(senha.count, 8))
            }
            prefixo += "@"
        }
        var resto = ""
        if let porta = partes?.port { resto += ":\(porta)" }
        resto += partes?.percentEncodedPath ?? url.path
        if let consulta = partes?.percentEncodedQuery { resto += "?" + consulta }
        if let fragmento = partes?.percentEncodedFragment { resto += "#" + fragmento }
        return Destino(
            prefixo: prefixo,
            anfitriao: anfitriao,
            resto: resto,
            punycode: temPunycode(anfitriao),
            usuarioEmbutido: usuario
        )
    }

    private static func destinoDeCorreio(_ url: URL) -> Destino {
        let corpo = url.absoluteString.dropFirst("mailto:".count)
        let endereco = corpo.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        let consulta = corpo.dropFirst(endereco.count)
        guard let arroba = endereco.lastIndex(of: "@") else {
            return Destino(
                prefixo: "mailto:", anfitriao: endereco, resto: String(consulta),
                punycode: temPunycode(endereco), usuarioEmbutido: false
            )
        }
        let dominio = ascii(anfitriao: String(endereco[endereco.index(after: arroba)...]))
        return Destino(
            prefixo: "mailto:" + endereco[..<endereco.index(after: arroba)],
            anfitriao: dominio,
            resto: String(consulta),
            punycode: temPunycode(dominio),
            // O `@` de um mailto separa caixa de domínio: é o endereço, não
            // disfarce nenhum.
            usuarioEmbutido: false
        )
    }

    private static func temPunycode(_ anfitriao: String) -> Bool {
        anfitriao.split(separator: ".").contains { $0.lowercased().hasPrefix("xn--") }
            || anfitriao.contains("%")
    }

    // MARK: - IDN: de volta para o ASCII

    /// O anfitrião **em ASCII**, com cada rótulo fora do alfabeto latino
    /// reescrito em punycode.
    ///
    /// ## Por que é preciso reescrever
    ///
    /// O `Foundation` faz o contrário do que esta tela precisa: ele
    /// **decodifica** IDN. `URL(string: "https://xn--80ak6aa92e.com")` volta com
    /// o anfitrião em cirílico — medido, e é o que fez o primeiro teste desta
    /// tarefa falhar. Desenhar isso é entregar ao email o poder de escrever
    /// "аррӏе.com" onde a pessoa lê "apple.com": as letras são outras, o
    /// desenho é o mesmo, e o clique vai para outro lugar.
    ///
    /// A forma que não mente é a ASCII — a mesma que a barra de endereços de um
    /// navegador mostra quando desconfia da mistura de alfabetos. `xn--` é feio
    /// e é o ponto: feio é visível.
    ///
    /// Só a **codificação** (RFC 3492) mora aqui, e é ela que este app precisa;
    /// decodificar seria construir a arma.
    static func ascii(anfitriao: String) -> String {
        let cru = (anfitriao.removingPercentEncoding ?? anfitriao).lowercased()
        guard cru.contains(where: { !$0.isASCII }) else { return cru }
        return cru.split(separator: ".", omittingEmptySubsequences: false)
            .map { rotulo -> String in
                guard rotulo.contains(where: { !$0.isASCII }) else { return String(rotulo) }
                return "xn--" + punycode(String(rotulo))
            }
            .joined(separator: ".")
    }

    /// RFC 3492, seção 6.3 — o laço de codificação, escrito como o documento o
    /// escreve para poder ser conferido linha a linha contra ele.
    private static func punycode(_ entrada: String) -> String {
        let base = 36, tmin = 1, tmax = 26, skew = 38, damp = 700, viesInicial = 72
        let escalares = Array(entrada.unicodeScalars)
        var saida = escalares.filter { $0.isASCII }.map { Character($0) }
        let basicos = saida.count
        if basicos > 0 { saida.append("-") }

        var n = 128, delta = 0, vies = viesInicial, tratados = basicos
        while tratados < escalares.count {
            let proximo = escalares.map { Int($0.value) }.filter { $0 >= n }.min() ?? n
            delta += (proximo - n) * (tratados + 1)
            n = proximo
            for escalar in escalares {
                let valor = Int(escalar.value)
                if valor < n { delta += 1 }
                guard valor == n else { continue }
                var quociente = delta
                var k = base
                while true {
                    let t = k <= vies ? tmin : (k >= vies + tmax ? tmax : k - vies)
                    if quociente < t { break }
                    saida.append(digito(t + (quociente - t) % (base - t)))
                    quociente = (quociente - t) / (base - t)
                    k += base
                }
                saida.append(digito(quociente))
                vies = adapta(
                    delta, pontos: tratados + 1, primeira: tratados == basicos,
                    base: base, tmin: tmin, tmax: tmax, skew: skew, damp: damp
                )
                delta = 0
                tratados += 1
            }
            delta += 1
            n += 1
        }
        return String(saida)
    }

    private static func adapta(
        _ delta: Int, pontos: Int, primeira: Bool,
        base: Int, tmin: Int, tmax: Int, skew: Int, damp: Int
    ) -> Int {
        var delta = primeira ? delta / damp : delta / 2
        delta += delta / pontos
        var k = 0
        while delta > ((base - tmin) * tmax) / 2 {
            delta /= (base - tmin)
            k += base
        }
        return k + (((base - tmin + 1) * delta) / (delta + skew))
    }

    private static func digito(_ valor: Int) -> Character {
        valor < 26
            ? Character(UnicodeScalar(UInt8(97 + valor)))
            : Character(UnicodeScalar(UInt8(48 + valor - 26)))
    }

    /// O anfitrião encurtado para caber numa linha de menu, **perdendo o
    /// meio**.
    ///
    /// Cortar pela cauda seria o pior corte possível: `conta.banco.com.br…` é
    /// exatamente o que um domínio disfarçado quer que se leia. Quem manda no
    /// destino são os últimos rótulos, e são eles que sobrevivem.
    public static func anfitriaoCurto(_ anfitriao: String, limite: Int) -> String {
        guard anfitriao.count > limite, limite > 1 else { return anfitriao }
        return "…" + String(anfitriao.suffix(limite - 1))
    }

    // MARK: - O menu

    /// Quantas letras de anfitrião cabem numa linha do painel de menu antes de
    /// ele passar da largura máxima.
    public static let limiteDoAnfitriaoNoMenu = 34

    /// O verbo certo para o esquema. "Abrir no navegador" num `mailto:` seria
    /// promessa falsa — e a promessa falsa é o defeito que esta tarefa veio
    /// consertar.
    public static func rotuloDeAbertura(_ url: URL) -> String {
        switch url.scheme?.lowercased() {
        case "mailto": "Escrever para este endereço…"
        case "tel": "Ligar para este número…"
        default: "Abrir no navegador…"
        }
    }

    /// O menu de contexto de um trecho do corpo que tem link.
    ///
    /// ## O que entra, e por quê
    ///
    /// - **A legenda com o anfitrião**, primeiro. É o que transforma o menu em
    ///   defesa: o destino aparece antes de qualquer ação, e não escondido num
    ///   balão que só nasce se a pessoa parar o ponteiro em cima.
    /// - **Abrir** (com reticências: ele ainda vai perguntar).
    /// - **Copiar link** — a saída de quem quer conferir noutro lugar.
    /// - **Copiar o texto do trecho** — o único item que não é do link, e o
    ///   que substitui o "Copiar" do menu do sistema que saiu junto.
    ///
    /// Ficaram de fora, e são do sistema, não do produto: "Buscar com Google"
    /// (manda o texto da pessoa para um buscador), "Serviços", "Fala",
    /// "Ferramentas de Escrita", "Ortografia e Gramática", "Fonte",
    /// "Compartilhar", "Abrir com".
    ///
    /// - Parameters:
    ///   - links: os destinos do trecho clicado, na ordem em que aparecem.
    ///   - textoDoBloco: o texto lido do trecho, para o item de copiar.
    public static func menu(links: [URL], textoDoBloco: String) -> [ContextMenuEntry] {
        var vistos: Set<URL> = []
        let abriveis = links.filter { abrivel($0) && vistos.insert($0).inserted }
        guard !abriveis.isEmpty else { return [] }

        var entradas: [ContextMenuEntry] = []
        if abriveis.count == 1, let url = abriveis.first, let destino = destino(de: url) {
            let anfitriao = destino.anfitriao.isEmpty
                ? destino.porExtenso
                : destino.anfitriao
            entradas.append(.legenda(
                "Vai para " + anfitriaoCurto(anfitriao, limite: limiteDoAnfitriaoNoMenu)
            ))
            if let aviso = destino.aviso { entradas.append(.legenda(aviso)) }
            entradas.append(contentsOf: acoes(url).map(ContextMenuEntry.item))
        } else {
            entradas.append(.legenda("\(abriveis.count) links neste trecho"))
            for url in abriveis {
                let destino = destino(de: url)
                let titulo = destino.map { $0.anfitriao.isEmpty ? $0.porExtenso : $0.anfitriao }
                    ?? url.absoluteString
                entradas.append(.submenu(
                    title: anfitriaoCurto(titulo, limite: limiteDoAnfitriaoNoMenu),
                    items: acoes(url)
                ))
            }
        }

        let texto = textoDoBloco.trimmingCharacters(in: .whitespacesAndNewlines)
        if !texto.isEmpty {
            entradas.append(.separator)
            entradas.append(.item(ContextMenuItem("Copiar o texto do trecho", .copy(texto))))
        }
        return entradas.tidied
    }

    private static func acoes(_ url: URL) -> [ContextMenuItem] {
        [
            ContextMenuItem(rotuloDeAbertura(url), .abrirLink(url: url)),
            ContextMenuItem("Copiar link", .copy(url.absoluteString)),
        ]
    }
}
