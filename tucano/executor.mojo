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
from .vetor import Vetor, Unidade
from .plano import Etapa, TipoEtapa
from .kernels import (
    contar_marcados,
    add_f64,
    sub_f64,
    mul_f64,
    div_f64,
    ou_na,
    cmp_f64,
    cmp_i32,
    tri_e,
    tri_ou,
    tri_nao,
    tri_para_keep,
    calendario_f64,
    micros_para_dias,
    relogio_f64,
)


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
    """Valor logico de tres estados, na ordem do reticulado de Kleene.

    Comparar com ausente nao da Falso: da Desconhecido. `onde()` mantem apenas
    Verdadeiro, entao a linha ausente e descartada com ou sem negacao.

        FALSO = 0  <  DESCONHECIDO = 1  <  VERDADEIRO = 2

    A ordem nao e arbitraria: com ela `E` e `min`, `OU` e `max` e `NAO` e
    `2 - x`. Cada conectivo vira uma unica instrucao SIMD (M4).
    """

    comptime FALSO = 0
    comptime DESCONHECIDO = 1
    comptime VERDADEIRO = 2


def _de_bool(b: Bool) -> UInt8:
    if b:
        return UInt8(Tri.VERDADEIRO)
    return UInt8(Tri.FALSO)


def _lista_tri(n: Int, valor: UInt8) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for _ in range(n):
        out.append(valor)
    return out^


