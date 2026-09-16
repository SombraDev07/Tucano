"""Expression Engine M2 — árvore de expressão via arena de nós.

M2.5 acrescenta literais e extratores de data (`lit_data`, `ano`, `mes`, `dia`).
"""

from .datas import (
    parse_data_iso,
    data_para_texto,
    parse_datahora_iso,
    datahora_para_texto,
)


struct Kind:
    comptime COLUNA = 1
    comptime LIT_F64 = 2
    comptime LIT_I64 = 3
    comptime LIT_STR = 4
    comptime LIT_BOOL = 5
    comptime LIT_DATA = 6
    comptime LIT_DATAHORA = 7
    comptime GT = 10
    comptime GE = 11
    comptime LT = 12
    comptime LE = 13
    comptime EQ = 14
    comptime NE = 15
    comptime CONTEM = 16
    comptime AND = 20
    comptime OR = 21
    comptime NOT = 22
    comptime ADD = 30
    comptime SUB = 31
    comptime MUL = 32
    comptime DIV = 33
    comptime ANO = 40
    comptime MES = 41
    comptime DIA = 42
    comptime HORA = 43
    comptime MINUTO = 44
    comptime SEGUNDO = 45
    # transformacoes de texto: entram texto e saem texto
    comptime MINUSCULAS = 50
    comptime MAIUSCULAS = 51
    comptime APARAR = 52
    comptime SEM_ACENTO = 53
    comptime NORMALIZAR = 54
    comptime SEM_ESPACOS = 55


struct ExprNode(Copyable, Movable):
    var kind: Int
    var nome: String
    var f64: Float64
    var i64: Int64
    var texto: String
    var logico: Bool
    var left: Int
    var right: Int

    def __init__(out self, kind: Int):
        self.kind = kind
        self.nome = ""
        self.f64 = 0.0
        self.i64 = Int64(0)
        self.texto = ""
        self.logico = False
        self.left = -1
        self.right = -1


struct Expr(Copyable, Movable):
    """Handle para uma expressão (arena de nós + raiz)."""

    var nodes: List[ExprNode]
    var root: Int

    def __init__(out self):
        self.nodes = List[ExprNode]()
        self.root = -1

    def add(mut self, var node: ExprNode) -> Int:
        var i = len(self.nodes)
        self.nodes.append(node^)
        return i

    def vazia(self) -> Bool:
        return self.root < 0

    def descrever(self) raises -> String:
        if self.vazia():
            return "<vazia>"
        return _descrever_no(self, self.root)

    def gt(var self, var other: Expr) -> Expr:
        return _binario(Kind.GT, self^, other^)

    def ge(var self, var other: Expr) -> Expr:
        return _binario(Kind.GE, self^, other^)

    def lt(var self, var other: Expr) -> Expr:
        return _binario(Kind.LT, self^, other^)

    def le(var self, var other: Expr) -> Expr:
        return _binario(Kind.LE, self^, other^)

    def eq(var self, var other: Expr) -> Expr:
        return _binario(Kind.EQ, self^, other^)

    def ne(var self, var other: Expr) -> Expr:
        return _binario(Kind.NE, self^, other^)

    def em(var self, valores: List[Expr]) raises -> Expr:
        """Verdadeiro quando o valor e um dos da lista.

        Acucar sobre `eq` e `ou`: `cidade.em([lit_texto("SP"), lit_texto("RJ")])`
        vira `cidade == "SP" ou cidade == "RJ"`. Nao ha no novo na arvore, entao
        o otimizador, o pushdown para o Parquet e o caminho dicionarizado valem
        sem nenhuma linha a mais — cada `==` de coluna dicionarizada continua
        resolvendo o texto para um codigo uma vez so.

        Lista vazia e Falso para toda linha: "esta em nada" nao e verdade para
        ninguem. E o mesmo que o `IN ()` do SQL responderia.
        """
        if len(valores) == 0:
            return lit_bool(False)
        var out = self.copy().eq(valores[0].copy())
        for i in range(1, len(valores)):
            out = out^.ou(self.copy().eq(valores[i].copy()))
        return out^

    def contem(var self, var other: Expr) -> Expr:
        """Verdadeiro quando o texto da coluna contem o trecho.

        Filtrar texto por pedaco e das coisas que mais se faz com dado sujo, e
        era o que faltava para nao precisar sair da biblioteca: sem isto, achar
        as cidades que comecam com "São" exigia listar todas com `ou`.

        Ausente continua Desconhecido, como em qualquer comparacao. Trecho vazio
        casa com toda linha presente — e o que "contem nada" quer dizer, e e o
        que faz `contem` se comportar como as outras comparacoes na borda.
        """
        return _binario(Kind.CONTEM, self^, other^)

    def e(var self, var other: Expr) -> Expr:
        return _binario(Kind.AND, self^, other^)

    def ou(var self, var other: Expr) -> Expr:
        return _binario(Kind.OR, self^, other^)

    def nao(var self) -> Expr:
        return _unario(Kind.NOT, self^)

    def mais(var self, var other: Expr) -> Expr:
        return _binario(Kind.ADD, self^, other^)

    def menos(var self, var other: Expr) -> Expr:
        return _binario(Kind.SUB, self^, other^)

    def vezes(var self, var other: Expr) -> Expr:
        return _binario(Kind.MUL, self^, other^)

    def sobre(var self, var other: Expr) -> Expr:
        return _binario(Kind.DIV, self^, other^)


