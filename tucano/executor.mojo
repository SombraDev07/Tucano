"""Executor fisico M3 — avaliacao coluna-a-coluna.

O M2 avaliava expressao linha a linha e, para cada linha, buscava a coluna na
`Tabela` — que fazia busca linear e devolvia uma copia profunda do slab. Custo
quadratico no volume de dados.

Aqui cada coluna referenciada e lida **uma vez** para um `Vetor` contiguo, e todo
o resto opera sobre esse vetor. Os lacos internos ja tem a forma que o M4 precisa
para virar kernel SIMD: `List[Float64]` contiguo, mascara separada, e o tipo de
operacao decidido *fora* do laco.
"""

from .coluna import Coluna
from .erros import erro_coluna
from .schema import Campo
from .expr import Expr, ExprNode, Kind
from .dtype import DType
from .vetor import Vetor
from .plano import Etapa, TipoEtapa
from .datas import civil_de_dias


# ------------------------------------------------------------------- lote
#
# O executor opera sobre um **lote**: uma lista de colunas alinhadas. Ele nao
# conhece `Tabela`. Essa e a separacao logico/fisico do M3 — e a forma que o M6
# precisa, quando join e groupby passarem lotes entre operadores.


def n_linhas(cols: List[Coluna]) -> Int:
    if len(cols) == 0:
        return 0
    return cols[0].tamanho()


def nomes_do_lote(cols: List[Coluna]) -> List[String]:
    var out = List[String]()
    for c in cols:
        out.append(c.nome)
    return out^


def posicao_no_lote(cols: List[Coluna], nome: String) raises -> Int:
    for i in range(len(cols)):
        if cols[i].nome == nome:
            return i
    raise erro_coluna(nome, nomes_do_lote(cols))


def pegar_do_lote(cols: List[Coluna], nome: String) raises -> Coluna:
    return cols[posicao_no_lote(cols, nome)].copy()


def dtype_do_lote(cols: List[Coluna], nome: String) raises -> Int:
    return cols[posicao_no_lote(cols, nome)].tipo


def copiar_lote(cols: List[Coluna]) -> List[Coluna]:
    var out = List[Coluna]()
    for c in cols:
        out.append(c.copy())
    return out^


# ----------------------------------------------------------------- esquema
#
# O planejador raciocina sobre **esquema** (nome + tipo), nao sobre dados. E o
# que permite tipar e avisar sem executar — e o que o otimizador do M8 vai usar
# para empurrar filtro e projecao.


def esquema_do_lote(cols: List[Coluna]) -> List[Campo]:
    var out = List[Campo]()
    for c in cols:
        out.append(Campo(c.nome, c.dtype()))
    return out^


def nomes_do_esquema(esq: List[Campo]) -> List[String]:
    var out = List[String]()
    for c in esq:
        out.append(c.nome)
    return out^


def tipo_no_esquema(esq: List[Campo], nome: String) raises -> Int:
    for c in esq:
        if c.nome == nome:
            return c.dtype.codigo
    raise erro_coluna(nome, nomes_do_esquema(esq))


def projetar_esquema(esq: List[Campo], nomes: List[String]) raises -> List[Campo]:
    var out = List[Campo]()
    for nome in nomes:
        out.append(Campo(nome, DType(tipo_no_esquema(esq, nome))))
    return out^


def com_coluna_esquema(esq: List[Campo], nome: String, tipo: Int) -> List[Campo]:
    var out = List[Campo]()
    var substituiu = False
    for c in esq:
        if c.nome == nome:
            out.append(Campo(nome, DType(tipo)))
            substituiu = True
        else:
            out.append(c.copy())
    if not substituiu:
        out.append(Campo(nome, DType(tipo)))
    return out^


def esquema_apos(esq: List[Campo], etapas: List[Etapa]) raises -> List[Campo]:
    """Esquema do resultado, calculado sem executar nada."""
    var atual = esq.copy()
    for e in etapas:
        if e.tipo == TipoEtapa.PROJECAO:
            atual = projetar_esquema(atual, e.nomes)
        elif e.tipo == TipoEtapa.COM_COLUNA:
            atual = com_coluna_esquema(
                atual, e.nome, tipo_resultado(e.expr, e.expr.root, atual)
            )
    return atual^


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