def _zeros_u8(n: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for _ in range(n):
        out.append(UInt8(0))
    return out^


# --------------------------------------------------------------- leitura


def extrair_coluna(cols: List[Coluna], nome: String) raises -> Vetor:
    """Le a coluna UMA vez para um vetor contiguo.

    Este e o ponto que elimina a divida quadratica do M2: a copia acontece por
    referencia de coluna na expressao, nao por linha.
    """
    ref col = cols[posicao_no_lote(cols, nome)]
    var n = col.tamanho()
    # bitmap -> bytes de uma vez; o laco de valores fica sem extracao de bit
    var na = col.validity_bits.para_bytes()

    if col.tipo == DType.TEXTO:
        var vt = Vetor.textual(n)
        vt.na = na^
        for i in range(n):
            if vt.na[i] == 0:
                vt.textos[i] = col.texto_bruto(i)
        return vt^

    var v = Vetor.numerico(n)
    v.na = na^
    if col.tipo == DType.DATA:
        v.unidade = Unidade.DIAS
    elif col.tipo == DType.DATAHORA:
        v.unidade = Unidade.MICROS
    if col.tipo == DType.REAL:
        for i in range(n):
            v.reais[i] = col.reals[i]
    elif (
        col.tipo == DType.INTEIRO
        or col.tipo == DType.DATA
        or col.tipo == DType.DATAHORA
    ):
        for i in range(n):
            v.reais[i] = Float64(col.ints[i])
    elif col.tipo == DType.LOGICO:
        for i in range(n):
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
    if k == Kind.LIT_I64:
        return Vetor.constante_numerica(linhas, Float64(n.i64))
    if k == Kind.LIT_DATA:
        var vd = Vetor.constante_numerica(linhas, Float64(n.i64))
        vd.unidade = Unidade.DIAS
        return vd^
    if k == Kind.LIT_DATAHORA:
        var vh = Vetor.constante_numerica(linhas, Float64(n.i64))
        vh.unidade = Unidade.MICROS
        return vh^
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
        v.na = filho.na.copy()
        var comp = 0  # ano
        if k == Kind.MES:
            comp = 1
        elif k == Kind.DIA:
            comp = 2
        if filho.unidade == Unidade.MICROS:
            # datahora: converte para dias antes do kernel de calendario
            var dias = Vetor.numerico(linhas)
            micros_para_dias(filho.reais, dias.reais, linhas)
            calendario_f64(comp, dias.reais, v.reais, linhas)
        else:
            calendario_f64(comp, filho.reais, v.reais, linhas)
        return v^

    if k == Kind.HORA or k == Kind.MINUTO or k == Kind.SEGUNDO:
        var filho = _avaliar_no(expr, n.left, cols)
        if filho.eh_texto or filho.unidade != Unidade.MICROS:
            raise Error(
                "hora/minuto/segundo exigem expressao de datahora"
                + " (uma coluna `data` nao guarda hora)"
            )
        var v = Vetor.numerico(linhas)
        v.na = filho.na.copy()
        var comp = 0  # hora
        if k == Kind.MINUTO:
            comp = 1
        elif k == Kind.SEGUNDO:
            comp = 2
        relogio_f64(comp, filho.reais, v.reais, linhas)
        return v^

    if k == Kind.ADD or k == Kind.SUB or k == Kind.MUL or k == Kind.DIV:
        var a = _avaliar_no(expr, n.left, cols)
        var b = _avaliar_no(expr, n.right, cols)
        if a.eh_texto or b.eh_texto:
            raise Error("aritmetica sobre coluna de texto")
        var v = Vetor.numerico(linhas)
        # `data + 7` continua sendo data: a unidade acompanha o operando que a tem
        if a.unidade != Unidade.NUMERO:
            v.unidade = a.unidade
        else:
            v.unidade = b.unidade
        # kernel SIMD, com o tipo da operacao decidido FORA do laco
        ou_na(a.na, b.na, v.na, linhas)
        if k == Kind.ADD:
            add_f64(a.reais, b.reais, v.reais, linhas)
        elif k == Kind.SUB:
            sub_f64(a.reais, b.reais, v.reais, linhas)
        elif k == Kind.MUL:
            mul_f64(a.reais, b.reais, v.reais, linhas)
        else:
            div_f64(a.reais, b.reais, v.reais, linhas)
        return v^

    raise Error("no de expressao nao avaliavel como valor: kind " + String(k))


# ------------------------------------------------------- logica de 3 valores


def avaliar_tri(expr: Expr, cols: List[Coluna]) raises -> List[UInt8]:
    """Mascara de tres valores para a tabela inteira."""
    if expr.vazia():
        raise Error("expressao vazia")
    return _tri_no(expr, expr.root, cols)


def _tri_no(expr: Expr, idx: Int, cols: List[Coluna]) raises -> List[UInt8]:
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
        var na = col.validity_bits.para_bytes()
        var out = List[UInt8](capacity=linhas)
        for i in range(linhas):
            if na[i] != 0:
                out.append(UInt8(Tri.DESCONHECIDO))
            else:
                out.append(_de_bool(Int(col.logics[i]) != 0))
        return out^

    if k == Kind.NOT:
        var filho = _tri_no(expr, n.left, cols)
        var out = _zeros_u8(linhas)
        tri_nao(filho, out, linhas)  # NAO de Kleene = 2 - x
        return out^

    if k == Kind.AND or k == Kind.OR:
        var a = _tri_no(expr, n.left, cols)
        var b = _tri_no(expr, n.right, cols)
        var out = _zeros_u8(linhas)
        if k == Kind.AND:
            tri_e(a, b, out, linhas)  # E de Kleene = min
        else:
            tri_ou(a, b, out, linhas)  # OU de Kleene = max
        return out^

    if (
        k == Kind.GT
        or k == Kind.GE
        or k == Kind.LT
        or k == Kind.LE
        or k == Kind.EQ
        or k == Kind.NE
    ):
        # caminho rapido: coluna de texto dicionarizada vs. literal
        var rapido = _cmp_dicionario(expr, n, cols, k)
        if len(rapido) == linhas:
            return rapido^

        var a = _avaliar_no(expr, n.left, cols)
        var b = _avaliar_no(expr, n.right, cols)
        if a.eh_texto != b.eh_texto:
            # Decisao 4: nada de coercao silenciosa entre texto e numero
            raise Error(
                "comparacao entre texto e numero em "
                + expr.descrever()
                + " — converta explicitamente"
            )
        var out = _zeros_u8(linhas)
        if a.eh_texto:
            var na = _zeros_u8(linhas)
            ou_na(a.na, b.na, na, linhas)
            for i in range(linhas):
                if na[i] != 0:
                    out[i] = UInt8(Tri.DESCONHECIDO)
                else:
                    out[i] = _de_bool(_cmp_texto(k, a.textos[i], b.textos[i]))
        else:
            var na = _zeros_u8(linhas)
            ou_na(a.na, b.na, na, linhas)
            cmp_f64(_codigo_op(k), a.reais, b.reais, na, out, linhas)
        return out^

    raise Error("expressao de filtro nao booleana")


def _cmp_dicionario(
    expr: Expr, n: ExprNode, cols: List[Coluna], k: Int
) raises -> List[UInt8]:
    """Caminho rapido: coluna de texto dicionarizada vs. literal de texto.

    `cidade == "SP"` vira comparacao de Int32 vetorizada. O texto e resolvido
    para um codigo UMA vez, varrendo so os valores distintos.

    Devolve lista vazia quando o padrao nao se aplica — o chamador cai no
    caminho geral.
    """
    if k != Kind.EQ and k != Kind.NE:
        return List[UInt8]()

    var esq = expr.nodes[n.left].copy()
    var dir = expr.nodes[n.right].copy()
    var col_no: ExprNode
    var lit_no: ExprNode
    if esq.kind == Kind.COLUNA and dir.kind == Kind.LIT_STR:
        col_no = esq^
        lit_no = dir^
    elif dir.kind == Kind.COLUNA and esq.kind == Kind.LIT_STR:
        col_no = dir^
        lit_no = esq^
    else:
        return List[UInt8]()
    var nome = col_no.nome
    var literal = lit_no.texto

    var pos = posicao_no_lote(cols, nome)
    ref col = cols[pos]
    if col.tipo != DType.TEXTO or not col.eh_dicionarizada():
        return List[UInt8]()

    var linhas = col.tamanho()
    var na = col.validity_bits.para_bytes()
    var out = _zeros_u8(linhas)
    var code = col.codigo_de(literal)

    if code < 0:
        # o literal nao esta no dicionario: nenhuma linha casa
        var constante = UInt8(Tri.FALSO)
        if k == Kind.NE:
            constante = UInt8(Tri.VERDADEIRO)
        for i in range(linhas):
            if na[i] != 0:
                out[i] = UInt8(Tri.DESCONHECIDO)
            else:
                out[i] = constante
        return out^

    cmp_i32(_codigo_op(k), col.codigos, code, na, out, linhas)
    return out^


def _codigo_op(k: Int) -> Int:
    """Kind de comparacao -> codigo do kernel (0 gt .. 5 ne)."""
    if k == Kind.GT:
        return 0
    if k == Kind.GE:
        return 1
    if k == Kind.LT:
        return 2
    if k == Kind.LE:
        return 3
    if k == Kind.EQ:
        return 4
    return 5


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
    """Data e datahora contam como inteiro na aritmetica (dias / microssegundos)."""
    if codigo == DType.DATA or codigo == DType.DATAHORA:
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
    if k == Kind.LIT_DATAHORA:
        return DType.DATAHORA
    if k == Kind.LIT_STR:
        return DType.TEXTO
    if k == Kind.LIT_BOOL:
        return DType.LOGICO
    if (
        k == Kind.ANO
        or k == Kind.MES
        or k == Kind.DIA
        or k == Kind.HORA
        or k == Kind.MINUTO
        or k == Kind.SEGUNDO
    ):
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
        aus.append(v.na[i] != 0)

    if tipo == DType.TEXTO:
        var textos = List[String](capacity=n)
        for i in range(n):
            textos.append(v.textos[i])
        return Coluna.de_textos(nome, textos^, aus^)

    if tipo == DType.INTEIRO or tipo == DType.DATA or tipo == DType.DATAHORA:
        var vals = List[Int64](capacity=n)
        for i in range(n):
            vals.append(Int64(Int(v.reais[i])))
        if tipo == DType.DATA:
            return Coluna.de_datas(nome, vals^, aus^)
        if tipo == DType.DATAHORA:
            return Coluna.de_datahoras(nome, vals^, aus^)
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


def filtrar_coluna(col: Coluna, keep: List[UInt8]) raises -> Coluna:
    var n_out = contar_marcados(keep, col.tamanho())

    if (
        col.tipo == DType.INTEIRO
        or col.tipo == DType.DATA
        or col.tipo == DType.DATAHORA
    ):
        var vals = List[Int64](capacity=n_out)
        var aus = List[Bool](capacity=n_out)
        for i in range(col.tamanho()):
            if keep[i] != 0:
                vals.append(col.ints[i])
                aus.append(col.eh_ausente(i))
        if col.tipo == DType.DATA:
            return Coluna.de_datas(col.nome, vals^, aus^)
        if col.tipo == DType.DATAHORA:
            return Coluna.de_datahoras(col.nome, vals^, aus^)
        return Coluna.de_inteiros(col.nome, vals^, aus^)

    if col.tipo == DType.REAL:
        var vals = List[Float64](capacity=n_out)
        var aus = List[Bool](capacity=n_out)
        for i in range(col.tamanho()):
            if keep[i] != 0:
                vals.append(col.reals[i])
                aus.append(col.eh_ausente(i))
        return Coluna.de_reais(col.nome, vals^, aus^)

    if col.tipo == DType.LOGICO:
        var vals = List[Bool](capacity=n_out)
        var aus = List[Bool](capacity=n_out)
        for i in range(col.tamanho()):
            if keep[i] != 0:
                vals.append(Int(col.logics[i]) != 0)
                aus.append(col.eh_ausente(i))
        return Coluna.de_logicos(col.nome, vals^, aus^)

    var vals = List[String](capacity=n_out)
    var aus = List[Bool](capacity=n_out)
    for i in range(col.tamanho()):
        if keep[i] != 0:
            if col.eh_ausente(i):
                vals.append("")
                aus.append(True)
            else:
                vals.append(col.texto_bruto(i))
                aus.append(False)
    return Coluna.de_textos(col.nome, vals^, aus^)


def op_filtro(cols: List[Coluna], pred: Expr) raises -> List[Coluna]:
    """FilterExec: mascara de tres valores -> selecao. So Verdadeiro passa."""
    var linhas = n_linhas(cols)
    var mascara = avaliar_tri(pred, cols)
    var keep = _zeros_u8(linhas)
    tri_para_keep(mascara, keep, linhas)

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


def _tem_caminho_dicionario(
    expr: Expr, n: ExprNode, cols: List[Coluna]
) raises -> Bool:
    """A comparacao casa com o padrao vetorizado coluna-dicionarizada vs literal?"""
    if n.kind != Kind.EQ and n.kind != Kind.NE:
        return False
    var esq = expr.nodes[n.left].copy()
    var dir = expr.nodes[n.right].copy()
    var col_no: ExprNode
    if esq.kind == Kind.COLUNA and dir.kind == Kind.LIT_STR:
        col_no = esq^
    elif dir.kind == Kind.COLUNA and esq.kind == Kind.LIT_STR:
        col_no = dir^
    else:
        return False
    var nome = col_no.nome
    for c in cols:
        if c.nome == nome:
            return c.tipo == DType.TEXTO and c.eh_dicionarizada()
    return False


def avisos_expr(
    expr: Expr,
    idx: Int,
    esq: List[Campo],
    cols: List[Coluna],
    mut saida: List[String],
) raises:
    """Marca os nos que ainda nao tem kernel vetorizado.

    O pandas nunca avisa que voce caiu do caminho rapido. Aqui avisa — e o aviso
    some quando o kernel chega.
    """
    if idx < 0:
        return
    var n = expr.nodes[idx].copy()
    var k = n.kind

    # comparacao dicionarizada e SIMD sobre Int32: nao avisa, nem desce na subarvore
    if _tem_caminho_dicionario(expr, n, cols):
        return

    if k == Kind.COLUNA:
        if tipo_no_esquema(esq, n.nome) == DType.TEXTO:
            saida.append(
                "coluna de texto '"
                + n.nome
                + "': comparacao escalar byte a byte (sem dicionario — "
                + "cardinalidade alta demais ou coluna derivada)"
            )
        return
    if k == Kind.HORA or k == Kind.MINUTO or k == Kind.SEGUNDO:
        saida.append(
            "extrator de hora: caminho escalar (divisao em Int64 nao vetoriza no AVX2)"
        )

    avisos_expr(expr, n.left, esq, cols, saida)
    avisos_expr(expr, n.right, esq, cols, saida)


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
            avisos_expr(e.expr, e.expr.root, esq, cols, saida)
            if e.tipo == TipoEtapa.COM_COLUNA:
                esq = com_coluna_esquema(
                    esq, e.nome, tipo_resultado(e.expr, e.expr.root, esq)
                )
    return saida^
