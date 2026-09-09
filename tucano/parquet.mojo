"""Leitura de Parquet (M5).

Layout do arquivo:

    PAR1 <dados dos row groups> <FileMetaData> <tamanho:4 LE> PAR1

Os metadados ficam no **fim**, o que permite ler esquema e estatisticas sem
tocar nos dados — e e isso que torna possivel podar colunas e row groups antes
de ler qualquer byte de valor.

Este modulo cobre o subconjunto que aparece na pratica: esquema plano,
codificacoes PLAIN e RLE_DICTIONARY, niveis de definicao em RLE/bit-packed,
paginas V1 e V2, sem compressao ou com Snappy.
"""

from std.pathlib import Path
from std.ffi import external_call
from std.memory import UnsafePointer
from .thrift import LeitorThrift, TTipo, CampoThrift, ListaThrift
from .arquivo import LeitorArquivo
from .paralelo import LINHAS_MINIMAS_POR_TAREFA
from .expr import Expr, ExprNode, Kind
from .codecs import bits_para_real64, bits_para_real32


struct PTipo:
    """Tipo fisico da coluna no Parquet."""

    comptime BOOLEAN = 0
    comptime INT32 = 1
    comptime INT64 = 2
    comptime INT96 = 3
    comptime FLOAT = 4
    comptime DOUBLE = 5
    comptime BYTE_ARRAY = 6
    comptime FLBA = 7


struct PConvertido:
    """Tipo logico legado (`ConvertedType`), suficiente para o que lemos."""

    comptime NENHUM = -1
    comptime UTF8 = 0
    comptime DATE = 6
    comptime TIME_MILLIS = 7
    comptime TIME_MICROS = 8
    comptime TIMESTAMP_MILLIS = 9
    comptime TIMESTAMP_MICROS = 10
    comptime INT_8 = 15
    comptime INT_16 = 16
    comptime INT_32 = 17
    comptime INT_64 = 18
    # marcador interno: nanossegundos so existem em LogicalType, nao no legado
    comptime TIMESTAMP_NANOS = 100


struct PRepeticao:
    comptime OBRIGATORIO = 0
    comptime OPCIONAL = 1
    comptime REPETIDO = 2


struct PCodificacao:
    comptime PLAIN = 0
    comptime PLAIN_DICTIONARY = 2
    comptime RLE = 3
    comptime BIT_PACKED = 4
    comptime DELTA_BINARY_PACKED = 5
    comptime DELTA_LENGTH_BYTE_ARRAY = 6
    comptime DELTA_BYTE_ARRAY = 7
    comptime RLE_DICTIONARY = 8
    comptime BYTE_STREAM_SPLIT = 9

    @staticmethod
    def nome(c: Int) -> String:
        if c == Self.PLAIN:
            return "PLAIN"
        if c == Self.PLAIN_DICTIONARY:
            return "PLAIN_DICTIONARY"
        if c == Self.RLE:
            return "RLE"
        if c == Self.BIT_PACKED:
            return "BIT_PACKED"
        if c == Self.DELTA_BINARY_PACKED:
            return "DELTA_BINARY_PACKED"
        if c == Self.DELTA_LENGTH_BYTE_ARRAY:
            return "DELTA_LENGTH_BYTE_ARRAY"
        if c == Self.DELTA_BYTE_ARRAY:
            return "DELTA_BYTE_ARRAY"
        if c == Self.RLE_DICTIONARY:
            return "RLE_DICTIONARY"
        if c == Self.BYTE_STREAM_SPLIT:
            return "BYTE_STREAM_SPLIT"
        return "codificacao " + String(c)


struct PCompressao:
    comptime NENHUMA = 0
    comptime SNAPPY = 1
    comptime GZIP = 2
    comptime LZO = 3
    comptime BROTLI = 4
    comptime LZ4 = 5
    comptime ZSTD = 6
    comptime LZ4_RAW = 7

    @staticmethod
    def nome(c: Int) -> String:
        if c == Self.NENHUMA:
            return "sem compressao"
        if c == Self.SNAPPY:
            return "Snappy"
        if c == Self.GZIP:
            return "GZIP"
        if c == Self.LZO:
            return "LZO"
        if c == Self.BROTLI:
            return "Brotli"
        if c == Self.LZ4:
            return "LZ4"
        if c == Self.ZSTD:
            return "Zstd"
        return "LZ4_RAW"


struct PTipoPagina:
    comptime DADOS = 0
    comptime INDICE = 1
    comptime DICIONARIO = 2
    comptime DADOS_V2 = 3


# ------------------------------------------------------------------ esquema


@fieldwise_init
struct ElementoEsquema(Copyable, Movable):
    var nome: String
    var tipo: Int
    var repeticao: Int
    var num_filhos: Int
    var convertido: Int
    var tamanho_tipo: Int


@fieldwise_init
struct ColunaMeta(Copyable, Movable):
    """`ColumnMetaData`: onde estao os bytes da coluna e como estao escritos."""

    var tipo: Int
    var codec: Int
    var num_valores: Int
    var offset_dados: Int
    var offset_dicionario: Int
    var tamanho_comprimido: Int
    var caminho: String
    var codificacoes: List[Int]
    var tem_min_max: Bool
    var min_bits: Int
    var max_bits: Int
    var n_distintos: Int

    def tem_dicionario(self) -> Bool:
        """Ausencia e -1, nao 0. Deslocar o pedaco leva um dicionario no comeco
        do chunk para o offset zero — com 0 como sentinela ele sumiria."""
        return self.offset_dicionario >= 0

    def inicio(self) -> Int:
        """Primeiro byte da coluna: a pagina de dicionario vem antes dos dados."""
        if self.tem_dicionario() and self.offset_dicionario < self.offset_dados:
            return self.offset_dicionario
        return self.offset_dados

    def min_f64(self) -> Float64:
        return _stats_como_f64(self.tipo, self.min_bits)

    def max_f64(self) -> Float64:
        return _stats_como_f64(self.tipo, self.max_bits)

    def min_int(self) -> Int:
        return _stats_como_int(self.tipo, self.min_bits)

    def max_int(self) -> Int:
        return _stats_como_int(self.tipo, self.max_bits)

    def tem_distintos(self) -> Bool:
        """`distinct_count` no rodape. `-1` e ausencia, nao zero distintos."""
        return self.n_distintos >= 0


@fieldwise_init
struct StatsFaixa(Copyable, Movable, ImplicitlyCopyable):
    """min/max e `distinct_count` de uma coluna num row group.

    `n_distintos` e `-1` quando o escritor nao informou. Texto dicionarizado
    emite o NDV do pedaco — os codigos presentes, nao o dicionario herdado da
    fatia, que pode ter valores que este row group nao usa.
    """

    var tem: Bool
    var min_bits: Int
    var max_bits: Int
    var n_distintos: Int


def _stats_como_int(tipo: Int, bits: Int) -> Int:
    """INT32 vem em 4 bytes; o sinal precisa sobreviver a promocao para Int."""
    if tipo == PTipo.INT32:
        var u = bits & 0xFFFFFFFF
        if u >= 0x80000000:
            return u - 0x100000000
        return u
    return bits


def _stats_como_f64(tipo: Int, bits: Int) -> Float64:
    if tipo == PTipo.DOUBLE:
        return bits_para_real64(bits)
    if tipo == PTipo.FLOAT:
        return bits_para_real32(bits)
    return Float64(_stats_como_int(tipo, bits))


def _int_cabe_em_f64(v: Int) -> Bool:
    var a = v
    if a < 0:
        a = -a
    return a <= 9007199254740992


def _ler_le_stats(bytes: List[UInt8], ini: Int, n: Int) -> Int:
    var v = 0
    for i in range(n):
        v |= Int(bytes[ini + i]) << (8 * i)
    return v


def _ler_estatisticas(
    mut l: LeitorThrift, bytes: List[UInt8]
) raises -> StatsFaixa:
    """Campo 12 de ColumnMetaData: distinct_count e min_value/max_value em PLAIN."""
    var tem_min = False
    var tem_max = False
    var min_bits = 0
    var max_bits = 0
    var n_distintos = -1
    l.entrar()
    while True:
        var d = l.campo(bytes)
        if d.tipo == TTipo.STOP:
            break
        if d.id == 4 and (
            d.tipo == TTipo.I64 or d.tipo == TTipo.I32 or d.tipo == TTipo.I16
        ):
            n_distintos = l.zigzag(bytes)
        elif (
            (d.id == 1 or d.id == 2 or d.id == 5 or d.id == 6)
            and d.tipo == TTipo.BINARIO
        ):
            var faixa = l.faixa_binaria(bytes)
            if faixa.tamanho == 4 or faixa.tamanho == 8:
                var bits = _ler_le_stats(bytes, faixa.tipo, faixa.tamanho)
                if d.id == 1 or d.id == 5:
                    max_bits = bits
                    tem_max = True
                else:
                    min_bits = bits
                    tem_min = True
        else:
            l.pular_valor(bytes, d.tipo)
    l.sair()
    return StatsFaixa(tem_min and tem_max, min_bits, max_bits, n_distintos)


@fieldwise_init
struct GrupoLinhas(Copyable, Movable):
    var num_linhas: Int
    var colunas: List[ColunaMeta]


struct MetadadosParquet(Copyable, Movable):
    var versao: Int
    var num_linhas: Int
    var criado_por: String
    var esquema: List[ElementoEsquema]
    var grupos: List[GrupoLinhas]

    def __init__(
        out self,
        versao: Int,
        num_linhas: Int,
        criado_por: String,
        var esquema: List[ElementoEsquema],
        var grupos: List[GrupoLinhas],
    ):
        self.versao = versao
        self.num_linhas = num_linhas
        self.criado_por = criado_por
        self.esquema = esquema^
        self.grupos = grupos^

    def num_colunas(self) -> Int:
        """Esquema plano: o elemento 0 e a raiz, o resto sao as colunas."""
        if len(self.esquema) == 0:
            return 0
        return len(self.esquema) - 1

    def coluna_do_esquema(self, i: Int) raises -> ElementoEsquema:
        if i < 0 or i >= self.num_colunas():
            raise Error("indice de coluna fora do esquema parquet")
        return self.esquema[i + 1].copy()

    def nivel_definicao_max(self, i: Int) raises -> Int:
        """Esquema plano: 1 quando a coluna e opcional, 0 quando obrigatoria."""
        if self.coluna_do_esquema(i).repeticao == PRepeticao.OPCIONAL:
            return 1
        return 0


def _meta_da_coluna(grupo: GrupoLinhas, nome: String) -> Int:
    for i in range(len(grupo.colunas)):
        if grupo.colunas[i].caminho == nome:
            return i
    return -1


def _eh_lit_numerico(k: Int) -> Bool:
    return (
        k == Kind.LIT_F64
        or k == Kind.LIT_I64
        or k == Kind.LIT_DATA
        or k == Kind.LIT_DATAHORA
    )


def _lit_eh_inteiro(k: Int) -> Bool:
    return k == Kind.LIT_I64 or k == Kind.LIT_DATA or k == Kind.LIT_DATAHORA


def _lit_f64(n: ExprNode) -> Float64:
    if n.kind == Kind.LIT_F64:
        return n.f64
    return Float64(n.i64)


def _lit_int(n: ExprNode) -> Int:
    return Int(n.i64)


def _op_invertido(op: Int) -> Int:
    if op == Kind.GT:
        return Kind.LT
    if op == Kind.GE:
        return Kind.LE
    if op == Kind.LT:
        return Kind.GT
    if op == Kind.LE:
        return Kind.GE
    return op


def _nao_casa_int(mn: Int, mx: Int, op: Int, lit: Int) -> Bool:
    if op == Kind.GT:
        return mx <= lit
    if op == Kind.GE:
        return mx < lit
    if op == Kind.LT:
        return mn >= lit
    if op == Kind.LE:
        return mn > lit
    if op == Kind.EQ:
        return lit < mn or lit > mx
    if op == Kind.NE:
        return mn == mx and mn == lit
    return False


def _nao_casa_f64(mn: Float64, mx: Float64, op: Int, lit: Float64) -> Bool:
    if op == Kind.GT:
        return mx <= lit
    if op == Kind.GE:
        return mx < lit
    if op == Kind.LT:
        return mn >= lit
    if op == Kind.LE:
        return mn > lit
    if op == Kind.EQ:
        return lit < mn or lit > mx
    if op == Kind.NE:
        return mn == mx and mn == lit
    return False


def _coluna_inteira(tipo: Int) -> Bool:
    return tipo == PTipo.INT32 or tipo == PTipo.INT64


def _faixa_impossivel(cm: ColunaMeta, op: Int, lit: ExprNode) -> Bool:
    if not cm.tem_min_max:
        return False
    if _coluna_inteira(cm.tipo) and _lit_eh_inteiro(lit.kind):
        return _nao_casa_int(cm.min_int(), cm.max_int(), op, _lit_int(lit))
    if cm.tipo == PTipo.BOOLEAN or cm.tipo == PTipo.BYTE_ARRAY or cm.tipo == PTipo.FLBA:
        return False
    if _coluna_inteira(cm.tipo):
        if not _int_cabe_em_f64(cm.min_int()) or not _int_cabe_em_f64(cm.max_int()):
            return False
    return _nao_casa_f64(cm.min_f64(), cm.max_f64(), op, _lit_f64(lit))


