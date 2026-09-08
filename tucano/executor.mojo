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
        elif e.tipo == TipoEtapa.AGREGACAO:
            atual = esquema_agrupado(atual, e.nomes, e.agregacoes)
        elif e.tipo == TipoEtapa.JUNCAO:
            atual = esquema_unido(atual, esquema_do_lote(e.lote_direito), e.nomes)
        # ordenacao, concatenacao, remocao e preenchimento nao mudam o esquema
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


def _compactar_f64(
    origem: List[Float64], keep: List[UInt8], n: Int, n_out: Int
) -> List[Float64]:
    var out = List[Float64](capacity=n_out)
    if n_out <= 0:
        return out^
    out.resize(unsafe_uninit_length=n_out)
    var dest = out.unsafe_ptr()
    var src = origem.unsafe_ptr()
    var k = keep.unsafe_ptr()
    var j = 0
    for i in range(n):
        if k.unsafe_load(i) != 0:
            dest.unsafe_store(j, src.unsafe_load(i))
            j += 1
    return out^


def _compactar_i64(
    origem: List[Int64], keep: List[UInt8], n: Int, n_out: Int
) -> List[Int64]:
    var out = List[Int64](capacity=n_out)
    if n_out <= 0:
        return out^
    out.resize(unsafe_uninit_length=n_out)
    var dest = out.unsafe_ptr()
    var src = origem.unsafe_ptr()
    var k = keep.unsafe_ptr()
    var j = 0
    for i in range(n):
        if k.unsafe_load(i) != 0:
            dest.unsafe_store(j, src.unsafe_load(i))
            j += 1
    return out^


def _compactar_i32(
    origem: List[Int32], keep: List[UInt8], n: Int, n_out: Int
) -> List[Int32]:
    var out = List[Int32](capacity=n_out)
    if n_out <= 0:
        return out^
    out.resize(unsafe_uninit_length=n_out)
    var dest = out.unsafe_ptr()
    var src = origem.unsafe_ptr()
    var k = keep.unsafe_ptr()
    var j = 0
    for i in range(n):
        if k.unsafe_load(i) != 0:
            dest.unsafe_store(j, src.unsafe_load(i))
            j += 1
    return out^


def filtrar_coluna(col: Coluna, keep: List[UInt8]) raises -> Coluna:
    var n = col.tamanho()
    var n_out = contar_marcados(keep, n)
    var sem_na = not col.validity_bits.tem_ausentes()

    if (
        col.tipo == DType.INTEIRO
        or col.tipo == DType.DATA
        or col.tipo == DType.DATAHORA
    ):
        if sem_na:
            var vals = _compactar_i64(col.ints, keep, n, n_out)
            if col.tipo == DType.DATA:
                return Coluna.de_datas(col.nome, vals^, List[Bool]())
            if col.tipo == DType.DATAHORA:
                return Coluna.de_datahoras(col.nome, vals^, List[Bool]())
            return Coluna.de_inteiros(col.nome, vals^, List[Bool]())
        var vals = List[Int64](capacity=n_out)
        var aus = List[Bool](capacity=n_out)
        for i in range(n):
            if keep[i] != 0:
                vals.append(col.ints[i])
                aus.append(col.eh_ausente(i))
        if col.tipo == DType.DATA:
            return Coluna.de_datas(col.nome, vals^, aus^)
        if col.tipo == DType.DATAHORA:
            return Coluna.de_datahoras(col.nome, vals^, aus^)
        return Coluna.de_inteiros(col.nome, vals^, aus^)

    if col.tipo == DType.REAL:
        if sem_na:
            return Coluna.de_reais(
                col.nome, _compactar_f64(col.reals, keep, n, n_out), List[Bool]()
            )
        var vals = List[Float64](capacity=n_out)
        var aus = List[Bool](capacity=n_out)
        for i in range(n):
            if keep[i] != 0:
                vals.append(col.reals[i])
                aus.append(col.eh_ausente(i))
        return Coluna.de_reais(col.nome, vals^, aus^)

    if col.tipo == DType.LOGICO:
        var vals = List[Bool](capacity=n_out)
        var aus = List[Bool](capacity=n_out)
        for i in range(n):
            if keep[i] != 0:
                vals.append(Int(col.logics[i]) != 0)
                aus.append(col.eh_ausente(i))
        return Coluna.de_logicos(col.nome, vals^, aus^)

    # coluna dicionarizada: filtra os codigos e mantem o dicionario
    if col.eh_dicionarizada():
        if sem_na:
            return Coluna.de_dicionario(
                col.nome,
                col.textos.copy(),
                _compactar_i32(col.codigos, keep, n, n_out),
                List[Bool](),
            )
        var codigos = List[Int32](capacity=n_out)
        var aus = List[Bool](capacity=n_out)
        for i in range(n):
            if keep[i] != 0:
                codigos.append(col.codigos[i])
                aus.append(col.eh_ausente(i))
        return Coluna.de_dicionario(col.nome, col.textos.copy(), codigos^, aus^)

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

    Substitui a coluna se o nome ja existir.
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
        elif e.tipo == TipoEtapa.AGREGACAO:
            atual = op_agrupar(atual, e.nomes, e.agregacoes)
        elif e.tipo == TipoEtapa.JUNCAO:
            atual = op_unir(atual, e.lote_direito, e.nomes, e.tipo_juncao)
        elif e.tipo == TipoEtapa.ORDENACAO:
            atual = op_ordenar(atual, e.nomes, e.descendente)
        elif e.tipo == TipoEtapa.CONCATENACAO:
            atual = op_concatenar(atual, e.lote_direito)
        elif e.tipo == TipoEtapa.REMOVER_NA:
            atual = op_remover_na(atual, e.nomes)
        elif e.tipo == TipoEtapa.PREENCHER_NA:
            atual = op_preencher_na(atual, e.nome, e.expr)
        elif e.tipo == TipoEtapa.LIMITE:
            atual = op_limite(atual, e.limite)
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

    O normal e a ferramenta nao avisar que voce saiu do caminho rapido. Aqui avisa
    — e o aviso some quando o kernel chega.
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
        elif e.tipo == TipoEtapa.AGREGACAO:
            esq = esquema_agrupado(esq, e.nomes, e.agregacoes)
        elif e.tipo == TipoEtapa.JUNCAO:
            esq = esquema_unido(esq, esquema_do_lote(e.lote_direito), e.nomes)
        elif (
            e.tipo == TipoEtapa.ORDENACAO
            or e.tipo == TipoEtapa.CONCATENACAO
            or e.tipo == TipoEtapa.REMOVER_NA
            or e.tipo == TipoEtapa.LIMITE
        ):
            pass
        else:
            avisos_expr(e.expr, e.expr.root, esq, cols, saida)
            if e.tipo == TipoEtapa.COM_COLUNA:
                esq = com_coluna_esquema(
                    esq, e.nome, tipo_resultado(e.expr, e.expr.root, esq)
                )
    return saida^


