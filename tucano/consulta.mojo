"""Consulta lazy — monta plano sem materializar (M2).

M2.5: avaliacao de predicado em logica de tres valores (Decisao 2 do CONTRATO) e
suporte a datas nas expressoes.
"""

from .tabela import Tabela
from .coluna import Coluna
from .expr import Expr, ExprNode, Kind
from .dtype import DType
from .datas import civil_de_dias
from .erros import erro_coluna


struct Tri:
    """Valor logico de tres estados.

    Comparar com ausente nao da Falso: da Desconhecido. `onde()` mantem apenas
    Verdadeiro, entao a linha ausente e descartada com ou sem negacao.
    """

    comptime FALSO = 0
    comptime VERDADEIRO = 1
    comptime DESCONHECIDO = 2


def _de_bool(b: Bool) -> Int:
    if b:
        return Tri.VERDADEIRO
    return Tri.FALSO


struct Consulta(Copyable, Movable):
    """Pipeline lazy sobre uma Tabela fonte.

    `onde` / `selecionar` so adicionam nos ao plano.
    `coletar()` materializa uma nova Tabela.
    """

    var fonte: Tabela
    var tem_filtro: Bool
    var filtro: Expr
    var projecao: List[String]

    def __init__(out self, var fonte: Tabela):
        self.fonte = fonte^
        self.tem_filtro = False
        self.filtro = Expr()
        self.projecao = List[String]()

    @staticmethod
    def de(var fonte: Tabela) -> Self:
        return Self(fonte^)

    def onde(var self, var pred: Expr) -> Self:
        if self.tem_filtro:
            self.filtro = self.filtro.copy().e(pred^)
        else:
            self.filtro = pred^
            self.tem_filtro = True
        return self^

    def selecionar(var self, nomes: List[String]) raises -> Self:
        if len(nomes) == 0:
            raise Error("selecionar exige pelo menos um nome")
        self.projecao = List[String]()
        for nome in nomes:
            self.projecao.append(nome)
        return self^

    def descrever(self) raises -> String:
        var s = String("SCAN")
        if self.tem_filtro:
            s += " -> FILTER " + self.filtro.descrever()
        if len(self.projecao) > 0:
            s += " -> PROJECT ["
            for i in range(len(self.projecao)):
                if i > 0:
                    s += ", "
                s += self.projecao[i]
            s += "]"
        s += " -> RESULT"
        return s

    def coletar(self) raises -> Tabela:
        var n = self.fonte.linhas()
        var keep = List[Bool](capacity=n)
        for i in range(n):
            if self.tem_filtro:
                # so Verdadeiro passa; Desconhecido e descartado
                keep.append(_eval_tri(self.filtro, self.fonte, i) == Tri.VERDADEIRO)
            else:
                keep.append(True)

        var nomes_out = List[String]()
        if len(self.projecao) == 0:
            for nome in self.fonte.nomes():
                nomes_out.append(nome)
        else:
            for nome in self.projecao:
                _ = self.fonte.dtype_de(nome)  # valida com sugestao de nome
                nomes_out.append(nome)

        var cols_out = List[Coluna]()
        for nome in nomes_out:
            cols_out.append(_filtrar_coluna(self.fonte.pegar(nome), keep))
        return Tabela(cols_out^)


# ---------------------------------------------------------------- numerico


def _eval_float(expr: Expr, tab: Tabela, row: Int) raises -> Float64:
    return _eval_float_no(expr, expr.nodes[expr.root].copy(), tab, row)