def _impossivel_no(grupo: GrupoLinhas, filtro: Expr, idx: Int) raises -> Bool:
    """True = nenhuma linha do grupo pode satisfazer. Conservador: na duvida, False."""
    if idx < 0 or filtro.vazia():
        return False
    var n = filtro.nodes[idx].copy()
    var k = n.kind
    if k == Kind.AND:
        return (
            _impossivel_no(grupo, filtro, n.left)
            or _impossivel_no(grupo, filtro, n.right)
        )
    if k == Kind.OR:
        return (
            _impossivel_no(grupo, filtro, n.left)
            and _impossivel_no(grupo, filtro, n.right)
        )
    if (
        k != Kind.GT
        and k != Kind.GE
        and k != Kind.LT
        and k != Kind.LE
        and k != Kind.EQ
        and k != Kind.NE
    ):
        return False
    var a = filtro.nodes[n.left].copy()
    var b = filtro.nodes[n.right].copy()
    if a.kind == Kind.COLUNA and _eh_lit_numerico(b.kind):
        var i = _meta_da_coluna(grupo, a.nome)
        if i < 0:
            return False
        return _faixa_impossivel(grupo.colunas[i], k, b)
    if b.kind == Kind.COLUNA and _eh_lit_numerico(a.kind):
        var j = _meta_da_coluna(grupo, b.nome)
        if j < 0:
            return False
        return _faixa_impossivel(grupo.colunas[j], _op_invertido(k), a)
    return False


def grupo_impossivel(grupo: GrupoLinhas, filtro: Expr) raises -> Bool:
    """O row group nao tem nenhuma linha que o predicado aceite.

    So decide com min/max. Sem estatistica, ou predicado que nao e
    `coluna op literal` (e AND/OR disso), devolve False — le o grupo.
    """
    if filtro.vazia():
        return False
    return _impossivel_no(grupo, filtro, filtro.root)


def n_grupos_possiveis(m: MetadadosParquet, filtro: Expr) raises -> Int:
    var n = 0
    for g in m.grupos:
        if not grupo_impossivel(g, filtro):
            n += 1
    return n


def _grupos_a_ler(m: MetadadosParquet, filtro: Expr) raises -> List[Int]:
    var out = List[Int]()
    for g in range(len(m.grupos)):
        if not grupo_impossivel(m.grupos[g], filtro):
            out.append(g)
    return out^


# ----------------------------------------------------------------- parsing


def _ler_unidade_tempo(mut l: LeitorThrift, bytes: List[UInt8]) raises -> Int:
    """`TimeUnit` e uma uniao: MILLIS=1, MICROS=2, NANOS=3, cada uma struct vazia."""
    var unidade = PConvertido.TIMESTAMP_MICROS
    l.entrar()
    while True:
        var c = l.campo(bytes)
        if c.tipo == TTipo.STOP:
            break
        if c.id == 1:
            unidade = PConvertido.TIMESTAMP_MILLIS
        elif c.id == 2:
            unidade = PConvertido.TIMESTAMP_MICROS
        elif c.id == 3:
            unidade = PConvertido.TIMESTAMP_NANOS
        l.pular_valor(bytes, c.tipo)
    l.sair()
    return unidade


def _ler_tipo_logico(mut l: LeitorThrift, bytes: List[UInt8]) raises -> Int:
    """`LogicalType` e uma uniao; so o campo presente importa."""
    var resultado = PConvertido.NENHUM
    l.entrar()
    while True:
        var c = l.campo(bytes)
        if c.tipo == TTipo.STOP:
            break
        if c.id == 1:
            resultado = PConvertido.UTF8
            l.pular_valor(bytes, c.tipo)
        elif c.id == 6:
            resultado = PConvertido.DATE
            l.pular_valor(bytes, c.tipo)
        elif c.id == 8:
            # TimestampType: isAdjustedToUTC (ignorado, nao ha tipo com fuso) + unit
            l.entrar()
            while True:
                var d = l.campo(bytes)
                if d.tipo == TTipo.STOP:
                    break
                if d.id == 2:
                    resultado = _ler_unidade_tempo(l, bytes)
                else:
                    l.pular_valor(bytes, d.tipo)
            l.sair()
        else:
            l.pular_valor(bytes, c.tipo)
    l.sair()
    return resultado


def _ler_esquema(
    mut l: LeitorThrift, bytes: List[UInt8], n: Int
) raises -> List[ElementoEsquema]:
    var out = List[ElementoEsquema]()
    for _ in range(n):
        var tipo = -1
        var repeticao = PRepeticao.OBRIGATORIO
        var nome = String("")
        var filhos = 0
        var convertido = PConvertido.NENHUM
        var tamanho_tipo = 0
        l.entrar()
        while True:
            var c = l.campo(bytes)
            if c.tipo == TTipo.STOP:
                break
            if c.id == 1:
                tipo = l.zigzag(bytes)
            elif c.id == 2:
                tamanho_tipo = l.zigzag(bytes)
            elif c.id == 3:
                repeticao = l.zigzag(bytes)
            elif c.id == 4:
                nome = l.texto(bytes)
            elif c.id == 5:
                filhos = l.zigzag(bytes)
            elif c.id == 6:
                if convertido == PConvertido.NENHUM:
                    convertido = l.zigzag(bytes)
                else:
                    _ = l.zigzag(bytes)
            elif c.id == 10:
                # LogicalType e a forma moderna e mais precisa: o legado nao
                # distingue timestamp com e sem fuso, nem chega a nanossegundos
                convertido = _ler_tipo_logico(l, bytes)
            else:
                l.pular_valor(bytes, c.tipo)
        l.sair()
        out.append(
            ElementoEsquema(nome, tipo, repeticao, filhos, convertido, tamanho_tipo)
        )
    return out^


def _ler_coluna_meta(mut l: LeitorThrift, bytes: List[UInt8]) raises -> ColunaMeta:
    var tipo = -1
    var codec = PCompressao.NENHUMA
    var num_valores = 0
    var offset_dados = 0
    var offset_dic = -1
    var comprimido = 0
    var caminho = String("")
    var codificacoes = List[Int]()
    var tem_min_max = False
    var min_bits = 0
    var max_bits = 0
    var n_distintos = -1

    l.entrar()
    while True:
        var c = l.campo(bytes)
        if c.tipo == TTipo.STOP:
            break
        if c.id == 1:
            tipo = l.zigzag(bytes)
        elif c.id == 2:
            var lst = l.lista(bytes)
            for _ in range(lst.tamanho):
                codificacoes.append(l.zigzag(bytes))
        elif c.id == 3:
            var lst = l.lista(bytes)
            for i in range(lst.tamanho):
                var parte = l.texto(bytes)
                if i > 0:
                    caminho += "."
                caminho += parte
        elif c.id == 4:
            codec = l.zigzag(bytes)
        elif c.id == 5:
            num_valores = l.zigzag(bytes)
        elif c.id == 7:
            comprimido = l.zigzag(bytes)
        elif c.id == 9:
            offset_dados = l.zigzag(bytes)
        elif c.id == 11:
            offset_dic = l.zigzag(bytes)
        elif c.id == 12:
            if c.tipo != TTipo.STRUCT:
                l.pular_valor(bytes, c.tipo)
            else:
                var st = _ler_estatisticas(l, bytes)
                tem_min_max = st.tem
                min_bits = st.min_bits
                max_bits = st.max_bits
                n_distintos = st.n_distintos
        else:
            l.pular_valor(bytes, c.tipo)
    l.sair()

    return ColunaMeta(
        tipo,
        codec,
        num_valores,
        offset_dados,
        offset_dic,
        comprimido,
        caminho,
        codificacoes^,
        tem_min_max,
        min_bits,
        max_bits,
        n_distintos,
    )


def _ler_pedaco(mut l: LeitorThrift, bytes: List[UInt8]) raises -> ColunaMeta:
    var meta = ColunaMeta(
        -1, 0, 0, 0, -1, 0, "", List[Int](), False, 0, 0, -1
    )
    var achou = False
    l.entrar()
    while True:
        var c = l.campo(bytes)
        if c.tipo == TTipo.STOP:
            break
        if c.id == 3:
            meta = _ler_coluna_meta(l, bytes)
            achou = True
        else:
            l.pular_valor(bytes, c.tipo)
    l.sair()
    if not achou:
        raise Error("parquet: ColumnChunk sem meta_data (arquivo externo?)")
    return meta^


def _ler_grupo(mut l: LeitorThrift, bytes: List[UInt8]) raises -> GrupoLinhas:
    var colunas = List[ColunaMeta]()
    var num_linhas = 0
    l.entrar()
    while True:
        var c = l.campo(bytes)
        if c.tipo == TTipo.STOP:
            break
        if c.id == 1:
            var lst = l.lista(bytes)
            for _ in range(lst.tamanho):
                colunas.append(_ler_pedaco(l, bytes))
        elif c.id == 3:
            num_linhas = l.zigzag(bytes)
        else:
            l.pular_valor(bytes, c.tipo)
    l.sair()
    return GrupoLinhas(num_linhas, colunas^)


def ler_metadados(bytes: List[UInt8]) raises -> MetadadosParquet:
    """Valida a magica, localiza o rodape e decodifica o `FileMetaData`."""
    var n = len(bytes)
    if n < 12:
        raise Error("parquet: arquivo curto demais para ser valido")
    if not (
        bytes[0] == UInt8(80)
        and bytes[1] == UInt8(65)
        and bytes[2] == UInt8(82)
        and bytes[3] == UInt8(49)
    ):
        raise Error("parquet: magica inicial PAR1 ausente")
    if not (
        bytes[n - 4] == UInt8(80)
        and bytes[n - 3] == UInt8(65)
        and bytes[n - 2] == UInt8(82)
        and bytes[n - 1] == UInt8(49)
    ):
        raise Error("parquet: magica final PAR1 ausente")

    var tamanho = 0
    for i in range(4):
        tamanho |= Int(bytes[n - 8 + i]) << (8 * i)
    var inicio = n - 8 - tamanho
    if inicio < 4:
        raise Error("parquet: tamanho de rodape invalido")
    return _parse_metadados(bytes, inicio)


def _parse_metadados(bytes: List[UInt8], inicio: Int) raises -> MetadadosParquet:
    var l = LeitorThrift(inicio)
    var versao = 0
    var num_linhas = 0
    var criado_por = String("")
    var esquema = List[ElementoEsquema]()
    var grupos = List[GrupoLinhas]()

    l.entrar()
    while True:
        var c = l.campo(bytes)
        if c.tipo == TTipo.STOP:
            break
        if c.id == 1:
            versao = l.zigzag(bytes)
        elif c.id == 2:
            var lst = l.lista(bytes)
            esquema = _ler_esquema(l, bytes, lst.tamanho)
        elif c.id == 3:
            num_linhas = l.zigzag(bytes)
        elif c.id == 4:
            var lst = l.lista(bytes)
            for _ in range(lst.tamanho):
                grupos.append(_ler_grupo(l, bytes))
        elif c.id == 6:
            criado_por = l.texto(bytes)
        else:
            l.pular_valor(bytes, c.tipo)
    l.sair()

    if len(esquema) == 0:
        raise Error("parquet: FileMetaData sem esquema")
    return MetadadosParquet(versao, num_linhas, criado_por, esquema^, grupos^)


def metadados_parquet(caminho: String) raises -> MetadadosParquet:
    """Le so o rodape: nao toca em nenhum byte de dado.

    E leitura por faixa de verdade — o arquivo pode ser maior que a RAM.
    """
    var leitor = LeitorArquivo(caminho)
    var m = _metadados_do_leitor(leitor, caminho)
    leitor.fechar()
    return m^


def _metadados_do_leitor(
    leitor: LeitorArquivo, caminho: String
) raises -> MetadadosParquet:
    if leitor.tamanho < 12:
        raise Error("parquet: arquivo curto demais para ser valido: " + caminho)
    var cabeca = leitor.ler(0, 4)
    if not (
        cabeca[0] == UInt8(80) and cabeca[1] == UInt8(65)
        and cabeca[2] == UInt8(82) and cabeca[3] == UInt8(49)
    ):
        raise Error("parquet: magica inicial PAR1 ausente em " + caminho)

    var cauda = leitor.ler(leitor.tamanho - 8, 8)
    if not (
        cauda[4] == UInt8(80) and cauda[5] == UInt8(65)
        and cauda[6] == UInt8(82) and cauda[7] == UInt8(49)
    ):
        raise Error("parquet: magica final PAR1 ausente em " + caminho)

    var tamanho = 0
    for i in range(4):
        tamanho |= Int(cauda[i]) << (8 * i)
    var inicio = leitor.tamanho - 8 - tamanho
    if inicio < 4:
        raise Error("parquet: tamanho de rodape invalido em " + caminho)

    var rodape = leitor.ler(inicio, tamanho)
    return _parse_metadados(rodape, 0)