# ------------------------------------------------------------- agregacao

from std.collections import Dict
from .agregacao import Agregacao, TipoAgregacao


struct Grupos(Copyable, Movable):
    """A que grupo pertence cada linha, e qual linha representa cada grupo."""

    var ids: List[Int]
    var n_grupos: Int
    var representantes: List[Int]
    var caminho: String
    """Como os grupos foram formados — aparece no plano fisico."""

    def __init__(
        out self,
        var ids: List[Int],
        n_grupos: Int,
        var representantes: List[Int],
        caminho: String,
    ):
        self.ids = ids^
        self.n_grupos = n_grupos
        self.representantes = representantes^
        self.caminho = caminho


def _chave_texto(col: Coluna, i: Int) raises -> String:
    """Representacao textual de uma celula, para compor chave de grupo."""
    if col.eh_ausente(i):
        return "\x00NA"
    if col.tipo == DType.TEXTO:
        return "s" + col.texto_bruto(i)
    if col.tipo == DType.REAL:
        return "r" + String(col.reals[i])
    if col.tipo == DType.LOGICO:
        return "b" + String(Int(col.logics[i]))
    return "i" + String(col.ints[i])


def calcular_grupos(cols: List[Coluna], chaves: List[String]) raises -> Grupos:
    """Atribui um id de grupo a cada linha, preservando a ordem de aparicao.

    Tres caminhos, do mais rapido ao mais geral:

    1. **uma chave de texto dicionarizada** — o codigo Int32 ja E o grupo. Vira
       indexacao direta de array, sem hash nenhum. E o retorno do dictionary
       encoding: a estrutura criada para acelerar filtro tambem acelera groupby.
    2. **uma chave inteira ou temporal** — tabela hash de inteiros.
    3. **qualquer outra combinacao** — chave composta em texto.
    """
    var linhas = n_linhas(cols)
    var ids = List[Int](capacity=linhas)
    var representantes = List[Int]()

    if len(chaves) == 1:
        var pos = posicao_no_lote(cols, chaves[0])
        ref col = cols[pos]

        if col.tipo == DType.TEXTO and col.eh_dicionarizada():
            # cardinalidade + 1 posicoes: a ultima recebe os ausentes
            var cardinalidade = col.cardinalidade()
            var mapa = List[Int](capacity=cardinalidade + 1)
            mapa.resize(cardinalidade + 1, -1)
            ids.resize(unsafe_uninit_length=linhas)
            var dest = ids.unsafe_ptr()
            var codes = col.codigos.unsafe_ptr()
            var n_grupos = 0
            if not col.validity_bits.tem_ausentes():
                for i in range(linhas):
                    var slot = Int(codes.unsafe_load(i))
                    if mapa[slot] < 0:
                        mapa[slot] = n_grupos
                        representantes.append(i)
                        n_grupos += 1
                    dest.unsafe_store(i, mapa[slot])
            else:
                for i in range(linhas):
                    var slot = cardinalidade
                    if not col.eh_ausente(i):
                        slot = Int(codes.unsafe_load(i))
                    if mapa[slot] < 0:
                        mapa[slot] = n_grupos
                        representantes.append(i)
                        n_grupos += 1
                    dest.unsafe_store(i, mapa[slot])
            return Grupos(ids^, n_grupos, representantes^, "indexacao direta")

        if (
            col.tipo == DType.INTEIRO
            or col.tipo == DType.DATA
            or col.tipo == DType.DATAHORA
            or col.tipo == DType.LOGICO
        ):
            var mapa = Dict[Int, Int]()
            var ausente_id = -1
            var n_grupos = 0
            for i in range(linhas):
                if col.eh_ausente(i):
                    if ausente_id < 0:
                        ausente_id = n_grupos
                        representantes.append(i)
                        n_grupos += 1
                    ids.append(ausente_id)
                    continue
                var chave: Int
                if col.tipo == DType.LOGICO:
                    chave = Int(col.logics[i])
                else:
                    chave = Int(col.ints[i])
                if chave in mapa:
                    ids.append(mapa[chave])
                else:
                    mapa[chave] = n_grupos
                    representantes.append(i)
                    ids.append(n_grupos)
                    n_grupos += 1
            return Grupos(ids^, n_grupos, representantes^, "hash de inteiros")

    var mapa = Dict[String, Int]()
    var n_grupos = 0
    var posicoes = List[Int]()
    for chave in chaves:
        posicoes.append(posicao_no_lote(cols, chave))
    for i in range(linhas):
        var composta = String("")
        for p in posicoes:
            composta += _chave_texto(cols[p], i) + "\x01"
        if composta in mapa:
            ids.append(mapa[composta])
        else:
            mapa[composta] = n_grupos
            representantes.append(i)
            ids.append(n_grupos)
            n_grupos += 1
    return Grupos(ids^, n_grupos, representantes^, "hash de chave composta")