def _eval_float_no(expr: Expr, n: ExprNode, tab: Tabela, row: Int) raises -> Float64:
    var k = n.kind
    if k == Kind.LIT_F64:
        return n.f64
    if k == Kind.LIT_I64 or k == Kind.LIT_DATA:
        return Float64(n.i64)
    if k == Kind.COLUNA:
        var col = tab.pegar(n.nome)
        if col.eh_ausente(row):
            raise Error("NA em expressao numerica: " + n.nome)
        # data avalia como dias desde a epoch, o que torna comparavel com lit_data
        if col.dtype().eh_numerico() or col.dtype().eh_temporal():
            if col.tipo == DType.INTEIRO or col.tipo == DType.DATA:
                return Float64(col.ints[row])
            return col.reals[row]
        raise Error("coluna nao numerica em expressao: " + n.nome)
    if k == Kind.ANO or k == Kind.MES or k == Kind.DIA:
        var dias = Int(_eval_float_no(expr, expr.nodes[n.left].copy(), tab, row))
        var civil = civil_de_dias(dias)
        if k == Kind.ANO:
            return Float64(civil.ano)
        if k == Kind.MES:
            return Float64(civil.mes)
        return Float64(civil.dia)
    if k == Kind.ADD:
        return _eval_float_no(expr, expr.nodes[n.left].copy(), tab, row) + _eval_float_no(
            expr, expr.nodes[n.right].copy(), tab, row
        )
    if k == Kind.SUB:
        return _eval_float_no(expr, expr.nodes[n.left].copy(), tab, row) - _eval_float_no(
            expr, expr.nodes[n.right].copy(), tab, row
        )
    if k == Kind.MUL:
        return _eval_float_no(expr, expr.nodes[n.left].copy(), tab, row) * _eval_float_no(
            expr, expr.nodes[n.right].copy(), tab, row
        )
    if k == Kind.DIV:
        return _eval_float_no(expr, expr.nodes[n.left].copy(), tab, row) / _eval_float_no(
            expr, expr.nodes[n.right].copy(), tab, row
        )
    raise Error("no nao numerico na expressao")


def _eval_texto(expr: Expr, n: ExprNode, tab: Tabela, row: Int) raises -> String:
    if n.kind == Kind.LIT_STR:
        return n.texto
    if n.kind == Kind.COLUNA:
        return tab.pegar(n.nome).texto_em(row)
    raise Error("no nao textual na expressao")


def _no_tem_na(expr: Expr, n: ExprNode, tab: Tabela, row: Int) raises -> Bool:
    """Propaga ausencia pelos nos que nao sao booleanos."""
    if n.kind == Kind.COLUNA:
        return tab.eh_ausente(n.nome, row)
    if n.kind == Kind.ANO or n.kind == Kind.MES or n.kind == Kind.DIA:
        return _no_tem_na(expr, expr.nodes[n.left].copy(), tab, row)
    if (
        n.kind == Kind.ADD
        or n.kind == Kind.SUB
        or n.kind == Kind.MUL
        or n.kind == Kind.DIV
    ):
        return _no_tem_na(expr, expr.nodes[n.left].copy(), tab, row) or _no_tem_na(
            expr, expr.nodes[n.right].copy(), tab, row
        )
    return False


def _eh_no_textual(expr: Expr, n: ExprNode, tab: Tabela) raises -> Bool:
    if n.kind == Kind.LIT_STR:
        return True
    if n.kind == Kind.COLUNA:
        return tab.dtype_de(n.nome).codigo == DType.TEXTO
    return False


# ------------------------------------------------------- logica de 3 valores


def _eval_tri(expr: Expr, tab: Tabela, row: Int) raises -> Int:
    return _eval_tri_no(expr, expr.nodes[expr.root].copy(), tab, row)


