"""Otimizador de planos (M8).

O plano logico diz **o que** o usuario quer. Nada nele obriga a executar naquela
ordem, e e essa folga que o otimizador aproveita.

Quatro regras, todas conservadoras — uma regra que as vezes muda o resultado nao
e otimizacao, e defeito:

1. **dobra de constantes** — `lit(2) * lit(3)` vira `lit(6)` uma vez, em vez de
   uma multiplicacao por linha;
2. **fusao de filtros** — filtros seguidos viram um `E`, numa passada so;
3. **empurrao de filtro** — o filtro sobe no plano, para que ordenacao e colunas
   derivadas trabalhem sobre menos linhas;
4. **poda de colunas** — o que o plano nao usa nao e lido. Sobre arquivo, isso
   vira menos I/O de verdade: as colunas nao pedidas nunca saem do disco.

`explicar()` mostra o plano antes, o plano depois e as regras que dispararam.
"""

from .expr import Expr, ExprNode, Kind, lit, lit_int, lit_bool
from .plano import Etapa, TipoEtapa
from .agregacao import Agregacao


# ------------------------------------------------------------ inspecao


def colunas_da_expr(expr: Expr, idx: Int, mut saida: List[String]) raises:
    if idx < 0 or expr.vazia():
        return
    var n = expr.nodes[idx].copy()
    if n.kind == Kind.COLUNA:
        for j in saida:
            if j == n.nome:
                return
        saida.append(n.nome)
        return
    colunas_da_expr(expr, n.left, saida)
    colunas_da_expr(expr, n.right, saida)


def _eh_literal_numerico(k: Int) -> Bool:
    return k == Kind.LIT_F64 or k == Kind.LIT_I64


def _valor_literal(n: ExprNode) -> Float64:
    if n.kind == Kind.LIT_F64:
        return n.f64
    return Float64(n.i64)


def _tudo_inteiro(a: ExprNode, b: ExprNode) -> Bool:
    return a.kind == Kind.LIT_I64 and b.kind == Kind.LIT_I64


def dobrar_constantes(expr: Expr) raises -> Expr:
    """Reduz subarvores sem coluna a um literal, uma vez em vez de por linha."""
    if expr.vazia():
        return expr.copy()
    return _dobrar(expr, expr.root)


def _dobrar(expr: Expr, idx: Int) raises -> Expr:
    var n = expr.nodes[idx].copy()
    var k = n.kind

    # folha: reconstroi isolada
    if n.left < 0 and n.right < 0:
        return _folha(n^)

    if n.right < 0:
        var filho = _dobrar(expr, n.left)
        if k == Kind.NOT:
            var f = filho.nodes[filho.root].copy()
            if f.kind == Kind.LIT_BOOL:
                return lit_bool(not f.logico)
        return _reconstruir_unario(k, filho^)

    var a = _dobrar(expr, n.left)
    var b = _dobrar(expr, n.right)
    var na = a.nodes[a.root].copy()
    var nb = b.nodes[b.root].copy()

    if _eh_literal_numerico(na.kind) and _eh_literal_numerico(nb.kind):
        var x = _valor_literal(na)
        var y = _valor_literal(nb)
        if k == Kind.ADD or k == Kind.SUB or k == Kind.MUL:
            var r: Float64
            if k == Kind.ADD:
                r = x + y
            elif k == Kind.SUB:
                r = x - y
            else:
                r = x * y
            if _tudo_inteiro(na, nb):
                return lit_int(Int(r))
            return lit(r)
        if k == Kind.DIV and y != 0.0:
            return lit(x / y)
        if k == Kind.GT:
            return lit_bool(x > y)
        if k == Kind.GE:
            return lit_bool(x >= y)
        if k == Kind.LT:
            return lit_bool(x < y)
        if k == Kind.LE:
            return lit_bool(x <= y)
        if k == Kind.EQ:
            return lit_bool(x == y)
        if k == Kind.NE:
            return lit_bool(x != y)

    if na.kind == Kind.LIT_BOOL and nb.kind == Kind.LIT_BOOL:
        if k == Kind.AND:
            return lit_bool(na.logico and nb.logico)
        if k == Kind.OR:
            return lit_bool(na.logico or nb.logico)

    return _reconstruir_binario(k, a^, b^)


def _folha(var n: ExprNode) -> Expr:
    var e = Expr()
    e.root = e.add(n^)
    return e^


def _reconstruir_unario(kind: Int, var filho: Expr) -> Expr:
    var out = Expr()
    var f = _copiar_para(out, filho)
    var n = ExprNode(kind)
    n.left = f
    out.root = out.add(n^)
    return out^