def coletar_linhas(col: Coluna, indices: List[Int]) raises -> Coluna:
    """Nova coluna com as linhas indicadas, na ordem dada."""
    var n = len(indices)
    var aus = List[Bool](capacity=n)
    for i in indices:
        aus.append(col.eh_ausente(i))

    if col.tipo == DType.TEXTO:
        if col.eh_dicionarizada():
            var codigos = List[Int32](capacity=n)
            for i in indices:
                codigos.append(col.codigos[i])
            return Coluna.de_dicionario(col.nome, col.textos.copy(), codigos^, aus^)
        var vals = List[String](capacity=n)
        for i in indices:
            if col.eh_ausente(i):
                vals.append("")
            else:
                vals.append(col.texto_bruto(i))
        return Coluna.de_textos(col.nome, vals^, aus^)
    if col.tipo == DType.REAL:
        var vals = List[Float64](capacity=n)
        for i in indices:
            vals.append(col.reals[i])
        return Coluna.de_reais(col.nome, vals^, aus^)
    if col.tipo == DType.LOGICO:
        var vals = List[Bool](capacity=n)
        for i in indices:
            vals.append(Int(col.logics[i]) != 0)
        return Coluna.de_logicos(col.nome, vals^, aus^)
    var vals = List[Int64](capacity=n)
    for i in indices:
        vals.append(col.ints[i])
    if col.tipo == DType.DATA:
        return Coluna.de_datas(col.nome, vals^, aus^)
    if col.tipo == DType.DATAHORA:
        return Coluna.de_datahoras(col.nome, vals^, aus^)
    return Coluna.de_inteiros(col.nome, vals^, aus^)


def tipo_da_agregacao(a: Agregacao, esq: List[Campo]) raises -> Int:
    """Tipo de saida, calculado sobre o esquema — sem executar."""
    if a.tipo == TipoAgregacao.CONTAGEM or a.tipo == TipoAgregacao.DISTINTOS:
        return DType.INTEIRO
    if a.tipo == TipoAgregacao.MEDIA:
        return DType.REAL
    var entrada = tipo_no_esquema(esq, a.coluna)
    if a.tipo == TipoAgregacao.SOMA:
        # soma de temporal nao faz sentido; soma de inteiro continua inteira
        if entrada == DType.INTEIRO:
            return DType.INTEIRO
        return DType.REAL
    return entrada  # minimo, maximo e primeiro preservam o tipo