def _anexar(mut dest: Expr, src: Expr) -> Int:
    var base = len(dest.nodes)
    for node in src.nodes:
        var c = node.copy()
        if c.left >= 0:
            c.left += base
        if c.right >= 0:
            c.right += base
        _ = dest.add(c^)
    return base + src.root


def _binario(kind: Int, var left: Expr, var right: Expr) -> Expr:
    var out = Expr()
    var l = _anexar(out, left)
    var r = _anexar(out, right)
    var n = ExprNode(kind)
    n.left = l
    n.right = r
    out.root = out.add(n^)
    return out^


def _unario(kind: Int, var filho: Expr) -> Expr:
    var out = Expr()
    var f = _anexar(out, filho)
    var n = ExprNode(kind)
    n.left = f
    out.root = out.add(n^)
    return out^


def coluna(nome: String) -> Expr:
    var e = Expr()
    var n = ExprNode(Kind.COLUNA)
    n.nome = nome
    e.root = e.add(n^)
    return e^


def lit(valor: Float64) -> Expr:
    var e = Expr()
    var n = ExprNode(Kind.LIT_F64)
    n.f64 = valor
    e.root = e.add(n^)
    return e^


def lit_int(valor: Int) -> Expr:
    var e = Expr()
    var n = ExprNode(Kind.LIT_I64)
    n.i64 = Int64(valor)
    e.root = e.add(n^)
    return e^


def lit_texto(valor: String) -> Expr:
    var e = Expr()
    var n = ExprNode(Kind.LIT_STR)
    n.texto = valor
    e.root = e.add(n^)
    return e^


def lit_bool(valor: Bool) -> Expr:
    var e = Expr()
    var n = ExprNode(Kind.LIT_BOOL)
    n.logico = valor
    e.root = e.add(n^)
    return e^


def lit_data(texto: String) raises -> Expr:
    """Literal de data a partir de AAAA-MM-DD."""
    var e = Expr()
    var n = ExprNode(Kind.LIT_DATA)
    n.i64 = Int64(parse_data_iso(texto))
    e.root = e.add(n^)
    return e^


def lit_datahora(texto: String) raises -> Expr:
    """Literal de datahora a partir de ISO-8601."""
    var e = Expr()
    var n = ExprNode(Kind.LIT_DATAHORA)
    n.i64 = Int64(parse_datahora_iso(texto))
    e.root = e.add(n^)
    return e^


def hora(var alvo: Expr) -> Expr:
    """Extrai a hora (0..23) de uma expressao de datahora."""
    return _unario(Kind.HORA, alvo^)


def minuto(var alvo: Expr) -> Expr:
    """Extrai o minuto (0..59) de uma expressao de datahora."""
    return _unario(Kind.MINUTO, alvo^)


def segundo(var alvo: Expr) -> Expr:
    """Extrai o segundo (0..59) de uma expressao de datahora."""
    return _unario(Kind.SEGUNDO, alvo^)


def minusculas(var alvo: Expr) -> Expr:
    """Tudo em minuscula, inclusive vogal acentuada."""
    return _unario(Kind.MINUSCULAS, alvo^)


def maiusculas(var alvo: Expr) -> Expr:
    """Tudo em maiuscula, inclusive vogal acentuada."""
    return _unario(Kind.MAIUSCULAS, alvo^)


def aparar(var alvo: Expr) -> Expr:
    """Tira espaco das pontas e junta os do meio."""
    return _unario(Kind.APARAR, alvo^)


def sem_acento(var alvo: Expr) -> Expr:
    """Troca vogal acentuada pela sem acento, e cedilha por `c`."""
    return _unario(Kind.SEM_ACENTO, alvo^)


def sem_espacos(var alvo: Expr) -> Expr:
    """Tira todo espaco — chave de comparacao, nao texto para mostrar.

    `sem_espacos(normalizar(coluna("cidade")))` faz `"S  AO PAULO"`,
    `"São  Paulo"` e `"sao paulo"` virarem a mesma chave.
    """
    return _unario(Kind.SEM_ESPACOS, alvo^)