def _lista_tri(n: Int, valor: Int) -> List[Int]:
    var out = List[Int](capacity=n)
    for _ in range(n):
        out.append(valor)
    return out^


# --------------------------------------------------------------- leitura


def extrair_coluna(cols: List[Coluna], nome: String) raises -> Vetor:
    """Le a coluna UMA vez para um vetor contiguo.

    Este e o ponto que elimina a divida quadratica do M2: a copia acontece por
    referencia de coluna na expressao, nao por linha.
    """
    ref col = cols[posicao_no_lote(cols, nome)]
    var n = col.tamanho()

    if col.tipo == DType.TEXTO:
        var vt = Vetor.textual(n)
        for i in range(n):
            if col.eh_ausente(i):
                vt.na[i] = True
            else:
                vt.textos[i] = col.textos.get(i)
        return vt^

    var v = Vetor.numerico(n)
    if col.tipo == DType.REAL:
        for i in range(n):
            if col.eh_ausente(i):
                v.na[i] = True
            else:
                v.reais[i] = col.reals[i]
    elif col.tipo == DType.INTEIRO or col.tipo == DType.DATA:
        for i in range(n):
            if col.eh_ausente(i):
                v.na[i] = True
            else:
                v.reais[i] = Float64(col.ints[i])
    elif col.tipo == DType.LOGICO:
        for i in range(n):
            if col.eh_ausente(i):
                v.na[i] = True
            else:
                v.reais[i] = Float64(Int(col.logics[i]))
    else:
        raise Error("tipo de coluna nao suportado em expressao: " + nome)
    return v^


# ------------------------------------------------------- avaliacao de valor


def avaliar(expr: Expr, cols: List[Coluna]) raises -> Vetor:
    """Avalia a expressao sobre a tabela inteira, devolvendo uma coluna."""
    if expr.vazia():
        raise Error("expressao vazia")
    return _avaliar_no(expr, expr.root, cols)


def _avaliar_no(expr: Expr, idx: Int, cols: List[Coluna]) raises -> Vetor:
    var n = expr.nodes[idx].copy()
    var linhas = n_linhas(cols)
    var k = n.kind

    if k == Kind.COLUNA:
        return extrair_coluna(cols, n.nome)
    if k == Kind.LIT_F64:
        return Vetor.constante_numerica(linhas, n.f64)
    if k == Kind.LIT_I64 or k == Kind.LIT_DATA:
        return Vetor.constante_numerica(linhas, Float64(n.i64))
    if k == Kind.LIT_BOOL:
        if n.logico:
            return Vetor.constante_numerica(linhas, 1.0)
        return Vetor.constante_numerica(linhas, 0.0)
    if k == Kind.LIT_STR:
        return Vetor.constante_textual(linhas, n.texto)

    if k == Kind.ANO or k == Kind.MES or k == Kind.DIA:
        var filho = _avaliar_no(expr, n.left, cols)
        if filho.eh_texto:
            raise Error("extrator de data exige expressao de data")
        var v = Vetor.numerico(linhas)
        if k == Kind.ANO:
            for i in range(linhas):
                if filho.na[i]:
                    v.na[i] = True
                else:
                    v.reais[i] = Float64(civil_de_dias(Int(filho.reais[i])).ano)
        elif k == Kind.MES:
            for i in range(linhas):
                if filho.na[i]:
                    v.na[i] = True
                else:
                    v.reais[i] = Float64(civil_de_dias(Int(filho.reais[i])).mes)
        else:
            for i in range(linhas):
                if filho.na[i]:
                    v.na[i] = True
                else:
                    v.reais[i] = Float64(civil_de_dias(Int(filho.reais[i])).dia)
        return v^

    if k == Kind.ADD or k == Kind.SUB or k == Kind.MUL or k == Kind.DIV:
        var a = _avaliar_no(expr, n.left, cols)
        var b = _avaliar_no(expr, n.right, cols)
        if a.eh_texto or b.eh_texto:
            raise Error("aritmetica sobre coluna de texto")
        var v = Vetor.numerico(linhas)
        # o tipo da operacao e decidido FORA do laco: forma que o M4 vetoriza
        if k == Kind.ADD:
            for i in range(linhas):
                if a.na[i] or b.na[i]:
                    v.na[i] = True
                else:
                    v.reais[i] = a.reais[i] + b.reais[i]
        elif k == Kind.SUB:
            for i in range(linhas):
                if a.na[i] or b.na[i]:
                    v.na[i] = True
                else:
                    v.reais[i] = a.reais[i] - b.reais[i]
        elif k == Kind.MUL:
            for i in range(linhas):
                if a.na[i] or b.na[i]:
                    v.na[i] = True
                else:
                    v.reais[i] = a.reais[i] * b.reais[i]
        else:
            for i in range(linhas):
                if a.na[i] or b.na[i]:
                    v.na[i] = True
                else:
                    v.reais[i] = a.reais[i] / b.reais[i]
        return v^

    raise Error("no de expressao nao avaliavel como valor: kind " + String(k))