def _agregar_uma(
    cols: List[Coluna], a: Agregacao, grupos: Grupos, esq: List[Campo]
) raises -> Coluna:
    var linhas = n_linhas(cols)
    var g = grupos.n_grupos
    var nome = a.nome_saida()
    var tipo_saida = tipo_da_agregacao(a, esq)

    # contagem de linhas: nao olha valor nenhum
    if a.tipo == TipoAgregacao.CONTAGEM and a.coluna == "":
        var vals = List[Int64](capacity=g)
        vals.resize(g, Int64(0))
        var vp = vals.unsafe_ptr()
        var gids = grupos.ids.unsafe_ptr()
        for i in range(linhas):
            var gid = gids.unsafe_load(i)
            vp.unsafe_store(gid, vp.unsafe_load(gid) + Int64(1))
        return Coluna.de_inteiros(nome, vals^, List[Bool]())

    var pos = posicao_no_lote(cols, a.coluna)
    ref col = cols[pos]

    if a.tipo == TipoAgregacao.PRIMEIRO:
        var c = coletar_linhas(col, grupos.representantes)
        return Coluna(
            nome, c.tipo, c.n, c.validity_bits.copy(), c.ints.copy(),
            c.reals.copy(), c.logics.copy(), c.textos.copy(), c.codigos.copy(),
        )

    if a.tipo == TipoAgregacao.CONTAGEM:
        var vals = List[Int64](capacity=g)
        for _ in range(g):
            vals.append(Int64(0))
        for i in range(linhas):
            if not col.eh_ausente(i):
                vals[grupos.ids[i]] += 1
        return Coluna.de_inteiros(nome, vals^, List[Bool]())

    if a.tipo == TipoAgregacao.DISTINTOS:
        var vistos = Dict[String, Bool]()
        var vals = List[Int64](capacity=g)
        for _ in range(g):
            vals.append(Int64(0))
        for i in range(linhas):
            if col.eh_ausente(i):
                continue
            var k = String(grupos.ids[i]) + "\x01" + _chave_texto(col, i)
            if k not in vistos:
                vistos[k] = True
                vals[grupos.ids[i]] += 1
        return Coluna.de_inteiros(nome, vals^, List[Bool]())

    # minimo / maximo sobre texto: comparacao lexicografica
    if col.tipo == DType.TEXTO:
        if a.tipo != TipoAgregacao.MINIMO and a.tipo != TipoAgregacao.MAXIMO:
            raise Error(
                "agregacao " + TipoAgregacao.nome(a.tipo)
                + " nao se aplica a coluna de texto: " + a.coluna
            )
        var textos = List[String](capacity=g)
        var vazio = List[Bool](capacity=g)
        for _ in range(g):
            textos.append("")
            vazio.append(True)
        for i in range(linhas):
            if col.eh_ausente(i):
                continue
            var gid = grupos.ids[i]
            var v = col.texto_bruto(i)
            if vazio[gid]:
                textos[gid] = v
                vazio[gid] = False
            elif a.tipo == TipoAgregacao.MINIMO:
                if v < textos[gid]:
                    textos[gid] = v
            else:
                if v > textos[gid]:
                    textos[gid] = v
        return Coluna.de_textos(nome, textos^, vazio^)

    # numericas e temporais: coluna real sem ausentes nao precisa virar Vetor
    if col.tipo == DType.REAL and not col.validity_bits.tem_ausentes():
        if (
            a.tipo == TipoAgregacao.SOMA
            or a.tipo == TipoAgregacao.MEDIA
            or a.tipo == TipoAgregacao.MINIMO
            or a.tipo == TipoAgregacao.MAXIMO
        ):
            var acumulado = List[Float64](capacity=g)
            var contagem = List[Int](capacity=g)
            acumulado.resize(g, 0.0)
            contagem.resize(g, 0)
            var src = col.reals.unsafe_ptr()
            var gids = grupos.ids.unsafe_ptr()
            var accp = acumulado.unsafe_ptr()
            var cntp = contagem.unsafe_ptr()
            if a.tipo == TipoAgregacao.SOMA or a.tipo == TipoAgregacao.MEDIA:
                for i in range(linhas):
                    var gid = gids.unsafe_load(i)
                    accp.unsafe_store(gid, accp.unsafe_load(gid) + src.unsafe_load(i))
                    cntp.unsafe_store(gid, cntp.unsafe_load(gid) + 1)
            elif a.tipo == TipoAgregacao.MINIMO:
                for i in range(linhas):
                    var gid = gids.unsafe_load(i)
                    var x = src.unsafe_load(i)
                    if cntp.unsafe_load(gid) == 0 or x < accp.unsafe_load(gid):
                        accp.unsafe_store(gid, x)
                    cntp.unsafe_store(gid, cntp.unsafe_load(gid) + 1)
            else:
                for i in range(linhas):
                    var gid = gids.unsafe_load(i)
                    var x = src.unsafe_load(i)
                    if cntp.unsafe_load(gid) == 0 or x > accp.unsafe_load(gid):
                        accp.unsafe_store(gid, x)
                    cntp.unsafe_store(gid, cntp.unsafe_load(gid) + 1)
            var saida_densa = Vetor.numerico(g)
            for gi in range(g):
                if contagem[gi] == 0:
                    saida_densa.na[gi] = UInt8(1)
                    continue
                if a.tipo == TipoAgregacao.MEDIA:
                    saida_densa.reais[gi] = acumulado[gi] / Float64(contagem[gi])
                else:
                    saida_densa.reais[gi] = acumulado[gi]
            return vetor_para_coluna(nome, saida_densa, tipo_saida)

    # numericas e temporais passam pelo Vetor
    var v = extrair_coluna(cols, a.coluna)
    var acumulado = List[Float64](capacity=g)
    var contagem = List[Int](capacity=g)
    for _ in range(g):
        acumulado.append(0.0)
        contagem.append(0)

    for i in range(linhas):
        if v.na[i] != 0:
            continue
        var gid = grupos.ids[i]
        var x = v.reais[i]
        if contagem[gid] == 0:
            acumulado[gid] = x
        elif a.tipo == TipoAgregacao.SOMA or a.tipo == TipoAgregacao.MEDIA:
            acumulado[gid] += x
        elif a.tipo == TipoAgregacao.MINIMO:
            if x < acumulado[gid]:
                acumulado[gid] = x
        else:
            if x > acumulado[gid]:
                acumulado[gid] = x
        contagem[gid] += 1

    var saida = Vetor.numerico(g)
    for gi in range(g):
        if contagem[gi] == 0:
            # grupo sem valor valido nao vira zero: vira ausente
            saida.na[gi] = UInt8(1)
            continue
        if a.tipo == TipoAgregacao.MEDIA:
            saida.reais[gi] = acumulado[gi] / Float64(contagem[gi])
        else:
            saida.reais[gi] = acumulado[gi]
    return vetor_para_coluna(nome, saida, tipo_saida)


def grupo_unico(n: Int) -> Grupos:
    """Tudo num grupo so — agregacao total, sem chave."""
    var ids = List[Int](capacity=n)
    for _ in range(n):
        ids.append(0)
    var rep = List[Int]()
    if n > 0:
        rep.append(0)
    var n_grupos = 1 if n > 0 else 0
    return Grupos(ids^, n_grupos, rep^, "grupo unico")