def _deslocar(meta: ColunaMeta, base: Int) -> ColunaMeta:
    """Copia a metadata com os deslocamentos relativos ao buffer local."""
    var dic = meta.offset_dicionario
    if dic >= 0:
        dic -= base
    return ColunaMeta(
        meta.tipo, meta.codec, meta.num_valores, meta.offset_dados - base, dic,
        meta.tamanho_comprimido, meta.caminho, meta.codificacoes.copy(),
        meta.tem_min_max, meta.min_bits, meta.max_bits, meta.n_distintos,
    )


struct VarreduraParquet(Movable):
    """Le um Parquet **row group por row group**, sem carregar o arquivo.

    Cada pedaco de coluna e lido na sua propria faixa de bytes: as colunas nao
    pedidas nunca saem do disco, e o pico de memoria e o de um row group das
    colunas pedidas — nao o do arquivo.
    """

    var leitor: LeitorArquivo
    var metadados: MetadadosParquet
    var querer: List[Int]

    def __init__(out self, caminho: String, colunas: List[String]) raises:
        self.leitor = LeitorArquivo(caminho)
        self.metadados = _metadados_do_leitor(self.leitor, caminho)
        self.querer = indices_das_colunas(self.metadados, colunas)

    def n_grupos(self) -> Int:
        return len(self.metadados.grupos)

    def n_linhas(self) -> Int:
        return self.metadados.num_linhas

    def linhas_do_grupo(self, g: Int) -> Int:
        return self.metadados.grupos[g].num_linhas

    def ler_grupo(self, g: Int) raises -> List[Coluna]:
        ref grupo = self.metadados.grupos[g]
        var saida = List[Coluna]()
        for c in self.querer:
            var e = self.metadados.coluna_do_esquema(c)
            var tipo_tucano = _tipo_tucano(e)
            var escala = 0
            if e.convertido == PConvertido.TIMESTAMP_MILLIS:
                escala = 1
            elif e.convertido == PConvertido.TIMESTAMP_NANOS:
                escala = -1
            var def_max = self.metadados.nivel_definicao_max(c)

            ref cm = grupo.colunas[c]
            var base = cm.inicio()
            var bytes = self.leitor.ler(base, cm.tamanho_comprimido)
            var local = _deslocar(cm, base)

            var acc = _Acumulador()
            acc.reservar(grupo.num_linhas, tipo_tucano)
            var dic = DicionarioBytes()
            var usou = False
            for _ in range(1):
                _ler_pedaco_coluna(
                    bytes, local, def_max, tipo_tucano, escala,
                    grupo.num_linhas, acc, dic, usou,
                )
            saida.append(_montar_coluna(e.nome, tipo_tucano, acc^, dic^, usou))
        return saida^

    def fechar(self):
        self.leitor.fechar()


# ------------------------------------------------------------------ paginas

from .codecs import (
    descomprimir_snappy,
    decodificar_delta_i64,
    codificar_delta_i64,
    comprimir_snappy,
    decodificar_rle,
    decodificar_rle_i32,
    preencher_rle_i32,
    remapeia_i32,
    rle_valor_unico,
    largura_de_bits,
)
from std.collections import Dict
from .coluna import Coluna
from .buffer import StringStore
from .executor import coletar_linhas
from .dtype import DType
from .schema import Campo, Schema
from .erros import erro_coluna


@fieldwise_init
struct CabecalhoPagina(Copyable, Movable):
    var tipo: Int
    var tamanho_descomprimido: Int
    var tamanho_comprimido: Int
    var num_valores: Int
    var codificacao: Int
    var codificacao_def: Int
    var bytes_niveis_def: Int
    var bytes_niveis_rep: Int
    var comprimida_v2: Bool
    var fim_cabecalho: Int


def _ler_cabecalho_pagina(bytes: List[UInt8], pos: Int) raises -> CabecalhoPagina:
    """Decodifica o `PageHeader`.

    Cada tipo de pagina tem seu proprio mapa de campos, e eles nao coincidem:
    o campo 3 e `definition_level_encoding` numa pagina de dados e `is_sorted`
    numa pagina de dicionario. `is_sorted` e booleano, e no Thrift compact
    booleano nao gasta byte de valor — le-lo como varint desalinha todo o resto
    do cabecalho e faz o offset dos dados apontar para lixo.
    """
    var l = LeitorThrift(pos)
    var tipo = -1
    var desc = 0
    var comp = 0
    var num_valores = 0
    var codificacao = PCodificacao.PLAIN
    var codificacao_def = PCodificacao.RLE
    var bytes_def = 0
    var bytes_rep = 0
    var comprimida_v2 = True

    l.entrar()
    while True:
        var c = l.campo(bytes)
        if c.tipo == TTipo.STOP:
            break

        if c.id == 1:
            tipo = l.zigzag(bytes)
        elif c.id == 2:
            desc = l.zigzag(bytes)
        elif c.id == 3:
            comp = l.zigzag(bytes)

        elif c.id == 5:
            # DataPageHeader: num_values, encoding, def_enc, rep_enc, stats
            l.entrar()
            while True:
                var d = l.campo(bytes)
                if d.tipo == TTipo.STOP:
                    break
                if d.id == 1:
                    num_valores = l.zigzag(bytes)
                elif d.id == 2:
                    codificacao = l.zigzag(bytes)
                elif d.id == 3:
                    codificacao_def = l.zigzag(bytes)
                else:
                    l.pular_valor(bytes, d.tipo)
            l.sair()

        elif c.id == 7:
            # DictionaryPageHeader: num_values, encoding, is_sorted (BOOL)
            l.entrar()
            while True:
                var d = l.campo(bytes)
                if d.tipo == TTipo.STOP:
                    break
                if d.id == 1:
                    num_valores = l.zigzag(bytes)
                elif d.id == 2:
                    codificacao = l.zigzag(bytes)
                else:
                    l.pular_valor(bytes, d.tipo)
            l.sair()

        elif c.id == 8:
            # DataPageHeaderV2: os niveis tem tamanho declarado e ficam fora
            # da compressao
            l.entrar()
            while True:
                var d = l.campo(bytes)
                if d.tipo == TTipo.STOP:
                    break
                if d.id == 1:
                    num_valores = l.zigzag(bytes)
                elif d.id == 4:
                    codificacao = l.zigzag(bytes)
                elif d.id == 5:
                    bytes_def = l.zigzag(bytes)
                elif d.id == 6:
                    bytes_rep = l.zigzag(bytes)
                elif d.id == 7:
                    comprimida_v2 = d.tipo == TTipo.BOOL_TRUE
                else:
                    l.pular_valor(bytes, d.tipo)
            l.sair()

        else:
            l.pular_valor(bytes, c.tipo)
    l.sair()

    return CabecalhoPagina(
        tipo, desc, comp, num_valores, codificacao, codificacao_def,
        bytes_def, bytes_rep, comprimida_v2, l.pos,
    )


def _descomprimir(
    bytes: List[UInt8], ini: Int, comprimido: Int, descomprimido: Int, codec: Int
) raises -> List[UInt8]:
    if codec == PCompressao.NENHUMA:
        # `memcpy` em vez de laco byte a byte: 46 ms contra 64 por 40 MiB, e sem
        # checagem de limite por byte. E copia pura — nao ha o que interpretar.
        var out = List[UInt8](capacity=comprimido)
        out.resize(unsafe_uninit_length=comprimido)
        if comprimido > 0:
            _ = external_call["memcpy", Int](
                out.unsafe_ptr(), bytes.unsafe_ptr().unsafe_offset(ini), comprimido
            )
        return out^
    if codec == PCompressao.SNAPPY:
        return descomprimir_snappy(bytes, ini, ini + comprimido)
    raise Error(
        "parquet: compressao "
        + PCompressao.nome(codec)
        + " ainda nao suportada (ha suporte a sem compressao e Snappy)"
    )


# ---------------------------------------------------------- valores PLAIN


def _int32(b: List[UInt8], pos: Int) -> Int:
    var v = 0
    var p = b.unsafe_ptr()
    for i in range(4):
        v |= Int(p.unsafe_load(pos + i)) << (8 * i)
    if v >= 0x80000000:
        v -= 0x100000000
    return v


def _int64(b: List[UInt8], pos: Int) -> Int:
    var v = 0
    var p = b.unsafe_ptr()
    for i in range(8):
        v |= Int(p.unsafe_load(pos + i)) << (8 * i)
    return v


def _double(b: List[UInt8], pos: Int) -> Float64:
    return bits_para_real64(_int64(b, pos))


def _float(b: List[UInt8], pos: Int) -> Float64:
    var v = 0
    for i in range(4):
        v |= Int(b[pos + i]) << (8 * i)
    return bits_para_real32(v)


struct ValoresPagina(Copyable, Movable):
    """Valores presentes de uma pagina, ja fora da codificacao."""

    var inteiros: List[Int64]
    var reais: List[Float64]
    var logicos: List[Bool]
    var textos: List[String]

    def __init__(out self):
        self.inteiros = List[Int64]()
        self.reais = List[Float64]()
        self.logicos = List[Bool]()
        self.textos = List[String]()


def _ler_plain_denso(
    b: List[UInt8],
    ini: Int,
    fim: Int,
    tipo: Int,
    quantidade: Int,
    tipo_tucano: Int,
    escala: Int,
    mut acc: _Acumulador,
) raises -> Bool:
    """Decodifica PLAIN direto no acumulador, quando nao ha ausentes.

    PLAIN de INT64/DOUBLE **ja e** a representacao em memoria: little-endian,
    largura fixa, sem preenchimento. Decodificar e copiar. O que impedia a copia
    em bloco era o alinhamento — os valores comecam depois dos niveis de
    definicao, em deslocamento qualquer, e uma carga de 8 bytes em endereco nao
    alinhado nao e segura de assumir. Mas isso vale para carga reinterpretada,
    nao para `memcpy`, que trata desalinhamento por contrato. Montar cada valor
    com oito deslocamentos custava 65 ms por coluna de 5 milhoes; a copia custa
    o que a memoria cobra.

    Assume maquina little-endian, o que vale para x86-64 e ARM64.

    Devolve False quando o tipo nao tem caminho denso — o chamador cai no geral.
    """
    var p = b.unsafe_ptr()

    if tipo == PTipo.DOUBLE and tipo_tucano == DType.REAL:
        if ini + quantidade * 8 > fim:
            raise Error("parquet: PLAIN double truncado")
        var antes = len(acc.reais)
        acc.reais.resize(unsafe_uninit_length=antes + quantidade)
        if quantidade > 0:
            _ = external_call["memcpy", Int](
                acc.reais.unsafe_ptr().unsafe_offset(antes).unsafe_bitcast[UInt8](), p.unsafe_offset(ini), quantidade * 8
            )
        _marcar_presentes(acc, quantidade)
        return True

    if tipo == PTipo.INT64 and tipo_tucano != DType.REAL and escala == 0:
        if ini + quantidade * 8 > fim:
            raise Error("parquet: PLAIN int64 truncado")
        var antes = len(acc.inteiros)
        acc.inteiros.resize(unsafe_uninit_length=antes + quantidade)
        if quantidade > 0:
            _ = external_call["memcpy", Int](
                acc.inteiros.unsafe_ptr().unsafe_offset(antes).unsafe_bitcast[UInt8](), p.unsafe_offset(ini), quantidade * 8
            )
        _marcar_presentes(acc, quantidade)
        return True

    if tipo == PTipo.INT32 and tipo_tucano != DType.REAL and escala == 0:
        if ini + quantidade * 4 > fim:
            raise Error("parquet: PLAIN int32 truncado")
        # int32 nao e copia pura: o slab do Tucano e de 64 bits. Ainda assim vale
        # copiar primeiro e alargar depois — o alargamento le de um buffer
        # alinhado, com um valor por iteracao em vez de quatro bytes.
        var estreitos = List[Int32](capacity=quantidade)
        estreitos.resize(unsafe_uninit_length=quantidade)
        if quantidade > 0:
            _ = external_call["memcpy", Int](
                estreitos.unsafe_ptr().unsafe_bitcast[UInt8](), p.unsafe_offset(ini), quantidade * 4
            )
        var antes = len(acc.inteiros)
        acc.inteiros.resize(unsafe_uninit_length=antes + quantidade)
        var destino = acc.inteiros.unsafe_ptr().unsafe_offset(antes)
        var origem = estreitos.unsafe_ptr()
        for i in range(quantidade):
            destino.unsafe_store(i, Int64(origem.unsafe_load(i)))
        _marcar_presentes(acc, quantidade)
        return True

    return False


