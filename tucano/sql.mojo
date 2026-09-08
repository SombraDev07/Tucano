"""Dialeto SQL minimo sobre o mesmo planner (M10).

Nao ha um segundo motor. `SELECT` vira exatamente as mesmas etapas que a API
fluente produz, passa pelo mesmo otimizador e pelo mesmo executor:

    SELECT cidade, SUM(valor) AS total
    FROM 'vendas.parquet'
    WHERE valor > 1000
    GROUP BY cidade
    HAVING SUM(valor) > 5000
    ORDER BY total DESC

    SELECT cidade, estado
    FROM vendas
    JOIN cidades USING (cidade)

vira

    SCAN -> FILTER (coluna(valor) > lit(1000)) -> AGGREGATE [cidade] -> [soma(valor)]
         -> PROJECT [cidade, total] -> SORT [total desc] -> RESULT

Isso e um teste da arquitetura, nao so um recurso: se o plano nao fosse um valor
manipulavel, seria preciso um interpretador separado para SQL.

Suportado: `SELECT` com colunas e agregacoes (`SUM`, `AVG`, `COUNT`, `MIN`,
`MAX`), `AS`, `FROM` (arquivo ou tabela registrada), `JOIN` / `LEFT JOIN`
com `USING (colunas)`, `WHERE`, `GROUP BY`, `HAVING`, `ORDER BY` com `ASC`/`DESC`,
`LIMIT`. `COUNT(DISTINCT coluna)` e `distintos`. O resto e recusado com a posicao
do erro.
"""

from std.collections import Dict
from .expr import (
    Expr,
    coluna,
    lit,
    lit_int,
    lit_texto,
    lit_bool,
)
from .agregacao import (
    Agregacao,
    soma,
    media,
    contar,
    contar_de,
    minimo,
    maximo,
    distintos,
)


struct TipoToken:
    comptime FIM = 0
    comptime NOME = 1
    comptime NUMERO = 2
    comptime TEXTO = 3
    comptime SIMBOLO = 4


@fieldwise_init
struct Token(Copyable, Movable):
    var tipo: Int
    var texto: String
    var posicao: Int


def _eh_letra(b: UInt8) -> Bool:
    return (
        (b >= UInt8(65) and b <= UInt8(90))
        or (b >= UInt8(97) and b <= UInt8(122))
        or b == UInt8(95)
    )


def _eh_digito(b: UInt8) -> Bool:
    return b >= UInt8(48) and b <= UInt8(57)


def _eh_branco(b: UInt8) -> Bool:
    return (
        b == UInt8(32) or b == UInt8(9) or b == UInt8(10) or b == UInt8(13)
    )


def tokenizar(texto: String) raises -> List[Token]:
    var b = texto.as_bytes()
    var n = len(b)
    var out = List[Token]()
    var i = 0
    while i < n:
        if _eh_branco(b[i]):
            i += 1
            continue

        if _eh_letra(b[i]):
            var ini = i
            while i < n and (_eh_letra(b[i]) or _eh_digito(b[i])):
                i += 1
            out.append(Token(TipoToken.NOME, String(texto[byte=ini:i]), ini))
            continue

        if _eh_digito(b[i]):
            var ini = i
            while i < n and (_eh_digito(b[i]) or b[i] == UInt8(46)):
                i += 1
            out.append(Token(TipoToken.NUMERO, String(texto[byte=ini:i]), ini))
            continue

        if b[i] == UInt8(39) or b[i] == UInt8(34):
            var aspa = b[i]
            var ini = i + 1
            i += 1
            while i < n and b[i] != aspa:
                i += 1
            if i >= n:
                raise Error("SQL: literal de texto sem fechamento na posicao " + String(ini - 1))
            out.append(Token(TipoToken.TEXTO, String(texto[byte=ini:i]), ini))
            i += 1
            continue

        # simbolos de dois caracteres primeiro
        if i + 1 < n:
            var par = String(texto[byte=i : i + 2])
            if par == ">=" or par == "<=" or par == "<>" or par == "!=":
                out.append(Token(TipoToken.SIMBOLO, par, i))
                i += 2
                continue

        out.append(Token(TipoToken.SIMBOLO, String(texto[byte=i : i + 1]), i))
        i += 1

    out.append(Token(TipoToken.FIM, "", n))
    return out^


def _maiusculo(s: String) -> String:
    return String(s.upper())