# ------------------------------------------------------- logica de 3 valores


def avaliar_tri(expr: Expr, cols: List[Coluna]) raises -> List[Int]:
    """Mascara de tres valores para a tabela inteira."""
    if expr.vazia():
        raise Error("expressao vazia")
    return _tri_no(expr, expr.root, cols)


def _tri_no(expr: Expr, idx: Int, cols: List[Coluna]) raises -> List[Int]:
    var n = expr.nodes[idx].copy()
    var linhas = n_linhas(cols)
    var k = n.kind

    if k == Kind.LIT_BOOL:
        return _lista_tri(linhas, _de_bool(n.logico))

    if k == Kind.COLUNA:
        if dtype_do_lote(cols, n.nome) != DType.LOGICO:
            raise Error(
                "coluna nao logica usada como predicado: "
                + n.nome
                + " (use uma comparacao)"
            )
        ref col = cols[posicao_no_lote(cols, n.nome)]
        var out = List[Int](capacity=linhas)
        for i in range(linhas):
            if col.eh_ausente(i):
                out.append(Tri.DESCONHECIDO)
            else:
                out.append(_de_bool(Int(col.logics[i]) != 0))
        return out^

    if k == Kind.NOT:
        var filho = _tri_no(expr, n.left, cols)
        var out = List[Int](capacity=linhas)
        for i in range(linhas):
            if filho[i] == Tri.DESCONHECIDO:
                out.append(Tri.DESCONHECIDO)
            elif filho[i] == Tri.VERDADEIRO:
                out.append(Tri.FALSO)
            else:
                out.append(Tri.VERDADEIRO)
        return out^

    if k == Kind.AND or k == Kind.OR:
        var a = _tri_no(expr, n.left, cols)
        var b = _tri_no(expr, n.right, cols)
        var out = List[Int](capacity=linhas)
        if k == Kind.AND:
            for i in range(linhas):
                if a[i] == Tri.FALSO or b[i] == Tri.FALSO:
                    out.append(Tri.FALSO)
                elif a[i] == Tri.DESCONHECIDO or b[i] == Tri.DESCONHECIDO:
                    out.append(Tri.DESCONHECIDO)
                else:
                    out.append(Tri.VERDADEIRO)
        else:
            for i in range(linhas):
                if a[i] == Tri.VERDADEIRO or b[i] == Tri.VERDADEIRO:
                    out.append(Tri.VERDADEIRO)
                elif a[i] == Tri.DESCONHECIDO or b[i] == Tri.DESCONHECIDO:
                    out.append(Tri.DESCONHECIDO)
                else:
                    out.append(Tri.FALSO)
        return out^

    if (
        k == Kind.GT
        or k == Kind.GE
        or k == Kind.LT
        or k == Kind.LE
        or k == Kind.EQ
        or k == Kind.NE
    ):
        var a = _avaliar_no(expr, n.left, cols)
        var b = _avaliar_no(expr, n.right, cols)
        if a.eh_texto != b.eh_texto:
            # Decisao 4: nada de coercao silenciosa entre texto e numero
            raise Error(
                "comparacao entre texto e numero em "
                + expr.descrever()
                + " — converta explicitamente"
            )
        var out = List[Int](capacity=linhas)
        if a.eh_texto:
            for i in range(linhas):
                if a.na[i] or b.na[i]:
                    out.append(Tri.DESCONHECIDO)
                else:
                    out.append(_de_bool(_cmp_texto(k, a.textos[i], b.textos[i])))
        else:
            for i in range(linhas):
                if a.na[i] or b.na[i]:
                    out.append(Tri.DESCONHECIDO)
                else:
                    out.append(_de_bool(_cmp_num(k, a.reais[i], b.reais[i])))
        return out^

    raise Error("expressao de filtro nao booleana")