def _marcar_presentes(mut acc: _Acumulador, quantidade: Int):
    """Estende a mascara de ausentes com `quantidade` presencas.

    Se ainda nao apareceu nenhum nulo, nao materializa a lista: so conta.
    """
    if len(acc.ausentes) > 0:
        acc.ausentes.resize(len(acc.ausentes) + quantidade, False)
    acc.n += quantidade


def _ler_plain(
    b: List[UInt8], ini: Int, fim: Int, tipo: Int, quantidade: Int, mut out: ValoresPagina
) raises:
    var pos = ini
    if tipo == PTipo.BOOLEAN:
        # 1 bit por valor, do menos ao mais significativo
        for i in range(quantidade):
            var byte_i = pos + i // 8
            if byte_i >= fim:
                raise Error("parquet: PLAIN booleano truncado")
            out.logicos.append(((Int(b[byte_i]) >> (i % 8)) & 1) == 1)
        return
    if tipo == PTipo.INT32:
        for _ in range(quantidade):
            if pos + 4 > fim:
                raise Error("parquet: PLAIN int32 truncado")
            out.inteiros.append(Int64(_int32(b, pos)))
            pos += 4
        return
    if tipo == PTipo.INT64:
        for _ in range(quantidade):
            if pos + 8 > fim:
                raise Error("parquet: PLAIN int64 truncado")
            out.inteiros.append(Int64(_int64(b, pos)))
            pos += 8
        return
    if tipo == PTipo.DOUBLE:
        for _ in range(quantidade):
            if pos + 8 > fim:
                raise Error("parquet: PLAIN double truncado")
            out.reais.append(_double(b, pos))
            pos += 8
        return
    if tipo == PTipo.FLOAT:
        for _ in range(quantidade):
            if pos + 4 > fim:
                raise Error("parquet: PLAIN float truncado")
            out.reais.append(_float(b, pos))
            pos += 4
        return
    if tipo == PTipo.BYTE_ARRAY:
        for _ in range(quantidade):
            if pos + 4 > fim:
                raise Error("parquet: PLAIN byte array truncado")
            var n = 0
            for i in range(4):
                n |= Int(b[pos + i]) << (8 * i)
            pos += 4
            if pos + n > fim:
                raise Error("parquet: byte array ultrapassa a pagina")
            if n == 0:
                out.textos.append("")
            else:
                out.textos.append(String(from_utf8=Span(b)[pos : pos + n]))
            pos += n
        return
    raise Error("parquet: tipo fisico " + String(tipo) + " ainda nao suportado")


# ------------------------------------------------------------- montagem


def _tipo_tucano(e: ElementoEsquema) raises -> Int:
    """Tipo fisico + tipo convertido -> tipo logico do Tucano."""
    if e.tipo == PTipo.BOOLEAN:
        return DType.LOGICO
    if e.tipo == PTipo.BYTE_ARRAY or e.tipo == PTipo.FLBA:
        return DType.TEXTO
    if e.tipo == PTipo.FLOAT or e.tipo == PTipo.DOUBLE:
        return DType.REAL
    if e.tipo == PTipo.INT32:
        if e.convertido == PConvertido.DATE:
            return DType.DATA
        return DType.INTEIRO
    if e.tipo == PTipo.INT64:
        if (
            e.convertido == PConvertido.TIMESTAMP_MICROS
            or e.convertido == PConvertido.TIMESTAMP_MILLIS
            or e.convertido == PConvertido.TIMESTAMP_NANOS
        ):
            return DType.DATAHORA
        return DType.INTEIRO
    raise Error(
        "parquet: coluna '" + e.nome + "' usa tipo fisico " + String(e.tipo)
        + ", ainda nao suportado"
    )


struct DicionarioBytes(Movable):
    """Dicionariza faixas de bytes sem criar `String` por valor.

    O caminho ingenuo cria uma `String` por linha so para descobrir que ela ja
    apareceu — 5 milhoes de alocacoes para achar 24 valores distintos. Aqui o
    hash e calculado sobre os bytes, e so um valor **novo** vira texto.

    A tabela e de enderecamento aberto num vetor plano, nao um `Dict` de listas.
    A diferenca importa porque esta e a pergunta feita uma vez por linha do
    arquivo: com balde encadeado eram duas buscas no `Dict` mais a copia da
    lista do balde por valor; aqui e um hash, uma sondagem linear e — so quando
    o hash bate — a confirmacao byte a byte. O hash de cada codigo fica
    guardado justamente para que a confirmacao quase nunca precise acontecer.

    Colisao de hash nao e problema: a confirmacao final e sempre byte a byte.
    """

    var tabela: List[Int32]
    var mascara: Int
    var hashes: List[Int]
    var bytes: List[UInt8]
    var inicios: List[Int]
    var fins: List[Int]

    def __init__(out self):
        self.tabela = List[Int32]()
        self.tabela.resize(1024, Int32(-1))
        self.mascara = 1023
        self.hashes = List[Int]()
        self.bytes = List[UInt8]()
        self.inicios = List[Int]()
        self.fins = List[Int]()

    def distintos(self) -> Int:
        return len(self.inicios)

    def _igual(self, codigo: Int, origem: List[UInt8], ini: Int, fim: Int) -> Bool:
        var a = self.inicios[codigo]
        var z = self.fins[codigo]
        if z - a != fim - ini:
            return False
        var meus = self.bytes.unsafe_ptr()
        var outros = origem.unsafe_ptr()
        var n = z - a
        var k = 0
        # compara de 8 em 8 pelo mesmo motivo do hash: o valor confirmado e lido
        # inteiro uma vez por linha do arquivo
        while k + 8 <= n:
            var x = meus.unsafe_offset(a + k).unsafe_bitcast[Int64]().unsafe_load[alignment=1]()
            var y = outros.unsafe_offset(ini + k).unsafe_bitcast[Int64]().unsafe_load[alignment=1]()
            if x != y:
                return False
            k += 8
        while k < n:
            if meus.unsafe_load(a + k) != outros.unsafe_load(ini + k):
                return False
            k += 1
        return True

    def _crescer(mut self):
        """Dobra a tabela e reinsere pelos hashes ja guardados."""
        var tamanho = len(self.tabela) * 2
        self.tabela = List[Int32]()
        self.tabela.resize(tamanho, Int32(-1))
        self.mascara = tamanho - 1
        var t = self.tabela.unsafe_ptr()
        for c in range(len(self.hashes)):
            var idx = self.hashes[c] & self.mascara
            while t.unsafe_load(idx) >= 0:
                idx = (idx + 1) & self.mascara
            t.unsafe_store(idx, Int32(c))

    def codigo_de(
        mut self, origem: List[UInt8], ini: Int, fim: Int
    ) raises -> Int32:
        # FNV-1a de 64 bits, consumindo 8 bytes por rodada onde da.
        # Esta e a unica operacao feita uma vez por linha do arquivo em coluna
        # de texto PLAIN, entao o custo dela e por byte da string: byte a byte,
        # uma string de 12 caracteres custava 12 rodadas. O comprimento entra no
        # estado inicial para que prefixos iguais de tamanhos diferentes nao
        # convirjam. Colisao continua sem consequencia: quem decide e o `_igual`.
        var h = 0xCBF29CE484222325 ^ (fim - ini)
        var p = origem.unsafe_ptr()
        var i = ini
        while i + 8 <= fim:
            var bloco = Int(
                p.unsafe_offset(i).unsafe_bitcast[Int64]().unsafe_load[alignment=1]()
            )
            h = (h ^ bloco) * 0x100000001B3
            i += 8
        while i < fim:
            h = (h ^ Int(p.unsafe_load(i))) * 0x100000001B3
            i += 1
        h &= 0xFFFFFFFFFFFFFFFF

        var idx = h & self.mascara
        var t = self.tabela.unsafe_ptr()
        while True:
            var c = t.unsafe_load(idx)
            if c < 0:
                break
            if self.hashes[Int(c)] == h and self._igual(Int(c), origem, ini, fim):
                return c
            idx = (idx + 1) & self.mascara

        var novo = Int32(len(self.inicios))
        self.inicios.append(len(self.bytes))
        for i in range(ini, fim):
            self.bytes.append(p.unsafe_load(i))
        self.fins.append(len(self.bytes))
        self.hashes.append(h)
        self.tabela[idx] = novo
        # metade cheia ja e o limite: sondagem linear degrada rapido depois disso
        if len(self.inicios) * 2 >= len(self.tabela):
            self._crescer()
        return novo

    def para_store(self) raises -> StringStore:
        var valores = List[String](capacity=len(self.inicios))
        for i in range(len(self.inicios)):
            if self.fins[i] == self.inicios[i]:
                valores.append("")
            else:
                valores.append(
                    String(from_utf8=Span(self.bytes)[self.inicios[i] : self.fins[i]])
                )
        return StringStore.de_valores(valores)


struct _Acumulador(Copyable, Movable):
    """Junta os valores de uma coluna ao longo de todos os row groups."""

    var inteiros: List[Int64]
    var reais: List[Float64]
    var logicos: List[Bool]
    var textos: List[String]
    var ausentes: List[Bool]
    var codigos: List[Int32]
    var n: Int

    def __init__(out self):
        self.inteiros = List[Int64]()
        self.reais = List[Float64]()
        self.logicos = List[Bool]()
        self.textos = List[String]()
        self.ausentes = List[Bool]()
        self.codigos = List[Int32]()
        self.n = 0

    def linhas(self) -> Int:
        return self.n

    def tomar_inteiros(mut self) -> List[Int64]:
        """Entrega o vetor de inteiros, deixando o acumulador vazio no lugar.

        A coluna assume o vetor em vez de copia-lo, e o Mojo nao deixa mover um
        campo para fora de um valor que ainda sera destruido — a troca por um
        vetor vazio da o mesmo efeito sem deixar o acumulador em meio-estado.
        """
        var fora = List[Int64]()
        swap(fora, self.inteiros)
        return fora^

    def tomar_reais(mut self) -> List[Float64]:
        var fora = List[Float64]()
        swap(fora, self.reais)
        return fora^

    def tomar_ausentes(mut self) -> List[Bool]:
        var fora = List[Bool]()
        swap(fora, self.ausentes)
        return fora^

    def tomar_codigos(mut self) -> List[Int32]:
        var fora = List[Int32]()
        swap(fora, self.codigos)
        return fora^

    def reservar(mut self, linhas: Int, tipo_tucano: Int):
        """Reserva de uma vez o espaco da coluna inteira.

        O rodape do Parquet ja diz quantas linhas o arquivo tem, entao a unica
        realocacao possivel e nenhuma. Sem isso, crescer por row group realoca a
        cada grupo e a copia acumulada vira quadratica no numero de grupos —
        50 grupos custaram 10 GiB de memoria movida a toa.

        Reserva so a lista do tipo em questao: reservar as seis custaria 21
        bytes por linha para usar 8.
        """
        # a mascara de ausentes so e materializada se aparecer um nulo.
        # reservar 5 milhoes de Bool para descobrir que nenhum veio e
        # escrever 5 MiB a toa.
        if tipo_tucano == DType.REAL:
            self.reais.reserve(linhas)
        elif tipo_tucano == DType.TEXTO:
            self.codigos.reserve(linhas)
        elif tipo_tucano == DType.LOGICO:
            self.logicos.reserve(linhas)
        else:
            self.inteiros.reserve(linhas)


def _abrir_ausentes(mut acc: _Acumulador):
    """Materializa a mascara so na primeira ausencia.

    Ate la `ausentes` fica vazio e `_montar_coluna` usa `todos_presentes`.
    """
    if len(acc.ausentes) == 0 and acc.n > 0:
        acc.ausentes.resize(acc.n, False)


def _emitir(
    mut acc: _Acumulador,
    tipo_tucano: Int,
    presente: Bool,
    vals: ValoresPagina,
    idx: Int,
    escala: Int,
):
    """Acrescenta uma linha, com placeholder quando ausente."""
    if not presente:
        _abrir_ausentes(acc)
        acc.ausentes.append(True)
    elif len(acc.ausentes) > 0:
        acc.ausentes.append(False)
    acc.n += 1
    if tipo_tucano == DType.LOGICO:
        if presente:
            acc.logicos.append(vals.logicos[idx])
        else:
            acc.logicos.append(False)
    elif tipo_tucano == DType.TEXTO:
        if presente:
            acc.textos.append(vals.textos[idx])
        else:
            acc.textos.append("")
    elif tipo_tucano == DType.REAL:
        if presente:
            acc.reais.append(vals.reais[idx])
        else:
            acc.reais.append(0.0)
    else:
        if presente:
            var v = vals.inteiros[idx]
            if escala > 0:
                v *= 1000  # milissegundos -> microssegundos
            elif escala < 0:
                v //= 1000  # nanossegundos -> microssegundos
            acc.inteiros.append(v)
        else:
            acc.inteiros.append(Int64(0))