def op_agrupar(
    cols: List[Coluna], chaves: List[String], agregacoes: List[Agregacao]
) raises -> List[Coluna]:
    """HashAggregate: agrupa por chave e reduz cada grupo.

    Sem chave, agrega a tabela inteira num unico grupo — e o que um KPI pede.
    """
    if len(agregacoes) == 0:
        raise Error("agregar exige pelo menos uma agregacao")

    var grupos: Grupos
    if len(chaves) == 0:
        grupos = grupo_unico(n_linhas(cols))
    else:
        grupos = calcular_grupos(cols, chaves)
    var esq = esquema_do_lote(cols)
    var saida = List[Coluna]()
    for chave in chaves:
        saida.append(
            coletar_linhas(cols[posicao_no_lote(cols, chave)], grupos.representantes)
        )
    for a in agregacoes:
        saida.append(_agregar_uma(cols, a, grupos, esq))
    return saida^


def esquema_agrupado(
    esq: List[Campo], chaves: List[String], agregacoes: List[Agregacao]
) raises -> List[Campo]:
    var out = List[Campo]()
    for chave in chaves:
        out.append(Campo(chave, DType(tipo_no_esquema(esq, chave))))
    for a in agregacoes:
        out.append(Campo(a.nome_saida(), DType(tipo_da_agregacao(a, esq))))
    return out^


# ---------------------------------------------------------------- juncao


struct TipoJuncao:
    comptime INTERNO = 0
    comptime ESQUERDA = 1

    @staticmethod
    def de_texto(t: String) raises -> Int:
        var v = String(t.lower())
        if v == "interno" or v == "inner":
            return Self.INTERNO
        if v == "esquerda" or v == "left":
            return Self.ESQUERDA
        raise Error(
            "tipo de juncao desconhecido: '" + t + "' (use 'interno' ou 'esquerda')"
        )

    @staticmethod
    def nome(t: Int) raises -> String:
        if t == Self.INTERNO:
            return "interno"
        if t == Self.ESQUERDA:
            return "esquerda"
        raise Error("tipo de juncao desconhecido: " + String(t))


def coletar_linhas_opcional(
    col: Coluna, indices: List[Int], nome: String
) raises -> Coluna:
    """Como `coletar_linhas`, mas indice -1 vira ausente.

    E o que permite a juncao a esquerda: linha sem par do outro lado nao some,
    fica com os campos daquele lado ausentes.
    """
    var n = len(indices)
    var aus = List[Bool](capacity=n)
    for i in indices:
        if i < 0:
            aus.append(True)
        else:
            aus.append(col.eh_ausente(i))

    if col.tipo == DType.TEXTO:
        var vals = List[String](capacity=n)
        for i in indices:
            if i < 0 or col.eh_ausente(i):
                vals.append("")
            else:
                vals.append(col.texto_bruto(i))
        return Coluna.de_textos(nome, vals^, aus^)
    if col.tipo == DType.REAL:
        var vals = List[Float64](capacity=n)
        for i in indices:
            if i < 0:
                vals.append(0.0)
            else:
                vals.append(col.reals[i])
        return Coluna.de_reais(nome, vals^, aus^)
    if col.tipo == DType.LOGICO:
        var vals = List[Bool](capacity=n)
        for i in indices:
            if i < 0:
                vals.append(False)
            else:
                vals.append(Int(col.logics[i]) != 0)
        return Coluna.de_logicos(nome, vals^, aus^)
    var vals = List[Int64](capacity=n)
    for i in indices:
        if i < 0:
            vals.append(Int64(0))
        else:
            vals.append(col.ints[i])
    if col.tipo == DType.DATA:
        return Coluna.de_datas(nome, vals^, aus^)
    if col.tipo == DType.DATAHORA:
        return Coluna.de_datahoras(nome, vals^, aus^)
    return Coluna.de_inteiros(nome, vals^, aus^)


def _chave_composta(cols: List[Coluna], posicoes: List[Int], i: Int) raises -> String:
    var s = String("")
    for p in posicoes:
        s += _chave_texto(cols[p], i) + "\x01"
    return s


struct ChavesJuncao(Copyable, Movable):
    """Chaves de um lado da juncao, ja no formato mais barato possivel.

    Chave unica inteira vira `Int`; chave unica de texto vira a propria `String`,
    sem prefixo nem separador. So combinacoes de colunas pagam a chave composta —
    que o bench mostra custar uma ordem de grandeza a mais.
    """

    var inteiras: List[Int]
    var textos: List[String]
    var ausente: List[Bool]
    var usa_inteiro: Bool

    def __init__(
        out self,
        var inteiras: List[Int],
        var textos: List[String],
        var ausente: List[Bool],
        usa_inteiro: Bool,
    ):
        self.inteiras = inteiras^
        self.textos = textos^
        self.ausente = ausente^
        self.usa_inteiro = usa_inteiro