def normalizar(var alvo: Expr) -> Expr:
    """Aparar + minusculas + sem acento.

    E a padronizacao que se faz antes de agrupar ou juntar: `" São  PAULO "`,
    `"Sao Paulo"` e `"são paulo"` viram todos `"sao paulo"`, e o `agrupar` para
    de devolver tres grupos para a mesma cidade.
    """
    return _unario(Kind.NORMALIZAR, alvo^)


def ano(var alvo: Expr) -> Expr:
    """Extrai o ano de uma expressao de data."""
    return _unario(Kind.ANO, alvo^)


def mes(var alvo: Expr) -> Expr:
    """Extrai o mes (1..12) de uma expressao de data."""
    return _unario(Kind.MES, alvo^)


def dia(var alvo: Expr) -> Expr:
    """Extrai o dia do mes (1..31) de uma expressao de data."""
    return _unario(Kind.DIA, alvo^)


def _descrever_no(expr: Expr, i: Int) raises -> String:
    var n = expr.nodes[i].copy()
    var k = n.kind
    if k == Kind.COLUNA:
        return "coluna(" + n.nome + ")"
    if k == Kind.LIT_F64:
        return "lit(" + String(n.f64) + ")"
    if k == Kind.LIT_I64:
        return "lit(" + String(n.i64) + ")"
    if k == Kind.LIT_STR:
        return 'lit("' + n.texto + '")'
    if k == Kind.LIT_BOOL:
        if n.logico:
            return "lit(True)"
        return "lit(False)"
    if k == Kind.LIT_DATA:
        return 'lit_data("' + data_para_texto(Int(n.i64)) + '")'
    if k == Kind.LIT_DATAHORA:
        return 'lit_datahora("' + datahora_para_texto(Int(n.i64)) + '")'
    if k == Kind.NOT:
        return "nao(" + _descrever_no(expr, n.left) + ")"
    if k == Kind.MINUSCULAS:
        return "minusculas(" + _descrever_no(expr, n.left) + ")"
    if k == Kind.MAIUSCULAS:
        return "maiusculas(" + _descrever_no(expr, n.left) + ")"
    if k == Kind.APARAR:
        return "aparar(" + _descrever_no(expr, n.left) + ")"
    if k == Kind.SEM_ACENTO:
        return "sem_acento(" + _descrever_no(expr, n.left) + ")"
    if k == Kind.NORMALIZAR:
        return "normalizar(" + _descrever_no(expr, n.left) + ")"
    if k == Kind.SEM_ESPACOS:
        return "sem_espacos(" + _descrever_no(expr, n.left) + ")"
    if k == Kind.ANO:
        return "ano(" + _descrever_no(expr, n.left) + ")"
    if k == Kind.MES:
        return "mes(" + _descrever_no(expr, n.left) + ")"
    if k == Kind.DIA:
        return "dia(" + _descrever_no(expr, n.left) + ")"
    if k == Kind.HORA:
        return "hora(" + _descrever_no(expr, n.left) + ")"
    if k == Kind.MINUTO:
        return "minuto(" + _descrever_no(expr, n.left) + ")"
    if k == Kind.SEGUNDO:
        return "segundo(" + _descrever_no(expr, n.left) + ")"

    if n.left < 0 or n.right < 0:
        # chegou aqui um no que nao e binario, e ninguem acima o tratou.
        # Indexar `nodes[-1]` nao levanta em Mojo: **mata o processo**, e o
        # `try` de quem chamou nao pega. Foi assim que os verbos de texto novos
        # apareceram — como crash no `descrever`, nao como erro.
        raise Error(
            "expressao com no de tipo " + String(k)
            + " que `descrever` nao conhece"
        )

    var op = String("?")
    if k == Kind.GT:
        op = ">"
    elif k == Kind.GE:
        op = ">="
    elif k == Kind.LT:
        op = "<"
    elif k == Kind.LE:
        op = "<="
    elif k == Kind.EQ:
        op = "=="
    elif k == Kind.NE:
        op = "!="
    elif k == Kind.CONTEM:
        op = "contem"

    elif k == Kind.AND:
        op = "&"
    elif k == Kind.OR:
        op = "|"
    elif k == Kind.ADD:
        op = "+"
    elif k == Kind.SUB:
        op = "-"
    elif k == Kind.MUL:
        op = "*"
    elif k == Kind.DIV:
        op = "/"
    return (
        "("
        + _descrever_no(expr, n.left)
        + " "
        + op
        + " "
        + _descrever_no(expr, n.right)
        + ")"
    )