def _valores_do_dicionario(
    dic: ValoresPagina, indices: List[Int], tipo: Int
) raises -> ValoresPagina:
    var out = ValoresPagina()
    for i in indices:
        if tipo == PTipo.BOOLEAN:
            out.logicos.append(dic.logicos[i])
        elif tipo == PTipo.BYTE_ARRAY or tipo == PTipo.FLBA:
            out.textos.append(dic.textos[i])
        elif tipo == PTipo.FLOAT or tipo == PTipo.DOUBLE:
            out.reais.append(dic.reais[i])
        else:
            out.inteiros.append(dic.inteiros[i])
    return out^


def _espalhar_codigos(
    mut acc: _Acumulador,
    codigos: List[Int32],
    niveis: List[Int],
    def_max: Int,
    n: Int,
) raises:
    """Espalha indices presentes nas linhas, preenchendo ausentes com 0."""
    var prox = 0
    for i in range(n):
        var presente = niveis[i] == def_max
        if not presente:
            _abrir_ausentes(acc)
            acc.ausentes.append(True)
        elif len(acc.ausentes) > 0:
            acc.ausentes.append(False)
        if presente:
            acc.codigos.append(codigos[prox])
            prox += 1
        else:
            acc.codigos.append(Int32(0))
        acc.n += 1


def _gather_dicionario(
    mut acc: _Acumulador,
    dic: ValoresPagina,
    indices: List[Int32],
    niveis: List[Int],
    def_max: Int,
    n: Int,
    todos: Bool,
    tipo_tucano: Int,
    escala: Int,
) raises:
    """Materializa valores de um dicionario numerico no acumulador.

    O caminho antigo expandia `ValoresPagina` com um valor por linha e depois
    `_emitir` de novo. Sao duas alocacoes e dois lacos onde basta um gather
    sobre a tabela pequena do dicionario.
    """
    var n_dic = len(dic.inteiros)
    if tipo_tucano == DType.REAL:
        n_dic = len(dic.reais)

    if todos:
        if tipo_tucano == DType.REAL:
            var antes = len(acc.reais)
            acc.reais.resize(unsafe_uninit_length=antes + n)
            var dest = acc.reais.unsafe_ptr().unsafe_offset(antes)
            var tab = dic.reais.unsafe_ptr()
            var idx = indices.unsafe_ptr()
            for i in range(n):
                var k = Int(idx.unsafe_load(i))
                if k < 0 or k >= n_dic:
                    raise Error("parquet: indice de dicionario fora da pagina")
                dest.unsafe_store(i, tab.unsafe_load(k))
        else:
            var antes = len(acc.inteiros)
            acc.inteiros.resize(unsafe_uninit_length=antes + n)
            var dest = acc.inteiros.unsafe_ptr().unsafe_offset(antes)
            var tab = dic.inteiros.unsafe_ptr()
            var idx = indices.unsafe_ptr()
            for i in range(n):
                var k = Int(idx.unsafe_load(i))
                if k < 0 or k >= n_dic:
                    raise Error("parquet: indice de dicionario fora da pagina")
                var v = tab.unsafe_load(k)
                if escala > 0:
                    v *= 1000
                elif escala < 0:
                    v //= 1000
                dest.unsafe_store(i, v)
        _marcar_presentes(acc, n)
        return

    var prox = 0
    for i in range(n):
        var presente = niveis[i] == def_max
        var k = 0
        if presente:
            k = Int(indices[prox])
            prox += 1
            if k < 0 or k >= n_dic:
                raise Error("parquet: indice de dicionario fora da pagina")
        if tipo_tucano == DType.REAL:
            if presente:
                acc.reais.append(dic.reais[k])
            else:
                acc.reais.append(0.0)
        else:
            if presente:
                var v = dic.inteiros[k]
                if escala > 0:
                    v *= 1000
                elif escala < 0:
                    v //= 1000
                acc.inteiros.append(v)
            else:
                acc.inteiros.append(Int64(0))
        if not presente:
            _abrir_ausentes(acc)
            acc.ausentes.append(True)
        elif len(acc.ausentes) > 0:
            acc.ausentes.append(False)
        acc.n += 1


def _faixas_byte_array(
    b: List[UInt8], ini: Int, fim: Int, quantidade: Int, mut dic: DicionarioBytes
) raises -> List[Int32]:
    """Percorre byte arrays PLAIN e devolve o codigo de cada um."""
    var out = List[Int32](capacity=quantidade)
    out.resize(unsafe_uninit_length=quantidade)
    var destino = out.unsafe_ptr()
    var pos = ini
    var p = b.unsafe_ptr()
    for k in range(quantidade):
        if pos + 4 > fim:
            raise Error("parquet: PLAIN byte array truncado")
        # comprimento little-endian de 4 bytes
        var n = (
            Int(p.unsafe_load(pos))
            | (Int(p.unsafe_load(pos + 1)) << 8)
            | (Int(p.unsafe_load(pos + 2)) << 16)
            | (Int(p.unsafe_load(pos + 3)) << 24)
        )
        pos += 4
        if pos + n > fim:
            raise Error("parquet: byte array ultrapassa a pagina")
        destino.unsafe_store(k, dic.codigo_de(b, pos, pos + n))
        pos += n
    return out^


def _ler_pedaco_coluna(
    bytes: List[UInt8],
    meta: ColunaMeta,
    def_max: Int,
    tipo_tucano: Int,
    escala: Int,
    linhas_do_grupo: Int,
    mut acc: _Acumulador,
    mut dic: DicionarioBytes,
    mut usou_dicionario: Bool,
) raises:
    var pos = meta.inicio()
    var limite = pos + meta.tamanho_comprimido
    var dicionario = ValoresPagina()
    var mapa_dicionario = List[Int32]()
    var tem_dicionario = False
    var lidas = 0

    while lidas < linhas_do_grupo and pos < limite:
        var cab = _ler_cabecalho_pagina(bytes, pos)
        var corpo = cab.fim_cabecalho

        if cab.tipo == PTipoPagina.DICIONARIO:
            var dados = _descomprimir(
                bytes, corpo, cab.tamanho_comprimido, cab.tamanho_descomprimido,
                meta.codec,
            )
            if tipo_tucano == DType.TEXTO:
                # os valores do dicionario da pagina viram codigos globais aqui,
                # uma vez — depois cada linha e so um indice trocado por outro
                mapa_dicionario = _faixas_byte_array(
                    dados, 0, len(dados), cab.num_valores, dic
                )
            else:
                dicionario = ValoresPagina()
                _ler_plain(
                    dados, 0, len(dados), meta.tipo, cab.num_valores, dicionario
                )
            tem_dicionario = True
            pos = corpo + cab.tamanho_comprimido
            continue

        if cab.tipo == PTipoPagina.INDICE:
            pos = corpo + cab.tamanho_comprimido
            continue

        var n = cab.num_valores
        var niveis = List[Int]()
        # coluna sem nivel de definicao nao tem ausente por construcao; com
        # nivel, o caso comum e um trecho RLE unico dizendo "todos presentes".
        # Nos dois, `niveis` fica vazio e ninguem paga um Int por linha.
        var todos = def_max == 0
        var dados: List[UInt8]
        var inicio_valores = 0

        if cab.tipo == PTipoPagina.DADOS_V2:
            # V2: os niveis ficam FORA da compressao, antes dos valores
            var p = corpo + cab.bytes_niveis_rep
            if def_max > 0 and cab.bytes_niveis_def > 0:
                var largura_def = largura_de_bits(def_max)
                var fim_def = p + cab.bytes_niveis_def
                if rle_valor_unico(bytes, p, fim_def, largura_def, n) == def_max:
                    todos = True
                else:
                    niveis = decodificar_rle(bytes, p, fim_def, largura_def, n)
            elif def_max > 0:
                # sem bytes de nivel: a especificacao diz todos no nivel maximo
                todos = True
            p += cab.bytes_niveis_def
            var cabecalho_total = cab.bytes_niveis_rep + cab.bytes_niveis_def
            var codec_valores = meta.codec
            if not cab.comprimida_v2:
                codec_valores = PCompressao.NENHUMA
            dados = _descomprimir(
                bytes, p, cab.tamanho_comprimido - cabecalho_total,
                cab.tamanho_descomprimido - cabecalho_total, codec_valores,
            )
        else:
            dados = _descomprimir(
                bytes, corpo, cab.tamanho_comprimido, cab.tamanho_descomprimido,
                meta.codec,
            )
            var p = 0
            # esquema plano: sem niveis de repeticao
            if def_max > 0:
                if cab.codificacao_def != PCodificacao.RLE:
                    raise Error(
                        "parquet: niveis de definicao em "
                        + PCodificacao.nome(cab.codificacao_def)
                        + " ainda nao suportados"
                    )
                var tamanho = 0
                for i in range(4):
                    tamanho |= Int(dados[p + i]) << (8 * i)
                p += 4
                var largura_def = largura_de_bits(def_max)
                if rle_valor_unico(dados, p, p + tamanho, largura_def, n) == def_max:
                    todos = True
                else:
                    niveis = decodificar_rle(dados, p, p + tamanho, largura_def, n)
                p += tamanho
            inicio_valores = p

        var presentes = n
        if not todos:
            presentes = 0
            for d in niveis:
                if d == def_max:
                    presentes += 1

        # texto sempre passa pelo dicionario de bytes: nenhuma `String` por linha
        if tipo_tucano == DType.TEXTO:
            usou_dicionario = True
            if (
                cab.codificacao == PCodificacao.RLE_DICTIONARY
                or cab.codificacao == PCodificacao.PLAIN_DICTIONARY
            ):
                if not tem_dicionario:
                    raise Error(
                        "parquet: pagina com dicionario, mas sem pagina de dicionario"
                    )
                if presentes <= 0:
                    _espalhar_codigos(acc, List[Int32](), niveis, def_max, n)
                    lidas += n
                    pos = corpo + cab.tamanho_comprimido
                    continue
                var largura = Int(dados[inicio_valores])
                if todos:
                    # indices RLE direto no slab da coluna, depois um remap
                    # in-place (o mapa cabe em cache: 24 a 500 entradas)
                    var antes = len(acc.codigos)
                    acc.codigos.resize(unsafe_uninit_length=antes + n)
                    if n > 0:
                        preencher_rle_i32(
                            dados, inicio_valores + 1, len(dados), largura, n,
                            acc.codigos, antes,
                        )
                        remapeia_i32(acc.codigos, antes, n, mapa_dicionario)
                    _marcar_presentes(acc, n)
                    lidas += n
                    pos = corpo + cab.tamanho_comprimido
                    continue
                var indices = decodificar_rle_i32(
                    dados, inicio_valores + 1, len(dados), largura, presentes
                )
                remapeia_i32(indices, 0, presentes, mapa_dicionario)
                _espalhar_codigos(acc, indices, niveis, def_max, n)
                lidas += n
                pos = corpo + cab.tamanho_comprimido
                continue
            if cab.codificacao != PCodificacao.PLAIN:
                raise Error(
                    "parquet: codificacao "
                    + PCodificacao.nome(cab.codificacao)
                    + " ainda nao suportada em coluna de texto"
                )
            var codigos_pagina = _faixas_byte_array(
                dados, inicio_valores, len(dados), presentes, dic
            )

            if todos:
                var antes = len(acc.codigos)
                acc.codigos.resize(unsafe_uninit_length=antes + n)
                if n > 0:
                    _ = external_call["memcpy", Int](
                        acc.codigos.unsafe_ptr().unsafe_offset(antes).unsafe_bitcast[UInt8](),
                        codigos_pagina.unsafe_ptr().unsafe_bitcast[UInt8](),
                        n * 4,
                    )
                _marcar_presentes(acc, n)
            else:
                _espalhar_codigos(acc, codigos_pagina, niveis, def_max, n)
            lidas += n
            pos = corpo + cab.tamanho_comprimido
            continue

        # delta: a coluna guarda diferencas, nao valores
        if cab.codificacao == PCodificacao.DELTA_BINARY_PACKED:
            if tipo_tucano == DType.REAL:
                raise Error(
                    "parquet: DELTA_BINARY_PACKED nao vale para coluna real"
                )
            var brutos = decodificar_delta_i64(
                dados, inicio_valores, len(dados), presentes
            )
            if todos and escala == 0:
                var antes = len(acc.inteiros)
                acc.inteiros.resize(unsafe_uninit_length=antes + n)
                if n > 0:
                    _ = external_call["memcpy", Int](
                        acc.inteiros.unsafe_ptr().unsafe_offset(antes).unsafe_bitcast[UInt8](),
                        brutos.unsafe_ptr().unsafe_bitcast[UInt8](),
                        n * 8,
                    )
                _marcar_presentes(acc, n)
            else:
                var vd = ValoresPagina()
                for x in brutos:
                    vd.inteiros.append(x)
                var proximo = 0
                for i in range(n):
                    var presente = todos or niveis[i] == def_max
                    _emitir(acc, tipo_tucano, presente, vd, proximo, escala)
                    if presente:
                        proximo += 1
            lidas += n
            pos = corpo + cab.tamanho_comprimido
            continue

        # sem ausentes e sem dicionario: escreve direto no acumulador
        if (
            todos
            and cab.codificacao == PCodificacao.PLAIN
            and _ler_plain_denso(
                dados, inicio_valores, len(dados), meta.tipo, n, tipo_tucano,
                escala, acc,
            )
        ):
            lidas += n
            pos = corpo + cab.tamanho_comprimido
            continue

        # dicionario numerico: indices -> gather no slab, sem `_emitir`
        if (
            cab.codificacao == PCodificacao.RLE_DICTIONARY
            or cab.codificacao == PCodificacao.PLAIN_DICTIONARY
        ):
            if not tem_dicionario:
                raise Error("parquet: pagina com dicionario, mas sem pagina de dicionario")
            if meta.tipo != PTipo.BOOLEAN:
                var indices = List[Int32]()
                if presentes > 0:
                    var largura = Int(dados[inicio_valores])
                    indices = decodificar_rle_i32(
                        dados, inicio_valores + 1, len(dados), largura, presentes
                    )
                _gather_dicionario(
                    acc, dicionario, indices, niveis, def_max, n, todos,
                    tipo_tucano, escala,
                )
                lidas += n
                pos = corpo + cab.tamanho_comprimido
                continue

        var vals = ValoresPagina()
        if (
            cab.codificacao == PCodificacao.RLE_DICTIONARY
            or cab.codificacao == PCodificacao.PLAIN_DICTIONARY
        ):
            if not tem_dicionario:
                raise Error("parquet: pagina com dicionario, mas sem pagina de dicionario")
            var largura = Int(dados[inicio_valores])
            var indices = decodificar_rle(
                dados, inicio_valores + 1, len(dados), largura, presentes
            )
            vals = _valores_do_dicionario(dicionario, indices, meta.tipo)
        elif cab.codificacao == PCodificacao.PLAIN:
            _ler_plain(dados, inicio_valores, len(dados), meta.tipo, presentes, vals)
        else:
            raise Error(
                "parquet: codificacao "
                + PCodificacao.nome(cab.codificacao)
                + " ainda nao suportada (ha suporte a PLAIN, dicionario e delta)"
            )

        if todos:
            for i in range(n):
                _emitir(acc, tipo_tucano, True, vals, i, escala)
        else:
            var proximo = 0
            for i in range(n):
                var presente = niveis[i] == def_max
                _emitir(acc, tipo_tucano, presente, vals, proximo, escala)
                if presente:
                    proximo += 1
        lidas += n
        pos = corpo + cab.tamanho_comprimido

    if lidas < linhas_do_grupo:
        raise Error(
            "parquet: coluna '" + meta.caminho + "' entregou " + String(lidas)
            + " de " + String(linhas_do_grupo) + " linhas do row group"
        )