def _chaves_de_juncao(
    cols: List[Coluna], posicoes: List[Int]
) raises -> ChavesJuncao:
    var n = n_linhas(cols)
    var ausente = List[Bool](capacity=n)
    for i in range(n):
        var na = False
        for p in posicoes:
            if cols[p].eh_ausente(i):
                na = True
        ausente.append(na)

    if len(posicoes) == 1:
        ref col = cols[posicoes[0]]
        if (
            col.tipo == DType.INTEIRO
            or col.tipo == DType.DATA
            or col.tipo == DType.DATAHORA
            or col.tipo == DType.LOGICO
        ):
            var ints = List[Int](capacity=n)
            for i in range(n):
                if col.tipo == DType.LOGICO:
                    ints.append(Int(col.logics[i]))
                else:
                    ints.append(Int(col.ints[i]))
            return ChavesJuncao(ints^, List[String](), ausente^, True)
        if col.tipo == DType.TEXTO:
            var txt = List[String](capacity=n)
            for i in range(n):
                if ausente[i]:
                    txt.append("")
                else:
                    txt.append(col.texto_bruto(i))
            return ChavesJuncao(List[Int](), txt^, ausente^, False)

    var comp = List[String](capacity=n)
    for i in range(n):
        comp.append(_chave_composta(cols, posicoes, i))
    return ChavesJuncao(List[Int](), comp^, ausente^, False)


def _custo_hash_juncao(cols: List[Coluna], pos: List[Int]) raises -> Int:
    """Custo de construir a tabela hash deste lado.

    Uma chave de texto dicionarizada custa a cardinalidade, nao o numero de
    linhas: o hash so tem tantos baldes quanto valores distintos. Sem isso,
    `pequena.unir(grande)` hashearia o lado grande so porque veio a direita.
    """
    var n = n_linhas(cols)
    if n <= 0:
        return 0
    if len(pos) != 1:
        return n
    ref col = cols[pos[0]]
    if col.tipo == DType.TEXTO and col.eh_dicionarizada():
        var d = col.cardinalidade()
        if d > 0 and d < n:
            return d
    return n


def _sondar_juncao(
    var ch_build: ChavesJuncao,
    var ch_probe: ChavesJuncao,
    n_build: Int,
    n_probe: Int,
    manter_sem_par: Bool,
    mut idx_probe: List[Int],
    mut idx_build: List[Int],
) raises:
    """Hash em `build`, sonda com `probe`. Preenche indices (probe, build)."""
    if ch_build.usa_inteiro:
        var balde = Dict[Int, List[Int]]()
        for i in range(n_build):
            if ch_build.ausente[i]:
                continue
            var k = ch_build.inteiras[i]
            if k in balde:
                balde[k].append(i)
            else:
                var lista = List[Int]()
                lista.append(i)
                balde[k] = lista^
        for i in range(n_probe):
            var casou = False
            if not ch_probe.ausente[i]:
                var k = ch_probe.inteiras[i]
                if k in balde:
                    casou = True
                    for j in balde[k]:
                        idx_probe.append(i)
                        idx_build.append(j)
            if not casou and manter_sem_par:
                idx_probe.append(i)
                idx_build.append(-1)
        return
    var balde = Dict[String, List[Int]]()
    for i in range(n_build):
        if ch_build.ausente[i]:
            continue
        var k = ch_build.textos[i]
        if k in balde:
            balde[k].append(i)
        else:
            var lista = List[Int]()
            lista.append(i)
            balde[k] = lista^
    for i in range(n_probe):
        var casou = False
        if not ch_probe.ausente[i]:
            var k = ch_probe.textos[i]
            if k in balde:
                casou = True
                for j in balde[k]:
                    idx_probe.append(i)
                    idx_build.append(j)
        if not casou and manter_sem_par:
            idx_probe.append(i)
            idx_build.append(-1)


def op_unir(
    esquerda: List[Coluna],
    direita: List[Coluna],
    chaves: List[String],
    tipo: Int,
) raises -> List[Coluna]:
    """HashJoin: constroi a tabela hash no lado mais barato.

    Na juncao a esquerda a hash fica na direita: toda linha da esquerda precisa
    ser sondada para sobreviver sem par. Na interna, os dois lados so entram
    quando casam — entao hasheamos o de menor custo (cardinalidade da chave
    dicionarizada, ou numero de linhas).

    Linha com chave ausente nao casa com nada, nem com outra ausente: ausente
    nao e um valor, e Desconhecido. Mesma regra do filtro.
    """
    if len(chaves) == 0:
        raise Error("unir exige pelo menos uma chave")

    var pos_esq = List[Int]()
    var pos_dir = List[Int]()
    for c in chaves:
        pos_esq.append(posicao_no_lote(esquerda, c))
        pos_dir.append(posicao_no_lote(direita, c))

    # nomes que colidem fora das chaves: recusar em vez de renomear em silencio
    var nomes_chave = List[String]()
    for c in chaves:
        nomes_chave.append(c)
    for cd in direita:
        var eh_chave = False
        for c in nomes_chave:
            if c == cd.nome:
                eh_chave = True
        if eh_chave:
            continue
        for ce in esquerda:
            if ce.nome == cd.nome:
                raise Error(
                    "unir: a coluna '" + cd.nome + "' existe nos dois lados."
                    + " Renomeie antes com `com_coluna`, ou inclua-a nas chaves"
                )

    var chaves_dir = _chaves_de_juncao(direita, pos_dir)
    var chaves_esq = _chaves_de_juncao(esquerda, pos_esq)
    var n_dir = n_linhas(direita)
    var n_esq = n_linhas(esquerda)
    var custo_esq = _custo_hash_juncao(esquerda, pos_esq)
    var custo_dir = _custo_hash_juncao(direita, pos_dir)
    var hash_na_esquerda = (
        tipo == TipoJuncao.INTERNO
        and custo_esq < custo_dir
        and chaves_esq.usa_inteiro == chaves_dir.usa_inteiro
    )

    var idx_esq = List[Int]()
    var idx_dir = List[Int]()
    if hash_na_esquerda:
        _sondar_juncao(
            chaves_esq^, chaves_dir^, n_esq, n_dir, False, idx_dir, idx_esq
        )
    else:
        var manter = tipo == TipoJuncao.ESQUERDA
        _sondar_juncao(
            chaves_dir^, chaves_esq^, n_dir, n_esq, manter, idx_esq, idx_dir
        )

    var saida = List[Coluna]()
    for c in esquerda:
        saida.append(coletar_linhas_opcional(c, idx_esq, c.nome))
    for cd in direita:
        var eh_chave = False
        for c in nomes_chave:
            if c == cd.nome:
                eh_chave = True
        if eh_chave:
            continue
        saida.append(coletar_linhas_opcional(cd, idx_dir, cd.nome))
    return saida^