def _reconstruir_binario(kind: Int, var a: Expr, var b: Expr) -> Expr:
    var out = Expr()
    var l = _copiar_para(out, a)
    var r = _copiar_para(out, b)
    var n = ExprNode(kind)
    n.left = l
    n.right = r
    out.root = out.add(n^)
    return out^


def _copiar_para(mut dest: Expr, src: Expr) -> Int:
    var base = len(dest.nodes)
    for node in src.nodes:
        var c = node.copy()
        if c.left >= 0:
            c.left += base
        if c.right >= 0:
            c.right += base
        _ = dest.add(c^)
    return base + src.root


def _e_de(var a: Expr, var b: Expr) -> Expr:
    return _reconstruir_binario(Kind.AND, a^, b^)


# ------------------------------------------------------------- as regras


def mesclar_filtros(etapas: List[Etapa]) raises -> List[Etapa]:
    """Filtros seguidos viram um `E`: uma passada em vez de N."""
    var out = List[Etapa]()
    var i = 0
    while i < len(etapas):
        if etapas[i].tipo != TipoEtapa.FILTRO:
            out.append(etapas[i].copy())
            i += 1
            continue
        var acumulado = etapas[i].expr.copy()
        var j = i + 1
        while j < len(etapas) and etapas[j].tipo == TipoEtapa.FILTRO:
            acumulado = _e_de(acumulado^, etapas[j].expr.copy())
            j += 1
        out.append(Etapa.filtro(acumulado^))
        i = j
    return out^


def _filtro_pode_subir(filtro: Etapa, anterior: Etapa) raises -> Bool:
    """O filtro pode passar por cima da etapa anterior sem mudar o resultado?

    Conservador de proposito. Ordenacao e permutacao, entao filtrar antes ou
    depois da o mesmo. Coluna derivada so bloqueia se o filtro usar justamente a
    coluna criada. Agregacao, juncao, concatenacao e preenchimento **nunca**
    deixam passar: filtrar antes deles e outra pergunta, nao a mesma mais rapida.
    """
    if anterior.tipo == TipoEtapa.ORDENACAO:
        return True
    if anterior.tipo == TipoEtapa.PROJECAO:
        # a projecao so remove colunas; se o filtro sobrevive a ela, ele existia antes
        return True
    if anterior.tipo == TipoEtapa.COM_COLUNA:
        var usadas = List[String]()
        colunas_da_expr(filtro.expr, filtro.expr.root, usadas)
        for u in usadas:
            if u == anterior.nome:
                return False
        return True
    return False


def empurrar_filtros(etapas: List[Etapa]) raises -> List[Etapa]:
    """Sobe cada filtro enquanto for seguro. Ordena menos, deriva menos."""
    var out = List[Etapa]()
    for e in etapas:
        out.append(e.copy())

    var i = 0
    while i < len(out):
        if out[i].tipo != TipoEtapa.FILTRO:
            i += 1
            continue
        var j = i
        while j > 0 and _filtro_pode_subir(out[j], out[j - 1]):
            var a = out[j - 1].copy()
            var b = out[j].copy()
            out[j - 1] = b^
            out[j] = a^
            j -= 1
        i += 1
    return out^


