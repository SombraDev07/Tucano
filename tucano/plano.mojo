"""Plano logico e plano fisico (M3).

O usuario monta um plano logico — o que ele quer. O executor escolhe um plano
fisico — como fazer. Esta separacao e o que permite, no M8, reordenar e empurrar
filtros sem mudar uma linha da API.

Ate M7 a traducao e um-para-um; a estrutura existe para o otimizador ter onde
morar.
"""

from .expr import Expr
from .agregacao import Agregacao
from .coluna import Coluna


struct TipoEtapa:
    """Etapas do plano logico."""

    comptime FILTRO = 0
    comptime PROJECAO = 1
    comptime COM_COLUNA = 2
    comptime AGREGACAO = 3
    comptime JUNCAO = 4
    comptime ORDENACAO = 5
    comptime CONCATENACAO = 6
    comptime REMOVER_NA = 7
    comptime PREENCHER_NA = 8
    comptime LIMITE = 9

    @staticmethod
    def nome_logico(tipo: Int) raises -> String:
        if tipo == Self.FILTRO:
            return "FILTER"
        if tipo == Self.PROJECAO:
            return "PROJECT"
        if tipo == Self.COM_COLUNA:
            return "WITH_COLUMN"
        if tipo == Self.AGREGACAO:
            return "AGGREGATE"
        if tipo == Self.JUNCAO:
            return "JOIN"
        if tipo == Self.ORDENACAO:
            return "SORT"
        if tipo == Self.CONCATENACAO:
            return "UNION ALL"
        if tipo == Self.REMOVER_NA:
            return "DROP NULLS"
        if tipo == Self.PREENCHER_NA:
            return "FILL NULLS"
        if tipo == Self.LIMITE:
            return "LIMIT"
        raise Error("etapa desconhecida: " + String(tipo))

    @staticmethod
    def nome_fisico(tipo: Int) raises -> String:
        if tipo == Self.FILTRO:
            return "FilterExec"
        if tipo == Self.PROJECAO:
            return "ProjectionExec"
        if tipo == Self.COM_COLUNA:
            return "ExpressionExec"
        if tipo == Self.AGREGACAO:
            return "HashAggregateExec"
        if tipo == Self.JUNCAO:
            return "HashJoinExec"
        if tipo == Self.ORDENACAO:
            return "SortExec"
        if tipo == Self.CONCATENACAO:
            return "UnionExec"
        if tipo == Self.REMOVER_NA:
            return "DropNullExec"
        if tipo == Self.PREENCHER_NA:
            return "FillNullExec"
        if tipo == Self.LIMITE:
            return "LimitExec"
        raise Error("etapa desconhecida: " + String(tipo))


struct Etapa(Copyable, Movable):
    """Uma etapa do plano. `expr` e `nomes` sao usados conforme o tipo."""

    var tipo: Int
    var expr: Expr
    var nomes: List[String]
    var nome: String
    var agregacoes: List[Agregacao]
    var lote_direito: List[Coluna]
    var tipo_juncao: Int
    var descendente: List[Bool]
    var limite: Int

    def __init__(
        out self,
        tipo: Int,
        var expr: Expr,
        var nomes: List[String],
        nome: String,
        var agregacoes: List[Agregacao] = List[Agregacao](),
        var lote_direito: List[Coluna] = List[Coluna](),
        tipo_juncao: Int = 0,
        var descendente: List[Bool] = List[Bool](),
        limite: Int = -1,
    ):
        self.tipo = tipo
        self.expr = expr^
        self.nomes = nomes^
        self.nome = nome
        self.agregacoes = agregacoes^
        self.lote_direito = lote_direito^
        self.tipo_juncao = tipo_juncao
        self.descendente = descendente^
        self.limite = limite

    @staticmethod
    def filtro(var pred: Expr) -> Self:
        return Self(TipoEtapa.FILTRO, pred^, List[String](), "")

    @staticmethod
    def projecao(var nomes: List[String]) -> Self:
        return Self(TipoEtapa.PROJECAO, Expr(), nomes^, "")

    @staticmethod
    def com_coluna(nome: String, var expr: Expr) -> Self:
        return Self(TipoEtapa.COM_COLUNA, expr^, List[String](), nome)

    @staticmethod
    def agregacao(var chaves: List[String], var agregacoes: List[Agregacao]) -> Self:
        return Self(TipoEtapa.AGREGACAO, Expr(), chaves^, "", agregacoes^)

    @staticmethod
    def juncao(
        var direita: List[Coluna], var chaves: List[String], tipo: Int
    ) -> Self:
        return Self(
            TipoEtapa.JUNCAO, Expr(), chaves^, "", List[Agregacao](), direita^, tipo
        )

    @staticmethod
    def ordenacao(var chaves: List[String], var desc: List[Bool]) -> Self:
        return Self(
            TipoEtapa.ORDENACAO, Expr(), chaves^, "", List[Agregacao](),
            List[Coluna](), 0, desc^,
        )

    @staticmethod
    def concatenacao(var outra: List[Coluna]) -> Self:
        return Self(
            TipoEtapa.CONCATENACAO, Expr(), List[String](), "",
            List[Agregacao](), outra^, 0,
        )

    @staticmethod
    def remover_na(var nomes: List[String]) -> Self:
        return Self(TipoEtapa.REMOVER_NA, Expr(), nomes^, "")

    @staticmethod
    def limite_de(n: Int) -> Self:
        return Self(
            TipoEtapa.LIMITE, Expr(), List[String](), "", List[Agregacao](),
            List[Coluna](), 0, List[Bool](), n,
        )

    @staticmethod
    def preencher_na(nome: String, var expr: Expr) -> Self:
        return Self(TipoEtapa.PREENCHER_NA, expr^, List[String](), nome)

    def descrever_logica(self) raises -> String:
        var cabeca = TipoEtapa.nome_logico(self.tipo)
        if self.tipo == TipoEtapa.FILTRO:
            return cabeca + " " + self.expr.descrever()
        if self.tipo == TipoEtapa.COM_COLUNA:
            return cabeca + " " + self.nome + " = " + self.expr.descrever()
        if self.tipo == TipoEtapa.PREENCHER_NA:
            return cabeca + " " + self.nome + " <- " + self.expr.descrever()
        if self.tipo == TipoEtapa.LIMITE:
            return cabeca + " " + String(self.limite)
        if self.tipo == TipoEtapa.CONCATENACAO:
            return cabeca
        if self.tipo == TipoEtapa.ORDENACAO:
            var s = cabeca + " ["
            for i in range(len(self.nomes)):
                if i > 0:
                    s += ", "
                s += self.nomes[i]
                if i < len(self.descendente) and self.descendente[i]:
                    s += " desc"
            return s + "]"
        if self.tipo == TipoEtapa.REMOVER_NA and len(self.nomes) == 0:
            return cabeca + " [todas]"
        var lista = String("[")
        for i in range(len(self.nomes)):
            if i > 0:
                lista += ", "
            lista += self.nomes[i]
        lista += "]"

        if self.tipo == TipoEtapa.JUNCAO:
            var lado = "interno"
            if self.tipo_juncao == 1:
                lado = "esquerda"
            return cabeca + " " + lado + " por " + lista

        var s = cabeca + " " + lista
        if self.tipo == TipoEtapa.AGREGACAO:
            s += " -> ["
            for i in range(len(self.agregacoes)):
                if i > 0:
                    s += ", "
                s += self.agregacoes[i].descrever()
            s += "]"
        return s

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