def esquema_unido(
    esq: List[Campo], dir_esq: List[Campo], chaves: List[String]
) raises -> List[Campo]:
    var out = List[Campo]()
    for c in esq:
        out.append(c.copy())
    for c in dir_esq:
        var eh_chave = False
        for k in chaves:
            if k == c.nome:
                eh_chave = True
        if not eh_chave:
            out.append(c.copy())
    return out^


# ------------------------------------------------- ordenacao e transformacoes


def _comparar_linhas(
    cols: List[Coluna], posicoes: List[Int], desc: List[Bool], a: Int, b: Int
) raises -> Int:
    """-1, 0 ou 1. Ausente vai sempre para o fim, nas duas direcoes."""
    for k in range(len(posicoes)):
        ref col = cols[posicoes[k]]
        var na_a = col.eh_ausente(a)
        var na_b = col.eh_ausente(b)
        if na_a and na_b:
            continue
        if na_a:
            return 1
        if na_b:
            return -1

        var ordem = 0
        if col.tipo == DType.TEXTO:
            var x = col.texto_bruto(a)
            var y = col.texto_bruto(b)
            if x < y:
                ordem = -1
            elif x > y:
                ordem = 1
        elif col.tipo == DType.REAL:
            if col.reals[a] < col.reals[b]:
                ordem = -1
            elif col.reals[a] > col.reals[b]:
                ordem = 1
        elif col.tipo == DType.LOGICO:
            var x = Int(col.logics[a])
            var y = Int(col.logics[b])
            if x < y:
                ordem = -1
            elif x > y:
                ordem = 1
        else:
            if col.ints[a] < col.ints[b]:
                ordem = -1
            elif col.ints[a] > col.ints[b]:
                ordem = 1

        if ordem != 0:
            if desc[k]:
                return -ordem
            return ordem
    return 0


def _mesclar(
    cols: List[Coluna],
    posicoes: List[Int],
    desc: List[Bool],
    origem: List[Int],
    mut destino: List[Int],
    ini: Int,
    meio: Int,
    fim: Int,
) raises:
    var i = ini
    var j = meio
    var k = ini
    while i < meio and j < fim:
        # `<= 0` mantem a ordenacao estavel
        if _comparar_linhas(cols, posicoes, desc, origem[i], origem[j]) <= 0:
            destino[k] = origem[i]
            i += 1
        else:
            destino[k] = origem[j]
            j += 1
        k += 1
    while i < meio:
        destino[k] = origem[i]
        i += 1
        k += 1
    while j < fim:
        destino[k] = origem[j]
        j += 1
        k += 1


def ordem_das_linhas(
    cols: List[Coluna], chaves: List[String], desc: List[Bool]
) raises -> List[Int]:
    """Ordenacao por mesclagem, estavel: linhas equivalentes mantem a ordem."""
    var n = linhas_do_lote(cols)
    var posicoes = List[Int]()
    for c in chaves:
        posicoes.append(posicao_no_lote(cols, c))

    var a = List[Int](capacity=n)
    var b = List[Int](capacity=n)
    for i in range(n):
        a.append(i)
        b.append(0)

    var largura = 1
    while largura < n:
        var i = 0
        while i < n:
            var meio = i + largura
            if meio > n:
                meio = n
            var fim = i + 2 * largura
            if fim > n:
                fim = n
            _mesclar(cols, posicoes, desc, a, b, i, meio, fim)
            i += 2 * largura
        var t = a^
        a = b^
        b = t^
        largura *= 2
    return a^


def linhas_do_lote(cols: List[Coluna]) -> Int:
    return n_linhas(cols)


def op_limite(cols: List[Coluna], n: Int) raises -> List[Coluna]:
    """LimitExec: as primeiras `n` linhas."""
    var total = n_linhas(cols)
    var ate = n
    if ate > total:
        ate = total
    if ate < 0:
        ate = 0
    var indices = List[Int](capacity=ate)
    for i in range(ate):
        indices.append(i)
    var out = List[Coluna]()
    for c in cols:
        out.append(coletar_linhas(c, indices))
    return out^