def _eval_tri_no(expr: Expr, n: ExprNode, tab: Tabela, row: Int) raises -> Int:
    var k = n.kind

    if k == Kind.LIT_BOOL:
        return _de_bool(n.logico)

    if k == Kind.COLUNA:
        # coluna logica usada direto como predicado: onde(coluna("ativo"))
        if tab.dtype_de(n.nome).codigo != DType.LOGICO:
            raise Error(
                "coluna nao logica usada como predicado: "
                + n.nome
                + " (use uma comparacao)"
            )
        if tab.eh_ausente(n.nome, row):
            return Tri.DESCONHECIDO
        return _de_bool(Int(tab.pegar(n.nome).logics[row]) != 0)

    if k == Kind.NOT:
        var v = _eval_tri_no(expr, expr.nodes[n.left].copy(), tab, row)
        if v == Tri.DESCONHECIDO:
            return Tri.DESCONHECIDO
        if v == Tri.VERDADEIRO:
            return Tri.FALSO
        return Tri.VERDADEIRO

    if k == Kind.AND:
        var a = _eval_tri_no(expr, expr.nodes[n.left].copy(), tab, row)
        var b = _eval_tri_no(expr, expr.nodes[n.right].copy(), tab, row)
        if a == Tri.FALSO or b == Tri.FALSO:
            return Tri.FALSO
        if a == Tri.DESCONHECIDO or b == Tri.DESCONHECIDO:
            return Tri.DESCONHECIDO
        return Tri.VERDADEIRO

    if k == Kind.OR:
        var a = _eval_tri_no(expr, expr.nodes[n.left].copy(), tab, row)
        var b = _eval_tri_no(expr, expr.nodes[n.right].copy(), tab, row)
        if a == Tri.VERDADEIRO or b == Tri.VERDADEIRO:
            return Tri.VERDADEIRO
        if a == Tri.DESCONHECIDO or b == Tri.DESCONHECIDO:
            return Tri.DESCONHECIDO
        return Tri.FALSO

    if k == Kind.GT or k == Kind.GE or k == Kind.LT or k == Kind.LE:
        var esq = expr.nodes[n.left].copy()
        var dir = expr.nodes[n.right].copy()
        if _no_tem_na(expr, esq, tab, row) or _no_tem_na(expr, dir, tab, row):
            return Tri.DESCONHECIDO
        var a = _eval_float_no(expr, esq, tab, row)
        var b = _eval_float_no(expr, dir, tab, row)
        if k == Kind.GT:
            return _de_bool(a > b)
        if k == Kind.GE:
            return _de_bool(a >= b)
        if k == Kind.LT:
            return _de_bool(a < b)
        return _de_bool(a <= b)

    if k == Kind.EQ or k == Kind.NE:
        var esq = expr.nodes[n.left].copy()
        var dir = expr.nodes[n.right].copy()
        if _no_tem_na(expr, esq, tab, row) or _no_tem_na(expr, dir, tab, row):
            return Tri.DESCONHECIDO
        if _eh_no_textual(expr, esq, tab) or _eh_no_textual(expr, dir, tab):
            var sa = _eval_texto(expr, esq, tab, row)
            var sb = _eval_texto(expr, dir, tab, row)
            if k == Kind.EQ:
                return _de_bool(sa == sb)
            return _de_bool(sa != sb)
        var fa = _eval_float_no(expr, esq, tab, row)
        var fb = _eval_float_no(expr, dir, tab, row)
        if k == Kind.EQ:
            return _de_bool(fa == fb)
        return _de_bool(fa != fb)

    raise Error("expressao de filtro nao booleana")


def lazy(tab: Tabela) -> Consulta:
    """Entrada no pipeline lazy a partir de uma Tabela."""
    return Consulta.de(tab.copy())


def _filtrar_coluna(col: Coluna, keep: List[Bool]) raises -> Coluna:
    var n_out = 0
    for flag in keep:
        if flag:
            n_out += 1

    if col.tipo == DType.INTEIRO or col.tipo == DType.DATA:
        var vals = List[Int64](capacity=n_out)
        var aus = List[Bool](capacity=n_out)
        for i in range(col.tamanho()):
            if keep[i]:
                vals.append(col.ints[i])
                aus.append(col.eh_ausente(i))
        if col.tipo == DType.DATA:
            return Coluna.de_datas(col.nome, vals^, aus^)
        return Coluna.de_inteiros(col.nome, vals^, aus^)

    if col.tipo == DType.REAL:
        var vals = List[Float64](capacity=n_out)
        var aus = List[Bool](capacity=n_out)
        for i in range(col.tamanho()):
            if keep[i]:
                vals.append(col.reals[i])
                aus.append(col.eh_ausente(i))
        return Coluna.de_reais(col.nome, vals^, aus^)

    if col.tipo == DType.LOGICO:
        var vals = List[Bool](capacity=n_out)
        var aus = List[Bool](capacity=n_out)
        for i in range(col.tamanho()):
            if keep[i]:
                vals.append(Int(col.logics[i]) != 0)
                aus.append(col.eh_ausente(i))
        return Coluna.de_logicos(col.nome, vals^, aus^)

    var vals = List[String](capacity=n_out)
    var aus = List[Bool](capacity=n_out)
    for i in range(col.tamanho()):
        if keep[i]:
            if col.eh_ausente(i):
                vals.append("")
                aus.append(True)
            else:
                vals.append(col.textos.get(i))
                aus.append(False)
    return Coluna.de_textos(col.nome, vals^, aus^)