def colunas_do_plano(
    etapas: List[Etapa], nomes_fonte: List[String]
) raises -> List[String]:
    """Colunas que o plano realmente usa.

    Caminha de tras para frente: comeca pelo que a ultima etapa produz e vai
    acrescentando o que cada etapa anterior precisa ler. Devolve a lista vazia
    quando nao da para podar — quando a saida e "todas as colunas".
    """
    var necessarias = List[String]()
    var define_saida = False

    var i = len(etapas) - 1
    while i >= 0:
        ref e = etapas[i]

        if e.tipo == TipoEtapa.PROJECAO and not define_saida:
            for n in e.nomes:
                _acrescentar(necessarias, n)
            define_saida = True

        elif e.tipo == TipoEtapa.AGREGACAO:
            if not define_saida:
                define_saida = True
                necessarias = List[String]()
            for n in e.nomes:
                _acrescentar(necessarias, n)
            for a in e.agregacoes:
                if a.coluna != "":
                    _acrescentar(necessarias, a.coluna)

        elif e.tipo == TipoEtapa.COM_COLUNA:
            _remover(necessarias, e.nome)
            var usadas = List[String]()
            colunas_da_expr(e.expr, e.expr.root, usadas)
            for u in usadas:
                _acrescentar(necessarias, u)

        elif e.tipo == TipoEtapa.FILTRO or e.tipo == TipoEtapa.PREENCHER_NA:
            var usadas = List[String]()
            colunas_da_expr(e.expr, e.expr.root, usadas)
            for u in usadas:
                _acrescentar(necessarias, u)
            if e.tipo == TipoEtapa.PREENCHER_NA:
                _acrescentar(necessarias, e.nome)

        elif e.tipo == TipoEtapa.ORDENACAO or e.tipo == TipoEtapa.JUNCAO:
            for n in e.nomes:
                _acrescentar(necessarias, n)
            if e.tipo == TipoEtapa.JUNCAO:
                # a juncao traz colunas do outro lado: nao da para podar aqui
                return List[String]()

        elif e.tipo == TipoEtapa.REMOVER_NA:
            if len(e.nomes) == 0:
                return List[String]()  # olha todas as colunas
            for n in e.nomes:
                _acrescentar(necessarias, n)

        elif e.tipo == TipoEtapa.CONCATENACAO:
            return List[String]()

        i -= 1

    if not define_saida:
        return List[String]()

    # ordem estavel: segue a ordem da fonte
    var out = List[String]()
    for n in nomes_fonte:
        for k in necessarias:
            if k == n:
                out.append(n)
    return out^


def _acrescentar(mut lista: List[String], nome: String):
    for x in lista:
        if x == nome:
            return
    lista.append(nome)


def _remover(mut lista: List[String], nome: String):
    var out = List[String]()
    for x in lista:
        if x != nome:
            out.append(x)
    lista = out^


# ------------------------------------------------------------- pipeline


struct PlanoOtimizado(Movable):
    var etapas: List[Etapa]
    var colunas_lidas: List[String]
    var regras: List[String]

    def __init__(
        out self,
        var etapas: List[Etapa],
        var colunas_lidas: List[String],
        var regras: List[String],
    ):
        self.etapas = etapas^
        self.colunas_lidas = colunas_lidas^
        self.regras = regras^


def otimizar(
    etapas: List[Etapa], nomes_fonte: List[String]
) raises -> PlanoOtimizado:
    var regras = List[String]()

    var dobradas = List[Etapa]()
    var mudou_dobra = False
    for e in etapas:
        if e.expr.vazia():
            dobradas.append(e.copy())
            continue
        var antes = e.expr.descrever()
        var nova = dobrar_constantes(e.expr)
        if nova.descrever() != antes:
            mudou_dobra = True
        var copia = e.copy()
        copia.expr = nova^
        dobradas.append(copia^)
    if mudou_dobra:
        regras.append("dobra de constantes")

    var n_filtros_antes = 0
    for e in dobradas:
        if e.tipo == TipoEtapa.FILTRO:
            n_filtros_antes += 1
    var fundidas = mesclar_filtros(dobradas)
    var n_filtros_depois = 0
    for e in fundidas:
        if e.tipo == TipoEtapa.FILTRO:
            n_filtros_depois += 1
    if n_filtros_depois < n_filtros_antes:
        regras.append(
            "fusao de filtros (" + String(n_filtros_antes) + " -> "
            + String(n_filtros_depois) + ")"
        )

    var ordem_antes = String("")
    for e in fundidas:
        ordem_antes += String(e.tipo) + ","
    var empurradas = empurrar_filtros(fundidas)
    var ordem_depois = String("")
    for e in empurradas:
        ordem_depois += String(e.tipo) + ","
    if ordem_depois != ordem_antes:
        regras.append("empurrao de filtro")

    var colunas = colunas_do_plano(empurradas, nomes_fonte)
    if len(colunas) > 0 and len(colunas) < len(nomes_fonte):
        regras.append(
            "poda de colunas (" + String(len(nomes_fonte)) + " -> "
            + String(len(colunas)) + ")"
        )

    return PlanoOtimizado(empurradas^, colunas^, regras^)


def filtro_do_scan(etapas: List[Etapa]) raises -> Expr:
    """Predicado que o scan Parquet pode usar para pular row group.

    So os filtros que o otimizador deixou no comeco do plano: os que usam
    coluna derivada ou vêm depois de agregacao ficam para o executor.
    """
    var acc = Expr()
    for e in etapas:
        if e.tipo != TipoEtapa.FILTRO:
            break
        if acc.vazia():
            acc = e.expr.copy()
        else:
            acc = _e_de(acc^, e.expr.copy())
    return acc^