struct ItemSelecao(Copyable, Movable):
    """Uma entrada da lista do SELECT: coluna simples ou agregacao."""

    var eh_agregacao: Bool
    var coluna: String
    var agregacao: Agregacao
    var apelido: String

    def __init__(
        out self,
        eh_agregacao: Bool,
        coluna: String,
        var agregacao: Agregacao,
        apelido: String,
    ):
        self.eh_agregacao = eh_agregacao
        self.coluna = coluna
        self.agregacao = agregacao^
        self.apelido = apelido


struct ConsultaSQL(Movable):
    """O que o SELECT pediu, ainda sem virar plano."""

    var tudo: Bool
    var distinto: Bool
    var itens: List[ItemSelecao]
    var fonte: String
    var tem_juncao: Bool
    var fonte_dir: String
    var tipo_juncao: String
    var chaves_juncao: List[String]
    var tem_onde: Bool
    var onde: Expr
    var agrupar: List[String]
    var tem_tendo: Bool
    var tendo: Expr
    var extras_tendo: List[Agregacao]
    var ordenar: List[String]
    var descendente: Bool
    var limite: Int

    def __init__(out self):
        self.tudo = False
        self.distinto = False
        self.itens = List[ItemSelecao]()
        self.fonte = ""
        self.tem_juncao = False
        self.fonte_dir = ""
        self.tipo_juncao = "interno"
        self.chaves_juncao = List[String]()
        self.tem_onde = False
        self.onde = Expr()
        self.agrupar = List[String]()
        self.tem_tendo = False
        self.tendo = Expr()
        self.extras_tendo = List[Agregacao]()
        self.ordenar = List[String]()
        self.descendente = False
        self.limite = -1

    def tem_agregacao(self) -> Bool:
        for i in self.itens:
            if i.eh_agregacao:
                return True
        return False