def _montar_coluna(
    nome: String, tipo_tucano: Int, var acc: _Acumulador, var dic: DicionarioBytes,
    usou_dicionario: Bool,
) raises -> Coluna:
    if usou_dicionario:
        return Coluna.de_dicionario(
            nome, dic.para_store(), acc.tomar_codigos(), acc.tomar_ausentes()
        )
    if tipo_tucano == DType.LOGICO:
        return Coluna.de_logicos(nome, acc.logicos^, acc.ausentes^)
    if tipo_tucano == DType.TEXTO:
        return Coluna.de_textos(nome, acc.textos^, acc.ausentes^)
    if tipo_tucano == DType.REAL:
        return Coluna.de_reais(nome, acc.tomar_reais(), acc.tomar_ausentes())
    if tipo_tucano == DType.DATA:
        return Coluna.de_datas(nome, acc.tomar_inteiros(), acc.tomar_ausentes())
    if tipo_tucano == DType.DATAHORA:
        return Coluna.de_datahoras(nome, acc.tomar_inteiros(), acc.tomar_ausentes())
    return Coluna.de_inteiros(nome, acc.tomar_inteiros(), acc.tomar_ausentes())


def esquema_parquet(caminho: String) raises -> Schema:
    """Esquema do arquivo, lido so do rodape — sem tocar nos dados."""
    var m = metadados_parquet(caminho)
    var campos = List[Campo]()
    for i in range(m.num_colunas()):
        var e = m.coluna_do_esquema(i)
        campos.append(Campo(e.nome, DType(_tipo_tucano(e))))
    return Schema(campos^)


def _decodificar_coluna(
    caminho: String, c: Int, filtro: Expr
) raises -> Coluna:
    """Decodifica **uma** coluna do arquivo, do zero ao `Coluna` pronto.

    Abre o proprio descritor e le o proprio rodape em vez de receber os
    metadados de fora. Custa ~130 us, contra dezenas de milissegundos de
    decodificacao — e em troca a funcao nao compartilha nada com ninguem, o que
    e o que permite chama-la de dentro de uma thread sem um unico mutex.
    """
    var leitor = LeitorArquivo(caminho)
    var m = _metadados_do_leitor(leitor, caminho)
    var grupos = _grupos_a_ler(m, filtro)
    var esperado = 0
    for g in grupos:
        esperado += m.grupos[g].num_linhas

    var e = m.coluna_do_esquema(c)
    var tipo_tucano = _tipo_tucano(e)
    var escala = 0
    if e.convertido == PConvertido.TIMESTAMP_MILLIS:
        escala = 1
    elif e.convertido == PConvertido.TIMESTAMP_NANOS:
        escala = -1
    var def_max = m.nivel_definicao_max(c)

    var acc = _Acumulador()
    acc.reservar(esperado, tipo_tucano)
    var dic = DicionarioBytes()
    var usou = False
    for g in grupos:
        ref grupo = m.grupos[g]
        if c >= len(grupo.colunas):
            leitor.fechar()
            raise Error("parquet: row group com menos colunas que o esquema")
        ref cm = grupo.colunas[c]
        var base = cm.inicio()
        var bytes = leitor.ler(base, cm.tamanho_comprimido)
        var local = _deslocar(cm, base)
        _ler_pedaco_coluna(
            bytes, local, def_max, tipo_tucano, escala, grupo.num_linhas,
            acc, dic, usou,
        )
    leitor.fechar()
    if acc.linhas() != esperado:
        raise Error(
            "parquet: coluna '" + e.nome + "' com " + String(acc.linhas())
            + " linhas, arquivo declara " + String(esperado)
            + " apos poda de row group"
        )
    return _montar_coluna(e.nome, tipo_tucano, acc^, dic^, usou)


struct _TarefaColuna(Movable):
    """Uma coluna para decodificar, e o lugar onde a resposta volta.

    `saida` e uma lista de zero ou um elemento porque `Coluna` nao tem valor
    vazio que signifique "ainda nao": lista de um diz "pronta" sem inventar uma
    coluna de mentira. `erro` guarda o que a thread nao pode lancar.

    Nenhum campo aponta para fora: a tarefa e dona de tudo que usa, e e por isso
    que ela roda em thread sem um unico mutex.
    """

    var caminho: String
    var indice: Int
    var filtro: Expr
    var saida: List[Coluna]
    var erro: String

    def __init__(out self, caminho: String, indice: Int, filtro: Expr):
        self.caminho = caminho
        self.indice = indice
        self.filtro = filtro.copy()
        self.saida = List[Coluna]()
        self.erro = ""


def _trabalhador_coluna(
    p: UnsafePointer[_TarefaColuna, origin=AnyOrigin[mut=True]]
) -> Int:
    """Rotina de entrada da thread. Nao propaga excecao: guarda e volta.

    A origin fica fixada em `AnyOrigin[mut=True]` porque solta (`_`) tornaria a
    funcao parametrica, e funcao parametrica nao tem endereco para dar ao
    `pthread_create`.
    """
    try:
        _executar_tarefa(p[])
    except e:
        p[].erro = String(e)
    return 0


def _executar_tarefa(mut tarefa: _TarefaColuna) raises:
    """O trabalho de uma tarefa, identico dentro e fora de thread.

    Estar num so lugar e o que impede o caminho sequencial de divergir do
    paralelo — que foi exatamente o erro cometido ao separa-los.
    """
    tarefa.saida.append(
        _decodificar_coluna(tarefa.caminho, tarefa.indice, tarefa.filtro)
    )


def ler_parquet_lote(
    caminho: String,
    colunas: List[String] = List[String](),
    filtro: Expr = Expr(),
) raises -> List[Coluna]:
    """Le um arquivo Parquet para um lote de colunas.

    `colunas` faz **column pruning**, e a poda vale para o disco tambem: so as
    faixas de bytes das colunas pedidas sao lidas. Carregar o arquivo inteiro
    para depois decodificar parte dele desperdicava a maior parcela do tempo —
    ler 244 MiB custa 180 ms; ler as faixas de duas colunas de cinco custa 30.

    `filtro` e predicate pushdown: row group cujo min/max nao pode satisfazer
    um `coluna op literal` (e AND/OR disso) nao sai do disco. Sem estatistica,
    o grupo e lido. O operador de filtro no plano continua rodando — pular
    grupo e so I/O, nao substitui a selecao.

    **Uma coluna por thread**, e nada mais fino que isso. Colunas nao dependem
    umas das outras: cada uma le a sua faixa de bytes com `pread`, que nao usa o
    cursor do arquivo, e escreve no seu proprio destino. Nao ha mutex no caminho
    quente porque nao ha estado compartilhado — a decisao de projeto que torna
    isso verdade e cada tarefa reler o rodape em vez de dividir os metadados.

    Dividir a coluna em faixas de row group existiu do M20 ao M25 e **saiu**:
    depois que as codificacoes encolheram o arquivo, juntar as faixas passou a
    custar mais que a divisao economizava. Ver M26.

    Devolve lote, nao `Tabela`: assim o leitor pode ser chamado de dentro do
    `coletar()`, depois que o otimizador ja decidiu quais colunas o plano usa.
    """
    var leitor = LeitorArquivo(caminho)
    var m = _metadados_do_leitor(leitor, caminho)
    var querer = indices_das_colunas(m, colunas)
    leitor.fechar()
    if len(querer) == 0:
        raise Error("parquet: nenhuma coluna selecionada")

    var grupos = _grupos_a_ler(m, filtro)
    var linhas = 0
    for g in grupos:
        linhas += m.grupos[g].num_linhas

    var tarefas = List[_TarefaColuna]()
    for c in querer:
        tarefas.append(_TarefaColuna(caminho, c, filtro))

    var n = len(tarefas)
    var usar_thread = n > 1 and linhas >= LINHAS_MINIMAS_POR_TAREFA
    var tids = List[Int]()
    tids.resize(n, 0)
    var criadas = 0
    if usar_thread:
        for i in range(n):
            var rc = external_call["pthread_create", Int32](
                tids.unsafe_ptr().unsafe_offset(i), Int(0),
                _trabalhador_coluna, tarefas.unsafe_ptr().unsafe_offset(i),
            )
            if rc != 0:
                break
            criadas += 1

    for i in range(criadas):
        _ = external_call["pthread_join", Int32](tids[i], Int(0))

    # o que nao coube em thread sai aqui, pela mesma funcao que a thread
    # teria chamado
    for i in range(criadas, n):
        _executar_tarefa(tarefas[i])

    var saida = List[Coluna]()
    for i in range(n):
        if tarefas[i].erro != "":
            raise Error(tarefas[i].erro)
        if len(tarefas[i].saida) != 1:
            raise Error(
                "parquet: a coluna '"
                + m.coluna_do_esquema(tarefas[i].indice).nome
                + "' nao voltou da decodificacao"
            )
        saida.append(tarefas[i].saida.pop())
    return saida^


def _ler_faixa(
    bytes: List[UInt8],
    m: MetadadosParquet,
    querer: List[Int],
    grupo_ini: Int,
    grupo_fim: Int,
) raises -> List[Coluna]:
    """Le uma faixa de row groups. Base tanto da leitura inteira quanto do fluxo."""
    var esperado = 0
    for g in range(grupo_ini, grupo_fim):
        esperado += m.grupos[g].num_linhas

    var saida = List[Coluna]()
    for c in querer:
        var e = m.coluna_do_esquema(c)
        var tipo_tucano = _tipo_tucano(e)
        var escala = 0
        if e.convertido == PConvertido.TIMESTAMP_MILLIS:
            escala = 1
        elif e.convertido == PConvertido.TIMESTAMP_NANOS:
            escala = -1
        var def_max = m.nivel_definicao_max(c)
        var acc = _Acumulador()
        acc.reservar(esperado, tipo_tucano)
        var dic = DicionarioBytes()
        var usou = False
        for g in range(grupo_ini, grupo_fim):
            ref grupo = m.grupos[g]
            if c >= len(grupo.colunas):
                raise Error("parquet: row group com menos colunas que o esquema")
            _ler_pedaco_coluna(
                bytes, grupo.colunas[c], def_max, tipo_tucano, escala,
                grupo.num_linhas, acc, dic, usou,
            )
        if acc.linhas() != esperado:
            raise Error(
                "parquet: coluna '" + e.nome + "' com " + String(acc.linhas())
                + " linhas, esperado " + String(esperado)
            )
        saida.append(_montar_coluna(e.nome, tipo_tucano, acc^, dic^, usou))
    return saida^