def op_ordenar(
    cols: List[Coluna], chaves: List[String], desc: List[Bool]
) raises -> List[Coluna]:
    """SortExec."""
    if len(chaves) == 0:
        raise Error("ordenar exige pelo menos uma coluna")
    var ordem = ordem_das_linhas(cols, chaves, desc)
    var out = List[Coluna]()
    for c in cols:
        out.append(coletar_linhas(c, ordem))
    return out^


def op_concatenar(
    cols: List[Coluna], outros: List[Coluna]
) raises -> List[Coluna]:
    """Empilha duas tabelas. Exige mesmo esquema — sem alinhamento por posicao."""
    if len(cols) != len(outros):
        raise Error(
            "concatenar: " + String(len(cols)) + " colunas contra "
            + String(len(outros))
        )
    var out = List[Coluna]()
    for i in range(len(cols)):
        ref a = cols[i]
        ref b = outros[i]
        if a.nome != b.nome:
            raise Error(
                "concatenar: coluna " + String(i) + " e '" + a.nome
                + "' de um lado e '" + b.nome + "' do outro"
            )
        if a.tipo != b.tipo:
            raise Error(
                "concatenar: coluna '" + a.nome + "' tem tipos diferentes nos"
                + " dois lados — converta explicitamente"
            )
        var na = a.tamanho() + b.tamanho()
        var aus = List[Bool](capacity=na)
        for k in range(a.tamanho()):
            aus.append(a.eh_ausente(k))
        for k in range(b.tamanho()):
            aus.append(b.eh_ausente(k))

        if a.tipo == DType.TEXTO:
            var vals = List[String](capacity=na)
            for k in range(a.tamanho()):
                vals.append("" if a.eh_ausente(k) else a.texto_bruto(k))
            for k in range(b.tamanho()):
                vals.append("" if b.eh_ausente(k) else b.texto_bruto(k))
            out.append(Coluna.de_textos(a.nome, vals^, aus^))
        elif a.tipo == DType.REAL:
            var vals = List[Float64](capacity=na)
            for k in range(a.tamanho()):
                vals.append(a.reals[k])
            for k in range(b.tamanho()):
                vals.append(b.reals[k])
            out.append(Coluna.de_reais(a.nome, vals^, aus^))
        elif a.tipo == DType.LOGICO:
            var vals = List[Bool](capacity=na)
            for k in range(a.tamanho()):
                vals.append(Int(a.logics[k]) != 0)
            for k in range(b.tamanho()):
                vals.append(Int(b.logics[k]) != 0)
            out.append(Coluna.de_logicos(a.nome, vals^, aus^))
        else:
            var vals = List[Int64](capacity=na)
            for k in range(a.tamanho()):
                vals.append(a.ints[k])
            for k in range(b.tamanho()):
                vals.append(b.ints[k])
            if a.tipo == DType.DATA:
                out.append(Coluna.de_datas(a.nome, vals^, aus^))
            elif a.tipo == DType.DATAHORA:
                out.append(Coluna.de_datahoras(a.nome, vals^, aus^))
            else:
                out.append(Coluna.de_inteiros(a.nome, vals^, aus^))
    return out^


def op_remover_na(cols: List[Coluna], nomes: List[String]) raises -> List[Coluna]:
    """Descarta linhas com ausente nas colunas dadas (ou em qualquer uma)."""
    var n = n_linhas(cols)
    var posicoes = List[Int]()
    if len(nomes) == 0:
        for i in range(len(cols)):
            posicoes.append(i)
    else:
        for nome in nomes:
            posicoes.append(posicao_no_lote(cols, nome))

    var keep = _zeros_u8(n)
    for i in range(n):
        var ok = True
        for p in posicoes:
            if cols[p].eh_ausente(i):
                ok = False
        if ok:
            keep[i] = UInt8(1)

    var out = List[Coluna]()
    for c in cols:
        out.append(filtrar_coluna(c, keep))
    return out^


def op_preencher_na(
    cols: List[Coluna], nome: String, expr: Expr
) raises -> List[Coluna]:
    """Substitui ausentes de uma coluna pelo valor da expressao."""
    var pos = posicao_no_lote(cols, nome)
    ref col = cols[pos]
    var n = col.tamanho()

    if col.tipo == DType.TEXTO:
        var v = avaliar(expr, cols)
        if not v.eh_texto:
            raise Error(
                "preencher_na: coluna '" + nome + "' e de texto, mas o valor"
                + " nao e — sem conversao implicita"
            )
        var vals = List[String](capacity=n)
        for i in range(n):
            if col.eh_ausente(i):
                vals.append(v.textos[i])
            else:
                vals.append(col.texto_bruto(i))
        var nova = Coluna.de_textos(nome, vals^, List[Bool]())
        var out = List[Coluna]()
        for c in cols:
            out.append(nova.copy() if c.nome == nome else c.copy())
        return out^

    var v = avaliar(expr, cols)
    if v.eh_texto:
        raise Error(
            "preencher_na: coluna '" + nome + "' e numerica, mas o valor e texto"
        )
    var vetor = Vetor.numerico(n)
    for i in range(n):
        if col.eh_ausente(i):
            vetor.reais[i] = v.reais[i]
        else:
            vetor.reais[i] = col._como_real(i)
    var nova = vetor_para_coluna(nome, vetor, col.tipo)
    var out = List[Coluna]()
    for c in cols:
        out.append(nova.copy() if c.nome == nome else c.copy())
    return out^