struct Analisador(Movable):
    var tokens: List[Token]
    var pos: Int
    var modo_tendo: Bool
    var itens_sel: List[ItemSelecao]
    var extras_tendo: List[Agregacao]

    def __init__(out self, var tokens: List[Token]):
        self.tokens = tokens^
        self.pos = 0
        self.modo_tendo = False
        self.itens_sel = List[ItemSelecao]()
        self.extras_tendo = List[Agregacao]()

    def atual(self) -> Token:
        return self.tokens[self.pos].copy()

    def avancar(mut self) -> Token:
        var t = self.tokens[self.pos].copy()
        if self.pos < len(self.tokens) - 1:
            self.pos += 1
        return t^

    def _erro(self, esperado: String) raises -> Error:
        var t = self.atual()
        var achado = t.texto
        if t.tipo == TipoToken.FIM:
            achado = "fim da consulta"
        return Error(
            "SQL: esperava " + esperado + ", achei '" + achado + "' na posicao "
            + String(t.posicao)
        )

    def eh_palavra(self, palavra: String) -> Bool:
        var t = self.atual()
        return t.tipo == TipoToken.NOME and _maiusculo(t.texto) == palavra

    def consumir_palavra(mut self, palavra: String) raises:
        if not self.eh_palavra(palavra):
            var erro = self._erro("'" + palavra + "'")
            raise erro^
        _ = self.avancar()

    def aceitar_palavra(mut self, palavra: String) -> Bool:
        if self.eh_palavra(palavra):
            _ = self.avancar()
            return True
        return False

    def eh_simbolo(self, s: String) -> Bool:
        var t = self.atual()
        return t.tipo == TipoToken.SIMBOLO and t.texto == s

    def consumir_simbolo(mut self, s: String) raises:
        if not self.eh_simbolo(s):
            var erro = self._erro("'" + s + "'")
            raise erro^
        _ = self.avancar()

    def aceitar_simbolo(mut self, s: String) -> Bool:
        if self.eh_simbolo(s):
            _ = self.avancar()
            return True
        return False

    def nome(mut self) raises -> String:
        var t = self.atual()
        if t.tipo != TipoToken.NOME:
            var erro = self._erro("um nome de coluna")
            raise erro^
        _ = self.avancar()
        return t.texto

    def _chamada_agregacao(mut self, nome: String) raises -> Agregacao:
        """Nome ja lido; o token atual e `(`. COUNT(DISTINCT coluna) e `distintos`."""
        self.consumir_simbolo("(")
        var distinto = self.aceitar_palavra("DISTINCT")
        var alvo: String
        if self.aceitar_simbolo("*"):
            if distinto:
                raise Error("SQL: COUNT(DISTINCT *) nao existe")
            alvo = "*"
        else:
            alvo = self.nome()
        self.consumir_simbolo(")")
        if distinto:
            if _maiusculo(nome) != "COUNT":
                raise Error("SQL: DISTINCT so vale em COUNT(DISTINCT coluna)")
            return distintos(alvo)
        return _agregacao_de(nome, alvo)

    def _saida_da_agg(mut self, ag: Agregacao) raises -> String:
        """HAVING SUM(valor) usa o apelido do SELECT, ou calcula a extra e descarta depois."""
        for item in self.itens_sel:
            if item.eh_agregacao:
                if item.agregacao.tipo == ag.tipo and item.agregacao.coluna == ag.coluna:
                    if item.apelido != "":
                        return item.apelido
                    return item.agregacao.nome_saida()
        for e in self.extras_tendo:
            if e.tipo == ag.tipo and e.coluna == ag.coluna:
                return e.nome_saida()
        var saida = ag.nome_saida()
        self.extras_tendo.append(ag.copy())
        return saida

    # ------------------------------------------------------------ expressao

    def expressao(mut self) raises -> Expr:
        return self.ou()

    def ou(mut self) raises -> Expr:
        var e = self.e()
        while self.eh_palavra("OR"):
            _ = self.avancar()
            e = e^.ou(self.e())
        return e^

    def e(mut self) raises -> Expr:
        var e = self.nao()
        while self.eh_palavra("AND"):
            _ = self.avancar()
            e = e^.e(self.nao())
        return e^

    def nao(mut self) raises -> Expr:
        if self.eh_palavra("NOT"):
            _ = self.avancar()
            var interna = self.nao()
            return interna^.nao()
        return self.comparacao()

    def comparacao(mut self) raises -> Expr:
        var esq = self.aritmetica()
        var t = self.atual()
        if t.tipo != TipoToken.SIMBOLO:
            return esq^
        var op = t.texto
        if op == "=":
            _ = self.avancar()
            return esq^.eq(self.aritmetica())
        if op == "<>" or op == "!=":
            _ = self.avancar()
            return esq^.ne(self.aritmetica())
        if op == ">":
            _ = self.avancar()
            return esq^.gt(self.aritmetica())
        if op == ">=":
            _ = self.avancar()
            return esq^.ge(self.aritmetica())
        if op == "<":
            _ = self.avancar()
            return esq^.lt(self.aritmetica())
        if op == "<=":
            _ = self.avancar()
            return esq^.le(self.aritmetica())
        return esq^

    def aritmetica(mut self) raises -> Expr:
        var e = self.termo()
        while self.eh_simbolo("+") or self.eh_simbolo("-"):
            var op = self.avancar().texto
            if op == "+":
                e = e^.mais(self.termo())
            else:
                e = e^.menos(self.termo())
        return e^

    def termo(mut self) raises -> Expr:
        var e = self.primario()
        while self.eh_simbolo("*") or self.eh_simbolo("/"):
            var op = self.avancar().texto
            if op == "*":
                e = e^.vezes(self.primario())
            else:
                e = e^.sobre(self.primario())
        return e^

    def primario(mut self) raises -> Expr:
        if self.aceitar_simbolo("("):
            var dentro = self.expressao()
            self.consumir_simbolo(")")
            return dentro^

        var t = self.atual()
        if t.tipo == TipoToken.NUMERO:
            _ = self.avancar()
            if "." in t.texto:
                return lit(atof(t.texto))
            return lit_int(atol(t.texto))
        if t.tipo == TipoToken.TEXTO:
            _ = self.avancar()
            return lit_texto(t.texto)
        if t.tipo == TipoToken.NOME:
            var up = _maiusculo(t.texto)
            if up == "TRUE":
                _ = self.avancar()
                return lit_bool(True)
            if up == "FALSE":
                _ = self.avancar()
                return lit_bool(False)
            _ = self.avancar()
            if self.modo_tendo and self.eh_simbolo("("):
                var ag = self._chamada_agregacao(t.texto)
                return coluna(self._saida_da_agg(ag^))
            return coluna(t.texto)
        var erro = self._erro("um valor ou nome de coluna")
        raise erro^


def _agregacao_de(nome: String, alvo: String) raises -> Agregacao:
    var f = _maiusculo(nome)
    if f == "SUM":
        return soma(alvo)
    if f == "AVG":
        return media(alvo)
    if f == "MIN":
        return minimo(alvo)
    if f == "MAX":
        return maximo(alvo)
    if f == "COUNT":
        if alvo == "*":
            return contar()
        return contar_de(alvo)
    raise Error(
        "SQL: funcao '" + nome + "' nao suportada"
        + " (use SUM, AVG, COUNT, COUNT(DISTINCT), MIN ou MAX)"
    )


