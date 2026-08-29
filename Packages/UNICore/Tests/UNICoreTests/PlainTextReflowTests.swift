import Foundation
import Testing
@testable import UNICore

/// O email que o dono pôs na tela, letra por letra. É o caso que nomeia a
/// tarefa: cinco parágrafos, e a frase da call inteira num só.
private let emailDoDono = """
    Olá,

    Passando para confirmar nossa call amanhã, 16 de julho, às 15h,
    no horário
    de Brasília.

    O link da reunião está disponível no convite da agenda.

    Até lá!

    Hugo
    """

@Suite("O texto plano refluído")
struct PlainTextReflowTests {

    @Test("O email da tela: cinco parágrafos, e a call num só")
    func emailDaTela() {
        let paragrafos = PlainTextReflow.paragraphs(from: emailDoDono)
        #expect(paragrafos.count == 5)
        #expect(paragrafos[0] == "Olá,")
        #expect(paragrafos[1] == """
            Passando para confirmar nossa call amanhã, 16 de julho, às 15h, \
            no horário de Brasília.
            """)
        #expect(paragrafos[2] == "O link da reunião está disponível no convite da agenda.")
        #expect(paragrafos[3] == "Até lá!")
        #expect(paragrafos[4] == "Hugo")
        // Nenhum parágrafo carrega quebra dentro: era isso que o leitor
        // desenhava como bloco separado.
        #expect(paragrafos.allSatisfy { !$0.contains("\n") })
    }

    @Test("Sem refluxo, o mesmo email teria sete blocos")
    func semRefluxoSeriamSete() {
        // A conta do defeito: as sete linhas não-vazias que o leitor desenhava.
        let linhas = emailDoDono
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        #expect(linhas.count == 7)
    }

    @Test("A quebra de 72 colunas some")
    func quebraDeTransporte() {
        let cru = """
            Segue o resumo da reunião de ontem com o time de produto, com as
            decisões que ficaram e o que cada um leva para a semana que vem.
            """
        #expect(PlainTextReflow.reflow(cru) == """
            Segue o resumo da reunião de ontem com o time de produto, com as \
            decisões que ficaram e o que cada um leva para a semana que vem.
            """)
    }

    @Test("Uma lista nunca vira parágrafo")
    func listaFicaIntacta() {
        let cru = """
            Pendências:
            - renovar o certificado do ambiente novo antes de sexta-feira
            - fechar o escopo de suporte com o jurídico
            * conferir o orçamento
            1. assinar o contrato
            2) mandar a nota
            """
        #expect(PlainTextReflow.reflow(cru) == cru)
    }

    @Test("Citação, assinatura e tabela ficam como estão")
    func formasProprias() {
        let citacao = """
            > mandei o arquivo ontem, dá uma olhada quando puder por favor
            > ele está na pasta compartilhada
            """
        #expect(PlainTextReflow.reflow(citacao) == citacao)

        let assinatura = """
            --
            Hugo Marques
            Diretor de operações e responsável pelo time de atendimento aqui
            OkamiOps
            """
        #expect(PlainTextReflow.reflow(assinatura) == assinatura)

        let tabela = """
            Produto      Qtd   Valor
              Caderno      2   19,90
              Caneta      10    4,50
            """
        #expect(PlainTextReflow.reflow(tabela) == tabela)
    }

    @Test("Saudação e despedida curtas continuam sozinhas")
    func linhasCurtasIntencionais() {
        let cru = """
            Olá,
            Segue o contrato.
            Abraços,
            Hugo
            """
        #expect(PlainTextReflow.reflow(cru) == cru)
    }

    @Test("Quem terminou a frase quebrou de propósito")
    func fimDeFraseSegura() {
        let cru = """
            A entrega foi confirmada para a próxima terça-feira de manhã.
            O pagamento sai junto.
            """
        #expect(PlainTextReflow.reflow(cru) == cru)
    }

    @Test("format=flowed: espaço no fim da linha é continuação")
    func flowedDeclarado() {
        let cru = "Confirmo a reunião \nde amanhã às 15h.\nAté lá!"
        #expect(PlainTextReflow.reflow(cru, flowed: true) == """
            Confirmo a reunião de amanhã às 15h.
            Até lá!
            """)
    }

    @Test("format=flowed com DelSp=Yes: o espaço da quebra some")
    func flowedComDelSp() {
        let cru = "conti \nnuação"
        #expect(PlainTextReflow.reflow(cru, flowed: true, delSp: true) == "continuação")
        #expect(PlainTextReflow.reflow(cru, flowed: true, delSp: false) == "conti nuação")
    }

    @Test("format=flowed: o espaço de enchimento sai, e `-- ` continua assinatura")
    func flowedDesenche() {
        let cru = " > isto não é citação, é enchimento\n-- \nHugo"
        #expect(PlainTextReflow.reflow(cru, flowed: true).components(separatedBy: "\n")
            == ["> isto não é citação, é enchimento", "-- ", "Hugo"])
    }

    @Test("Uma linha só, ou nenhuma, atravessa igual")
    func casosDegenerados() {
        #expect(PlainTextReflow.reflow("") == "")
        #expect(PlainTextReflow.reflow("Recibo da sua assinatura anual.")
            == "Recibo da sua assinatura anual.")
        // As fixtures do Marco 1 têm corpos de um parágrafo por linha: o
        // refluxo não pode encostar em nenhuma delas.
        for mensagem in Fixtures.messages {
            for paragrafo in mensagem.body {
                #expect(PlainTextReflow.reflow(paragrafo) == paragrafo)
            }
        }
    }
}