def _cmp_num(k: Int, a: Float64, b: Float64) -> Bool:
    if k == Kind.GT:
        return a > b
    if k == Kind.GE:
        return a >= b
    if k == Kind.LT:
        return a < b
    if k == Kind.LE:
        return a <= b
    if k == Kind.EQ:
        return a == b
    return a != b


def _cmp_texto(k: Int, a: String, b: String) -> Bool:
    if k == Kind.GT:
        return a > b
    if k == Kind.GE:
        return a >= b
    if k == Kind.LT:
        return a < b
    if k == Kind.LE:
        return a <= b
    if k == Kind.EQ:
        return a == b
    return a != b


# ------------------------------------------------------------ tipo do resultado


def _num_kind(codigo: Int) -> Int:
    """Data conta como inteiro para efeito de aritmetica (dias)."""
    if codigo == DType.DATA:
        return DType.INTEIRO
    return codigo


def tipo_resultado(expr: Expr, idx: Int, esq: List[Campo]) raises -> Int:
    """Tipo da coluna que a expressao produz. Sem coercao silenciosa.

    Trabalha sobre esquema: nao precisa dos dados.
    """
    var n = expr.nodes[idx].copy()
    var k = n.kind

    if k == Kind.COLUNA:
        return tipo_no_esquema(esq, n.nome)
    if k == Kind.LIT_F64:
        return DType.REAL
    if k == Kind.LIT_I64:
        return DType.INTEIRO
    if k == Kind.LIT_DATA:
        return DType.DATA
    if k == Kind.LIT_STR:
        return DType.TEXTO
    if k == Kind.LIT_BOOL:
        return DType.LOGICO
    if k == Kind.ANO or k == Kind.MES or k == Kind.DIA:
        return DType.INTEIRO
    if k == Kind.DIV:
        return DType.REAL
    if k == Kind.ADD or k == Kind.SUB or k == Kind.MUL:
        var a = _num_kind(tipo_resultado(expr, n.left, esq))
        var b = _num_kind(tipo_resultado(expr, n.right, esq))
        if a == DType.INTEIRO and b == DType.INTEIRO:
            return DType.INTEIRO
        return DType.REAL
    return DType.LOGICO


def vetor_para_coluna(nome: String, v: Vetor, tipo: Int) raises -> Coluna:
    var n = v.tamanho()
    var aus = List[Bool](capacity=n)
    for i in range(n):
        aus.append(v.na[i])

    if tipo == DType.TEXTO:
        var textos = List[String](capacity=n)
        for i in range(n):
            textos.append(v.textos[i])
        return Coluna.de_textos(nome, textos^, aus^)

    if tipo == DType.INTEIRO or tipo == DType.DATA:
        var vals = List[Int64](capacity=n)
        for i in range(n):
            vals.append(Int64(Int(v.reais[i])))
        if tipo == DType.DATA:
            return Coluna.de_datas(nome, vals^, aus^)
        return Coluna.de_inteiros(nome, vals^, aus^)

    if tipo == DType.LOGICO:
        var vals = List[Bool](capacity=n)
        for i in range(n):
            vals.append(v.reais[i] != 0.0)
        return Coluna.de_logicos(nome, vals^, aus^)

    var vals = List[Float64](capacity=n)
    for i in range(n):
        vals.append(v.reais[i])
    return Coluna.de_reais(nome, vals^, aus^)


# ------------------------------------------------------------ operadores fisicos