def analisar(texto: String) raises -> ConsultaSQL:
    """Texto SQL -> descricao da consulta. Nao toca em dado nenhum."""
    var a = Analisador(tokenizar(texto))
    var c = ConsultaSQL()

    a.consumir_palavra("SELECT")

    # `DISTINCT` aqui e o modificador da selecao. O `DISTINCT` de dentro de
    # `COUNT(DISTINCT coluna)` e outro token, consumido pela chamada de
    # agregacao — nao ha ambiguidade porque este so vale colado no SELECT.
    if a.aceitar_palavra("DISTINCT"):
        c.distinto = True

    if a.aceitar_simbolo("*"):
        c.tudo = True
    else:
        while True:
            var t = a.atual()
            if t.tipo != TipoToken.NOME:
                var erro = a._erro("um nome de coluna ou funcao")
                raise erro^
            var nome = a.avancar().texto

            if a.eh_simbolo("("):
                var ag = a._chamada_agregacao(nome)
                var apelido = String("")
                if a.aceitar_palavra("AS"):
                    apelido = a.nome()
                    ag = ag^.como(apelido)
                var alvo = ag.coluna
                c.itens.append(ItemSelecao(True, alvo, ag^, apelido))
            else:
                var apelido = String("")
                if a.aceitar_palavra("AS"):
                    apelido = a.nome()
                c.itens.append(
                    ItemSelecao(False, nome, Agregacao(0, ""), apelido)
                )

            if not a.aceitar_simbolo(","):
                break

    a.consumir_palavra("FROM")
    var t = a.atual()
    if t.tipo != TipoToken.TEXTO and t.tipo != TipoToken.NOME:
        var erro = a._erro("um caminho entre aspas ou um nome de tabela")
        raise erro^
    c.fonte = a.avancar().texto

    if a.eh_palavra("RIGHT"):
        var erro = Error(
            "SQL: juncao a direita nao existe — inverta as tabelas ou use LEFT JOIN"
            + " na posicao " + String(a.atual().posicao)
        )
        raise erro^
    var tipo_j = String("")
    if a.aceitar_palavra("LEFT"):
        _ = a.aceitar_palavra("OUTER")
        a.consumir_palavra("JOIN")
        tipo_j = "esquerda"
    elif a.aceitar_palavra("INNER"):
        a.consumir_palavra("JOIN")
        tipo_j = "interno"
    elif a.aceitar_palavra("JOIN"):
        tipo_j = "interno"

    if tipo_j != "":
        var t2 = a.atual()
        if t2.tipo != TipoToken.TEXTO and t2.tipo != TipoToken.NOME:
            var erro = a._erro("um caminho entre aspas ou um nome de tabela")
            raise erro^
        c.fonte_dir = a.avancar().texto
        c.tem_juncao = True
        c.tipo_juncao = tipo_j
        if a.eh_palavra("ON"):
            var erro = Error(
                "SQL: juncao usa USING (coluna), nao ON expressao"
                + " — as chaves existem nos dois lados com o mesmo nome"
                + " na posicao " + String(a.atual().posicao)
            )
            raise erro^
        a.consumir_palavra("USING")
        a.consumir_simbolo("(")
        while True:
            c.chaves_juncao.append(a.nome())
            if not a.aceitar_simbolo(","):
                break
        a.consumir_simbolo(")")
        if len(c.chaves_juncao) == 0:
            var erro = Error("SQL: USING exige pelo menos uma coluna")
            raise erro^

    if a.aceitar_palavra("WHERE"):
        c.onde = a.expressao()
        c.tem_onde = True

    if a.aceitar_palavra("GROUP"):
        a.consumir_palavra("BY")
        while True:
            c.agrupar.append(a.nome())
            if not a.aceitar_simbolo(","):
                break

    if a.aceitar_palavra("HAVING"):
        a.modo_tendo = True
        a.itens_sel = List[ItemSelecao]()
        for item in c.itens:
            a.itens_sel.append(item.copy())
        c.tendo = a.expressao()
        c.tem_tendo = True
        for e in a.extras_tendo:
            c.extras_tendo.append(e.copy())
        a.modo_tendo = False

    if a.aceitar_palavra("ORDER"):
        a.consumir_palavra("BY")
        while True:
            c.ordenar.append(a.nome())
            if not a.aceitar_simbolo(","):
                break
        if a.aceitar_palavra("DESC"):
            c.descendente = True
        else:
            _ = a.aceitar_palavra("ASC")

    if a.aceitar_palavra("LIMIT"):
        var n = a.atual()
        if n.tipo != TipoToken.NUMERO:
            var erro = a._erro("um numero depois de LIMIT")
            raise erro^
        _ = a.avancar()
        c.limite = atol(n.texto)

    if a.atual().tipo != TipoToken.FIM:
        var erro = a._erro("o fim da consulta")
        raise erro^

    return c^