def indices_das_colunas(
    m: MetadadosParquet, colunas: List[String]
) raises -> List[Int]:
    """Nomes -> posicoes no esquema. Lista vazia significa todas."""
    var querer = List[Int]()
    if len(colunas) == 0:
        for i in range(m.num_colunas()):
            querer.append(i)
        return querer^
    for nome in colunas:
        var achou = -1
        for i in range(m.num_colunas()):
            if m.coluna_do_esquema(i).nome == nome:
                achou = i
                break
        if achou < 0:
            var disponiveis = List[String]()
            for i in range(m.num_colunas()):
                disponiveis.append(m.coluna_do_esquema(i).nome)
            raise erro_coluna(nome, disponiveis)
        querer.append(achou)
    return querer^


def ler_parquet_grupo(
    bytes: List[UInt8],
    m: MetadadosParquet,
    querer: List[Int],
    grupo: Int,
) raises -> List[Coluna]:
    """Le um unico row group — a unidade natural de fatia do formato."""
    return _ler_faixa(bytes, m, querer, grupo, grupo + 1)


# ------------------------------------------------------------------ escrita

from .thrift import EscritorThrift
from .codecs import codificar_rle, codificar_rle_i32, real64_para_bits


def _tipo_parquet(codigo: Int) raises -> Int:
    if codigo == DType.LOGICO:
        return PTipo.BOOLEAN
    if codigo == DType.TEXTO:
        return PTipo.BYTE_ARRAY
    if codigo == DType.REAL:
        return PTipo.DOUBLE
    if codigo == DType.DATA:
        return PTipo.INT32
    return PTipo.INT64


def _convertido_parquet(codigo: Int) -> Int:
    if codigo == DType.TEXTO:
        return PConvertido.UTF8
    if codigo == DType.DATA:
        return PConvertido.DATE
    if codigo == DType.DATAHORA:
        return PConvertido.TIMESTAMP_MICROS
    return PConvertido.NENHUM


def _por_le(mut out: List[UInt8], valor: Int, n_bytes: Int):
    for i in range(n_bytes):
        out.append(UInt8((valor >> (8 * i)) & 0xFF))


def _valores_plain(col: Coluna) raises -> List[UInt8]:
    """PLAIN dos valores PRESENTES — ausentes nao ocupam espaco no Parquet."""
    var out = List[UInt8]()
    var n = col.tamanho()

    if col.tipo == DType.LOGICO:
        var bit = 0
        var atual = 0
        for i in range(n):
            if col.eh_ausente(i):
                continue
            if Int(col.logics[i]) != 0:
                atual |= 1 << bit
            bit += 1
            if bit == 8:
                out.append(UInt8(atual))
                atual = 0
                bit = 0
        if bit > 0:
            out.append(UInt8(atual))
        return out^

    if col.tipo == DType.TEXTO:
        for i in range(n):
            if col.eh_ausente(i):
                continue
            var b = col.texto_bruto(i).as_bytes()
            _por_le(out, len(b), 4)
            for x in b:
                out.append(x)
        return out^

    if col.tipo == DType.REAL:
        for i in range(n):
            if col.eh_ausente(i):
                continue
            _por_le(out, real64_para_bits(col.reals[i]), 8)
        return out^

    if col.tipo == DType.DATA:
        for i in range(n):
            if col.eh_ausente(i):
                continue
            _por_le(out, Int(col.ints[i]), 4)
        return out^

    for i in range(n):
        if col.eh_ausente(i):
            continue
        _por_le(out, Int(col.ints[i]), 8)
    return out^


def _fatiar(col: Coluna, ini: Int, fim: Int) raises -> Coluna:
    """Recorta um trecho **contiguo** da coluna.

    A primeira versao montava uma lista de indices e chamava `coletar_linhas`,
    que e um gather — o caminho de quando as linhas vem espalhadas, como depois
    de ordenar. Para uma faixa contigua sao dois memcpy.
    """
    var n = fim - ini
    if n < 0:
        n = 0
    var aus = List[Bool](capacity=n)
    for i in range(ini, fim):
        aus.append(col.eh_ausente(i))

    if col.tipo == DType.TEXTO:
        if col.eh_dicionarizada():
            var cods = List[Int32](capacity=n)
            cods.resize(unsafe_uninit_length=n)
            if n > 0:
                _ = external_call["memcpy", Int](
                    cods.unsafe_ptr().unsafe_bitcast[UInt8](),
                    col.codigos.unsafe_ptr().unsafe_offset(ini).unsafe_bitcast[UInt8](),
                    n * 4,
                )
            return Coluna.de_dicionario(col.nome, col.textos.copy(), cods^, aus^)
        var vals = List[String](capacity=n)
        for i in range(ini, fim):
            if col.eh_ausente(i):
                vals.append("")
            else:
                vals.append(col.texto_bruto(i))
        return Coluna.de_textos(col.nome, vals^, aus^)

    if col.tipo == DType.LOGICO:
        var vals = List[Bool](capacity=n)
        for i in range(ini, fim):
            vals.append(Int(col.logics[i]) != 0)
        return Coluna.de_logicos(col.nome, vals^, aus^)

    if col.tipo == DType.REAL:
        var vals = List[Float64](capacity=n)
        vals.resize(unsafe_uninit_length=n)
        if n > 0:
            _ = external_call["memcpy", Int](
                vals.unsafe_ptr().unsafe_bitcast[UInt8](),
                col.reals.unsafe_ptr().unsafe_offset(ini).unsafe_bitcast[UInt8](),
                n * 8,
            )
        return Coluna.de_reais(col.nome, vals^, aus^)

    var vals = List[Int64](capacity=n)
    vals.resize(unsafe_uninit_length=n)
    if n > 0:
        _ = external_call["memcpy", Int](
            vals.unsafe_ptr().unsafe_bitcast[UInt8](),
            col.ints.unsafe_ptr().unsafe_offset(ini).unsafe_bitcast[UInt8](),
            n * 8,
        )
    if col.tipo == DType.DATA:
        return Coluna.de_datas(col.nome, vals^, aus^)
    if col.tipo == DType.DATAHORA:
        return Coluna.de_datahoras(col.nome, vals^, aus^)
    return Coluna.de_inteiros(col.nome, vals^, aus^)


def _acrescentar(mut dest: List[UInt8], src: List[UInt8]):
    """Copia `src` no fim de `dest` em bloco, sem zerar nem `append` por byte."""
    var n = len(src)
    if n <= 0:
        return
    var antes = len(dest)
    dest.resize(unsafe_uninit_length=antes + n)
    _ = external_call["memcpy", Int](
        dest.unsafe_ptr().unsafe_offset(antes), src.unsafe_ptr(), n
    )


struct _DicNumerico(Movable):
    """Uma coluna numerica reduzida a valores distintos + um codigo por linha."""

    var distintos: List[Int64]
    """Os bits dos valores distintos, na ordem de aparicao. Real vai como bits:
    a pagina de dicionario e PLAIN dos oito bytes, e o padrao de bits E o valor."""

    var codigos: List[Int32]
    var vale: Bool

    def __init__(out self, var distintos: List[Int64], var codigos: List[Int32], vale: Bool):
        self.distintos = distintos^
        self.codigos = codigos^
        self.vale = vale


def _dicionario_numerico(col: Coluna) raises -> _DicNumerico:
    """Dicionariza uma coluna numerica, se isso encolher a pagina.

    O escritor ja fazia isso com texto desde o M10.6, e o leitor sempre soube
    ler dicionario de qualquer tipo — faltava o escritor emitir. Uma coluna de
    cinco milhoes de linhas com dez mil valores distintos ocupa 40 MiB em PLAIN
    e menos de 9 em codigos, e cada codigo cabe em quatorze bits.

    O criterio e o tamanho, calculado nos dois formatos. Coluna toda distinta —
    uma chave, um carimbo de tempo — nao dicionariza: o dicionario seria a
    coluna inteira mais os codigos.
    """
    var vazio_i = List[Int64]()
    var vazio_c = List[Int32]()
    if col.tipo == DType.TEXTO or col.tipo == DType.LOGICO:
        return _DicNumerico(vazio_i^, vazio_c^, False)

    var n = col.tamanho()
    var mapa = Dict[Int, Int]()
    var distintos = List[Int64]()
    var codigos = List[Int32]()
    var presentes = 0
    for i in range(n):
        if col.eh_ausente(i):
            continue
        presentes += 1
        var bruto: Int
        if col.tipo == DType.REAL:
            bruto = real64_para_bits(col.reals[i])
        else:
            bruto = Int(col.ints[i])
        if bruto in mapa:
            codigos.append(Int32(mapa[bruto]))
        else:
            var novo = len(distintos)
            mapa[bruto] = novo
            distintos.append(Int64(bruto))
            codigos.append(Int32(novo))

    if presentes == 0 or len(distintos) == 0:
        return _DicNumerico(vazio_i^, vazio_c^, False)

    var largura = 0
    if len(distintos) > 1:
        largura = largura_de_bits(len(distintos) - 1)
    var com_dicionario = len(distintos) * 8 + (presentes * largura + 7) // 8
    var em_plain = presentes * 8
    if com_dicionario >= em_plain:
        return _DicNumerico(vazio_i^, vazio_c^, False)
    return _DicNumerico(distintos^, codigos^, True)


def _valores_plain_dicionario_numerico(dic: _DicNumerico) -> List[UInt8]:
    """PLAIN dos valores distintos: oito bytes little-endian cada."""
    var out = List[UInt8](capacity=len(dic.distintos) * 8)
    for v in dic.distintos:
        var x = Int(v)
        for k in range(8):
            out.append(UInt8((x >> (8 * k)) & 0xFF))
    return out^


def _valores_plain_dicionario(col: Coluna) raises -> List[UInt8]:
    """PLAIN dos valores distintos — o corpo da pagina de dicionario."""
    var out = List[UInt8]()
    var n = col.textos.tamanho()
    for i in range(n):
        var b = col.textos.get(i).as_bytes()
        _por_le(out, len(b), 4)
        for x in b:
            out.append(x)
    return out^


def _indices_presentes(col: Coluna) raises -> List[Int32]:
    var n = col.tamanho()
    var out = List[Int32](capacity=n)
    for i in range(n):
        if not col.eh_ausente(i):
            out.append(col.codigos[i])
    return out^


def _delta_se_valer(col: Coluna) raises -> List[UInt8]:
    """Decide entre DELTA_BINARY_PACKED e PLAIN medindo os dois.

    Nao ha heuristica melhor que codificar e comparar: o delta ganha muito em
    coluna que cresce, empata em ruido e perde em coluna aleatoria de 64 bits.

    Devolve os **bytes**, nao um sim ou nao: a primeira versao respondia `Bool` e
    o chamador codificava de novo para escrever, o que dobrava o trabalho da
    coluna inteira.
    """
    var vazio = List[UInt8]()
    if col.tipo == DType.REAL or col.tipo == DType.TEXTO:
        return vazio^
    if col.tipo == DType.LOGICO:
        return vazio^
    var presentes = _inteiros_presentes(col)
    if len(presentes) < 8:
        return vazio^
    # o codec recusa faixas que nao cabem; recusa dele e resposta aqui
    try:
        var bytes = codificar_delta_i64(presentes)
        if len(bytes) < len(presentes) * 8:
            return bytes^
        return vazio^
    except:
        return vazio^


def _inteiros_presentes(col: Coluna) raises -> List[Int64]:
    var out = List[Int64](capacity=col.tamanho())
    for i in range(col.tamanho()):
        if not col.eh_ausente(i):
            out.append(col.ints[i])
    return out^


def _pagina_de_dados(
    col: Coluna, dicionarizada: Bool, var delta: List[UInt8] = List[UInt8](),
    codigos_de_fora: List[Int32] = List[Int32](), cardinalidade_de_fora: Int = 0,
) raises -> List[UInt8]:
    """Pagina de dados V1: [tamanho dos niveis][niveis RLE][valores]."""
    var n = col.tamanho()
    var niveis = List[UInt8](capacity=n)
    for i in range(n):
        if col.eh_ausente(i):
            niveis.append(UInt8(0))
        else:
            niveis.append(UInt8(1))
    var niveis_rle = codificar_rle(niveis, 1)

    var pagina = List[UInt8]()
    _por_le(pagina, len(niveis_rle), 4)
    _acrescentar(pagina, niveis_rle)
    if dicionarizada:
        var idxs: List[Int32]
        var card: Int
        if cardinalidade_de_fora > 0:
            # coluna numerica: o dicionario foi montado na hora de escrever, e
            # nao vive dentro da `Coluna` como no texto — `col.codigos` esta
            # vazio, e le-lo estouraria o limite
            idxs = codigos_de_fora.copy()
            card = cardinalidade_de_fora
        else:
            idxs = _indices_presentes(col)
            card = col.cardinalidade()
        var largura = 0
        if card > 1:
            largura = largura_de_bits(card - 1)
        pagina.append(UInt8(largura))
        _acrescentar(pagina, codificar_rle_i32(idxs, largura))
    elif len(delta) > 0:
        # ja codificado por quem decidiu usar delta
        _acrescentar(pagina, delta^)
    else:
        _acrescentar(pagina, _valores_plain(col))
    return pagina^


