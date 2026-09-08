"""Plano logico e plano fisico (M3).

O usuario monta um plano logico — o que ele quer. O executor escolhe um plano
fisico — como fazer. Esta separacao e o que permite, no M8, reordenar e empurrar
filtros sem mudar uma linha da API.

Ate M7 a traducao e um-para-um; a estrutura existe para o otimizador ter onde
morar.
"""

from .expr import Expr


struct TipoEtapa:
    """Etapas do plano logico."""

    comptime FILTRO = 0
    comptime PROJECAO = 1
    comptime COM_COLUNA = 2

    @staticmethod
    def nome_logico(tipo: Int) raises -> String:
        if tipo == Self.FILTRO:
            return "FILTER"
        if tipo == Self.PROJECAO:
            return "PROJECT"
        if tipo == Self.COM_COLUNA:
            return "WITH_COLUMN"
        raise Error("etapa desconhecida: " + String(tipo))

    @staticmethod
    def nome_fisico(tipo: Int) raises -> String:
        if tipo == Self.FILTRO:
            return "FilterExec"
        if tipo == Self.PROJECAO:
            return "ProjectionExec"
        if tipo == Self.COM_COLUNA:
            return "ExpressionExec"
        raise Error("etapa desconhecida: " + String(tipo))


struct Etapa(Copyable, Movable):
    """Uma etapa do plano. `expr` e `nomes` sao usados conforme o tipo."""

    var tipo: Int
    var expr: Expr
    var nomes: List[String]
    var nome: String

    def __init__(out self, tipo: Int, var expr: Expr, var nomes: List[String], nome: String):
        self.tipo = tipo
        self.expr = expr^
        self.nomes = nomes^
        self.nome = nome

    @staticmethod
    def filtro(var pred: Expr) -> Self:
        return Self(TipoEtapa.FILTRO, pred^, List[String](), "")

    @staticmethod
    def projecao(var nomes: List[String]) -> Self:
        return Self(TipoEtapa.PROJECAO, Expr(), nomes^, "")

    @staticmethod
    def com_coluna(nome: String, var expr: Expr) -> Self:
        return Self(TipoEtapa.COM_COLUNA, expr^, List[String](), nome)

    def descrever_logica(self) raises -> String:
        var cabeca = TipoEtapa.nome_logico(self.tipo)
        if self.tipo == TipoEtapa.FILTRO:
            return cabeca + " " + self.expr.descrever()
        if self.tipo == TipoEtapa.COM_COLUNA:
            return cabeca + " " + self.nome + " = " + self.expr.descrever()
        var s = cabeca + " ["
        for i in range(len(self.nomes)):
            if i > 0:
                s += ", "
            s += self.nomes[i]
        return s + "]"

    def descrever_fisica(self) raises -> String:
        return TipoEtapa.nome_fisico(self.tipo) + ": " + self.descrever_logica()


def descrever_logico(etapas: List[Etapa]) raises -> String:
    var s = String("SCAN")
    for e in etapas:
        s += " -> " + e.descrever_logica()
    return s + " -> RESULT"


def descrever_fisico(etapas: List[Etapa]) raises -> String:
    """Plano fisico indentado, do operador de baixo para o de cima."""
    var linhas = List[String]()
    linhas.append("ScanExec: tabela em memoria")
    for e in etapas:
        linhas.append(e.descrever_fisica())

    var s = String("")
    for i in range(len(linhas)):
        var nivel = len(linhas) - 1 - i
        if i > 0:
            s += "\n"
        for _ in range(nivel):
            s += "  "
        s += linhas[len(linhas) - 1 - i]
    return s