def filtrar_coluna(col: Coluna, keep: List[Bool]) raises -> Coluna:
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


def op_filtro(cols: List[Coluna], pred: Expr) raises -> List[Coluna]:
    """FilterExec: mascara de tres valores -> selecao. So Verdadeiro passa."""
    var mascara = avaliar_tri(pred, cols)
    var keep = List[Bool](capacity=len(mascara))
    for m in mascara:
        keep.append(m == Tri.VERDADEIRO)

    var out = List[Coluna]()
    for c in cols:
        out.append(filtrar_coluna(c, keep))
    return out^


def op_projecao(cols: List[Coluna], nomes: List[String]) raises -> List[Coluna]:
    """ProjectionExec."""
    if len(nomes) == 0:
        raise Error("projecao exige pelo menos um nome")
    var out = List[Coluna]()
    for nome in nomes:
        out.append(pegar_do_lote(cols, nome))
    return out^


def op_com_coluna(
    cols: List[Coluna], nome: String, expr: Expr
) raises -> List[Coluna]:
    """ExpressionExec: avalia a expressao e materializa a coluna nova.

    Substitui a coluna se o nome ja existir — o `df['x'] = ...` do pandas.
    """
    var v = avaliar(expr, cols)
    var tipo = tipo_resultado(expr, expr.root, esquema_do_lote(cols))
    var nova = vetor_para_coluna(nome, v, tipo)

    var out = List[Coluna]()
    var substituiu = False
    for c in cols:
        if c.nome == nome:
            out.append(nova.copy())
            substituiu = True
        else:
            out.append(c.copy())
    if not substituiu:
        out.append(nova^)
    return out^


def executar(cols: List[Coluna], etapas: List[Etapa]) raises -> List[Coluna]:
    """Aplica o plano fisico, etapa por etapa, materializando entre elas."""
    var atual = copiar_lote(cols)
    for e in etapas:
        if e.tipo == TipoEtapa.FILTRO:
            atual = op_filtro(atual, e.expr)
        elif e.tipo == TipoEtapa.PROJECAO:
            atual = op_projecao(atual, e.nomes)
        elif e.tipo == TipoEtapa.COM_COLUNA:
            atual = op_com_coluna(atual, e.nome, e.expr)
        else:
            raise Error("etapa desconhecida no plano: " + String(e.tipo))
    return atual^


# ---------------------------------------------------------------- avisos


def avisos_expr(
    expr: Expr, idx: Int, esq: List[Campo], mut saida: List[String]
) raises:
    """Marca os nos que nao terao kernel vetorizado no M4.

    O pandas nunca avisa que voce caiu do caminho rapido. Aqui avisa.
    """
    if idx < 0:
        return
    var n = expr.nodes[idx].copy()
    var k = n.kind

    if k == Kind.COLUNA:
        if tipo_no_esquema(esq, n.nome) == DType.TEXTO:
            saida.append(
                "coluna de texto '"
                + n.nome
                + "': comparacao escalar byte a byte (dictionary encoding no M4)"
            )
        return
    if k == Kind.ANO or k == Kind.MES or k == Kind.DIA:
        saida.append("extrator de data: caminho escalar (kernel de calendario no M4)")

    avisos_expr(expr, n.left, esq, saida)
    avisos_expr(expr, n.right, esq, saida)


def avisos_plano(cols: List[Coluna], etapas: List[Etapa]) raises -> List[String]:
    """Avisos do plano inteiro, propagando o esquema entre as etapas.

    Sem propagar, um `onde` sobre coluna criada por um `com_coluna` anterior
    referenciaria um nome que ainda nao existe na fonte.
    """
    var esq = esquema_do_lote(cols)
    var saida = List[String]()
    for e in etapas:
        if e.tipo == TipoEtapa.PROJECAO:
            esq = projetar_esquema(esq, e.nomes)
        else:
            avisos_expr(e.expr, e.expr.root, esq, saida)
            if e.tipo == TipoEtapa.COM_COLUNA:
                esq = com_coluna_esquema(
                    esq, e.nome, tipo_resultado(e.expr, e.expr.root, esq)
                )
    return saida^