def _codec_de_nome(nome: String) raises -> Int:
    var v = String(nome.lower())
    if v == "" or v == "nenhuma" or v == "none" or v == "uncompressed":
        return PCompressao.NENHUMA
    if v == "snappy":
        return PCompressao.SNAPPY
    raise Error(
        "parquet: compressao '" + nome + "' desconhecida (use 'snappy' ou 'nenhuma')"
    )


def _aplicar_codec(var corpo: List[UInt8], codec: Int) raises -> List[UInt8]:
    if codec == PCompressao.SNAPPY:
        return comprimir_snappy(corpo)
    return corpo^


def _cabecalho_de_dados(
    num_valores: Int, descomprimido: Int, comprimido: Int, encoding: Int
) raises -> List[UInt8]:
    var w = EscritorThrift()
    w.entrar()
    w.campo_i32(1, PTipoPagina.DADOS)
    w.campo_i32(2, descomprimido)
    w.campo_i32(3, comprimido)
    w.campo_struct(5)
    w.campo_i32(1, num_valores)
    w.campo_i32(2, encoding)
    w.campo_i32(3, PCodificacao.RLE)
    w.campo_i32(4, PCodificacao.RLE)
    w.sair()
    w.sair()
    return w.finalizar()


def _cabecalho_de_dicionario(
    num_valores: Int, descomprimido: Int, comprimido: Int
) raises -> List[UInt8]:
    var w = EscritorThrift()
    w.entrar()
    w.campo_i32(1, PTipoPagina.DICIONARIO)
    w.campo_i32(2, descomprimido)
    w.campo_i32(3, comprimido)
    w.campo_struct(7)
    w.campo_i32(1, num_valores)
    w.campo_i32(2, PCodificacao.PLAIN)
    w.sair()
    w.sair()
    return w.finalizar()


def _n_distintos_de(col: Coluna) raises -> Int:
    """NDV do pedaco. `-1` se a coluna nao e dicionarizada."""
    if not col.eh_dicionarizada():
        return -1
    var card = col.cardinalidade()
    if card <= 0:
        return 0
    var visto = List[Bool](capacity=card)
    visto.resize(card, False)
    var nd = 0
    var n = col.tamanho()
    for i in range(n):
        if col.eh_ausente(i):
            continue
        var c = Int(col.codigos[i])
        if c < 0 or c >= card:
            continue
        if not visto[c]:
            visto[c] = True
            nd += 1
    return nd


def _stats_de_coluna(col: Coluna) raises -> StatsFaixa:
    """min/max dos valores presentes. Texto e logico nao entram: sem PLAIN util."""
    var nd = _n_distintos_de(col)
    var n = col.tamanho()
    if col.tipo == DType.REAL:
        var tem = False
        var mn = 0.0
        var mx = 0.0
        for i in range(n):
            if col.eh_ausente(i):
                continue
            var v = col.reals[i]
            if not tem:
                mn = v
                mx = v
                tem = True
            else:
                if v < mn:
                    mn = v
                if v > mx:
                    mx = v
        if not tem:
            return StatsFaixa(False, 0, 0, nd)
        return StatsFaixa(True, real64_para_bits(mn), real64_para_bits(mx), nd)
    if (
        col.tipo == DType.INTEIRO
        or col.tipo == DType.DATA
        or col.tipo == DType.DATAHORA
    ):
        var tem = False
        var mn = Int64(0)
        var mx = Int64(0)
        for i in range(n):
            if col.eh_ausente(i):
                continue
            var v = col.ints[i]
            if not tem:
                mn = v
                mx = v
                tem = True
            else:
                if v < mn:
                    mn = v
                if v > mx:
                    mx = v
        if not tem:
            return StatsFaixa(False, 0, 0, nd)
        return StatsFaixa(True, Int(mn), Int(mx), nd)
    return StatsFaixa(False, 0, 0, nd)


def _bytes_stats(tipo: Int, bits: Int) -> List[UInt8]:
    var n = 8
    if tipo == PTipo.INT32 or tipo == PTipo.FLOAT:
        n = 4
    var out = List[UInt8]()
    _por_le(out, bits, n)
    return out^


def para_parquet_lote(
    colunas: List[Coluna],
    nomes: List[String],
    caminho: String,
    linhas_por_grupo: Int = 0,
    compressao: String = "snappy",
) raises:
    """Grava um lote de colunas em Parquet.

    Texto ja dicionarizado sai em `RLE_DICTIONARY`. Paginas em Snappy por
    padrao (`compressao="nenhuma"` desliga). Qualquer leitor de Parquet aceita
    os dois; a verificacao e ler o arquivo de volta com outra implementacao.
    """
    var codec = _codec_de_nome(compressao)
    var n_linhas = 0
    if len(colunas) > 0:
        n_linhas = colunas[0].tamanho()

    var arquivo = List[UInt8]()
    for b in String("PAR1").as_bytes():
        arquivo.append(b)

    # fronteiras dos row groups
    var passo = linhas_por_grupo
    if passo <= 0 or passo > n_linhas:
        passo = n_linhas
    if passo <= 0:
        passo = 1
    var inicios = List[Int]()
    var fins = List[Int]()
    var p = 0
    while p < n_linhas:
        var f = p + passo
        if f > n_linhas:
            f = n_linhas
        inicios.append(p)
        fins.append(f)
        p = f
    if len(inicios) == 0:
        inicios.append(0)
        fins.append(0)

    # offsets[g * n_col + c]
    var offsets = List[Int]()
    var tamanhos = List[Int]()
    var tamanhos_uncomp = List[Int]()
    var offset_dados = List[Int]()
    var offset_dic = List[Int]()
    var deltas_usados = List[Bool]()
    var stats = List[StatsFaixa]()
    for g in range(len(inicios)):
        for c in range(len(colunas)):
            var fatia = _fatiar(colunas[c], inicios[g], fins[g])
            stats.append(_stats_de_coluna(fatia))
            var usa_dic = fatia.tipo == DType.TEXTO and fatia.eh_dicionarizada()
            var dic_num = _DicNumerico(List[Int64](), List[Int32](), False)
            if not usa_dic:
                dic_num = _dicionario_numerico(fatia)
            var usa_dic_num = dic_num.vale
            var inicio_chunk = len(arquivo)
            var uncomp = 0
            var dic_off = -1
            if usa_dic or usa_dic_num:
                var corpo_dic: List[UInt8]
                var card_dic: Int
                if usa_dic:
                    corpo_dic = _valores_plain_dicionario(fatia)
                    card_dic = fatia.cardinalidade()
                else:
                    corpo_dic = _valores_plain_dicionario_numerico(dic_num)
                    card_dic = len(dic_num.distintos)
                var n_dic = len(corpo_dic)
                var corpo_dic_c = _aplicar_codec(corpo_dic^, codec)
                var cab_dic = _cabecalho_de_dicionario(
                    card_dic, n_dic, len(corpo_dic_c)
                )
                dic_off = len(arquivo)
                _acrescentar(arquivo, cab_dic)
                _acrescentar(arquivo, corpo_dic_c)
                uncomp += len(cab_dic) + n_dic
            var delta_bytes = List[UInt8]()
            if not usa_dic and not usa_dic_num:
                delta_bytes = _delta_se_valer(fatia)
            var usa_delta = len(delta_bytes) > 0
            var encoding = PCodificacao.PLAIN
            if usa_dic or usa_dic_num:
                encoding = PCodificacao.RLE_DICTIONARY
            elif usa_delta:
                encoding = PCodificacao.DELTA_BINARY_PACKED
            var pagina = _pagina_de_dados(
                fatia, usa_dic or usa_dic_num, delta_bytes^,
                dic_num.codigos, len(dic_num.distintos),
            )
            var n_pag = len(pagina)
            var pagina_c = _aplicar_codec(pagina^, codec)
            var cabecalho = _cabecalho_de_dados(
                fins[g] - inicios[g], n_pag, len(pagina_c), encoding
            )
            var dados_off = len(arquivo)
            _acrescentar(arquivo, cabecalho)
            _acrescentar(arquivo, pagina_c)
            uncomp += len(cabecalho) + n_pag
            deltas_usados.append(usa_delta)
            offsets.append(inicio_chunk)
            tamanhos.append(len(arquivo) - inicio_chunk)
            tamanhos_uncomp.append(uncomp)
            offset_dados.append(dados_off)
            offset_dic.append(dic_off)

    # ---- FileMetaData
    var w = EscritorThrift()
    w.entrar()
    w.campo_i32(1, 1)  # versao do formato

    # esquema: raiz + uma entrada por coluna, em ordem de profundidade
    w.campo_lista(2, TTipo.STRUCT, len(colunas) + 1)
    w.entrar()
    w.campo_texto(4, "tucano")
    w.campo_i32(5, len(colunas))
    w.sair()
    for c in range(len(colunas)):
        var codigo = colunas[c].tipo
        w.entrar()
        w.campo_i32(1, _tipo_parquet(codigo))
        w.campo_i32(3, PRepeticao.OPCIONAL)
        w.campo_texto(4, nomes[c])
        var conv = _convertido_parquet(codigo)
        if conv != PConvertido.NENHUM:
            w.campo_i32(6, conv)
        if codigo == DType.DATAHORA:
            # sem LogicalType, o legado TIMESTAMP_MICROS e lido como UTC e o
            # carimbo volta com fuso que nunca teve
            w.campo_struct(10)  # LogicalType
            w.campo_struct(8)  # TIMESTAMP
            w.campo_bool(1, False)  # isAdjustedToUTC
            w.campo_struct(2)  # TimeUnit
            w.campo_struct(2)  # MICROS
            w.sair()
            w.sair()
            w.sair()
            w.sair()
        w.sair()

    w.campo_i64(3, n_linhas)

    w.campo_lista(4, TTipo.STRUCT, len(inicios))
    for g in range(len(inicios)):
        var linhas_g = fins[g] - inicios[g]
        w.entrar()  # RowGroup
        w.campo_lista(1, TTipo.STRUCT, len(colunas))
        var total = 0
        for c in range(len(colunas)):
            var k = g * len(colunas) + c
            total += tamanhos[k]
            w.entrar()  # ColumnChunk
            w.campo_i64(2, offsets[k])
            w.campo_struct(3)  # ColumnMetaData
            w.campo_i32(1, _tipo_parquet(colunas[c].tipo))
            # o rodape declara o que a coluna usou: quem le por aqui decide se
            # sabe abrir o arquivo antes de tocar nos dados
            if offset_dic[k] >= 0:
                w.campo_lista(2, TTipo.I32, 3)
                w.zigzag(PCodificacao.PLAIN)
                w.zigzag(PCodificacao.RLE)
                w.zigzag(PCodificacao.RLE_DICTIONARY)
            elif deltas_usados[k]:
                w.campo_lista(2, TTipo.I32, 2)
                w.zigzag(PCodificacao.RLE)
                w.zigzag(PCodificacao.DELTA_BINARY_PACKED)
            else:
                w.campo_lista(2, TTipo.I32, 2)
                w.zigzag(PCodificacao.PLAIN)
                w.zigzag(PCodificacao.RLE)
            w.campo_lista(3, TTipo.BINARIO, 1)
            w.binario(nomes[c])
            w.campo_i32(4, codec)
            w.campo_i64(5, linhas_g)
            w.campo_i64(6, tamanhos_uncomp[k])
            w.campo_i64(7, tamanhos[k])
            w.campo_i64(9, offset_dados[k])
            if offset_dic[k] >= 0:
                w.campo_i64(11, offset_dic[k])
            if stats[k].tem or stats[k].n_distintos >= 0:
                w.campo_struct(12)
                if stats[k].n_distintos >= 0:
                    w.campo_i64(4, stats[k].n_distintos)
                if stats[k].tem:
                    var tipo_p = _tipo_parquet(colunas[c].tipo)
                    w.campo_bytes(5, _bytes_stats(tipo_p, stats[k].max_bits))
                    w.campo_bytes(6, _bytes_stats(tipo_p, stats[k].min_bits))
                w.sair()
            w.sair()  # ColumnMetaData
            w.sair()  # ColumnChunk
        w.campo_i64(2, total)
        w.campo_i64(3, linhas_g)
        w.sair()  # RowGroup

    w.campo_texto(6, "tucano")
    w.sair()

    var meta = w.finalizar()
    for b in meta:
        arquivo.append(b)
    _por_le(arquivo, len(meta), 4)
    for b in String("PAR1").as_bytes():
        arquivo.append(b)

    Path(caminho).write_bytes(arquivo)
