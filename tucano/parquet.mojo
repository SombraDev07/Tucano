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
from .thrift import LeitorThrift, TTipo, CampoThrift, ListaThrift
from .arquivo import LeitorArquivo


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

    def tem_dicionario(self) -> Bool:
        return self.offset_dicionario > 0

    def inicio(self) -> Int:
        """Primeiro byte da coluna: a pagina de dicionario vem antes dos dados."""
        if self.tem_dicionario() and self.offset_dicionario < self.offset_dados:
            return self.offset_dicionario
        return self.offset_dados


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
    var offset_dic = 0
    var comprimido = 0
    var caminho = String("")
    var codificacoes = List[Int]()

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
    )


def _ler_pedaco(mut l: LeitorThrift, bytes: List[UInt8]) raises -> ColunaMeta:
    var meta = ColunaMeta(
        -1, 0, 0, 0, 0, 0, "", List[Int]()
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
    if dic > 0:
        dic -= base
    return ColunaMeta(
        meta.tipo, meta.codec, meta.num_valores, meta.offset_dados - base, dic,
        meta.tamanho_comprimido, meta.caminho, meta.codificacoes.copy(),
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
            _ler_pedaco_coluna(
                bytes, local, def_max, tipo_tucano, escala, grupo.num_linhas, acc
            )
            saida.append(_montar_coluna(e.nome, tipo_tucano, acc^))
        return saida^

    def fechar(self):
        self.leitor.fechar()


# ------------------------------------------------------------------ paginas

from .codecs import (
    descomprimir_snappy,
    decodificar_rle,
    largura_de_bits,
    bits_para_real64,
    bits_para_real32,
)
from .coluna import Coluna
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
        var out = List[UInt8](capacity=comprimido)
        for i in range(comprimido):
            out.append(bytes[ini + i])
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
    for i in range(4):
        v |= Int(b[pos + i]) << (8 * i)
    if v >= 0x80000000:
        v -= 0x100000000
    return v


def _int64(b: List[UInt8], pos: Int) -> Int:
    var v = 0
    for i in range(8):
        v |= Int(b[pos + i]) << (8 * i)
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


struct _Acumulador(Copyable, Movable):
    """Junta os valores de uma coluna ao longo de todos os row groups."""

    var inteiros: List[Int64]
    var reais: List[Float64]
    var logicos: List[Bool]
    var textos: List[String]
    var ausentes: List[Bool]

    def __init__(out self):
        self.inteiros = List[Int64]()
        self.reais = List[Float64]()
        self.logicos = List[Bool]()
        self.textos = List[String]()
        self.ausentes = List[Bool]()

    def linhas(self) -> Int:
        return len(self.ausentes)


def _emitir(
    mut acc: _Acumulador,
    tipo_tucano: Int,
    presente: Bool,
    vals: ValoresPagina,
    idx: Int,
    escala: Int,
):
    """Acrescenta uma linha, com placeholder quando ausente."""
    acc.ausentes.append(not presente)
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


def _ler_pedaco_coluna(
    bytes: List[UInt8],
    meta: ColunaMeta,
    def_max: Int,
    tipo_tucano: Int,
    escala: Int,
    linhas_do_grupo: Int,
    mut acc: _Acumulador,
) raises:
    var pos = meta.inicio()
    var limite = pos + meta.tamanho_comprimido
    var dicionario = ValoresPagina()
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
        var dados: List[UInt8]
        var inicio_valores = 0

        if cab.tipo == PTipoPagina.DADOS_V2:
            # V2: os niveis ficam FORA da compressao, antes dos valores
            var p = corpo + cab.bytes_niveis_rep
            if def_max > 0 and cab.bytes_niveis_def > 0:
                niveis = decodificar_rle(
                    bytes, p, p + cab.bytes_niveis_def, largura_de_bits(def_max), n
                )
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
                niveis = decodificar_rle(
                    dados, p, p + tamanho, largura_de_bits(def_max), n
                )
                p += tamanho
            inicio_valores = p

        var presentes = 0
        if def_max == 0:
            presentes = n
        else:
            for d in niveis:
                if d == def_max:
                    presentes += 1

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
                + " ainda nao suportada (ha suporte a PLAIN e dicionario)"
            )

        var proximo = 0
        for i in range(n):
            var presente = def_max == 0 or niveis[i] == def_max
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
    nome: String, tipo_tucano: Int, var acc: _Acumulador
) raises -> Coluna:
    if tipo_tucano == DType.LOGICO:
        return Coluna.de_logicos(nome, acc.logicos^, acc.ausentes^)
    if tipo_tucano == DType.TEXTO:
        return Coluna.de_textos(nome, acc.textos^, acc.ausentes^)
    if tipo_tucano == DType.REAL:
        return Coluna.de_reais(nome, acc.reais^, acc.ausentes^)
    if tipo_tucano == DType.DATA:
        return Coluna.de_datas(nome, acc.inteiros^, acc.ausentes^)
    if tipo_tucano == DType.DATAHORA:
        return Coluna.de_datahoras(nome, acc.inteiros^, acc.ausentes^)
    return Coluna.de_inteiros(nome, acc.inteiros^, acc.ausentes^)


def esquema_parquet(caminho: String) raises -> Schema:
    """Esquema do arquivo, lido so do rodape — sem tocar nos dados."""
    var m = metadados_parquet(caminho)
    var campos = List[Campo]()
    for i in range(m.num_colunas()):
        var e = m.coluna_do_esquema(i)
        campos.append(Campo(e.nome, DType(_tipo_tucano(e))))
    return Schema(campos^)


def ler_parquet_lote(
    caminho: String, colunas: List[String] = List[String]()
) raises -> List[Coluna]:
    """Le um arquivo Parquet para um lote de colunas.

    `colunas` faz **column pruning**: os bytes das colunas nao pedidas nunca sao
    lidos. Os metadados ficam no rodape justamente para permitir isso — e por
    isso a poda nasce aqui, e nao como otimizacao depois.

    Devolve lote, nao `Tabela`: assim o leitor pode ser chamado de dentro do
    `coletar()`, depois que o otimizador ja decidiu quais colunas o plano usa.
    """
    var bytes = Path(caminho).read_bytes()
    var m = ler_metadados(bytes)

    var querer = List[Int]()
    if len(colunas) == 0:
        for i in range(m.num_colunas()):
            querer.append(i)
    else:
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

    if len(querer) == 0:
        raise Error("parquet: nenhuma coluna selecionada")

    return _ler_faixa(bytes, m, querer, 0, len(m.grupos))


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
        for g in range(grupo_ini, grupo_fim):
            ref grupo = m.grupos[g]
            if c >= len(grupo.colunas):
                raise Error("parquet: row group com menos colunas que o esquema")
            _ler_pedaco_coluna(
                bytes, grupo.colunas[c], def_max, tipo_tucano, escala,
                grupo.num_linhas, acc,
            )
        if acc.linhas() != esperado:
            raise Error(
                "parquet: coluna '" + e.nome + "' com " + String(acc.linhas())
                + " linhas, esperado " + String(esperado)
            )
        saida.append(_montar_coluna(e.nome, tipo_tucano, acc^))
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
from .codecs import codificar_rle, real64_para_bits


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
    var indices = List[Int](capacity=fim - ini)
    for i in range(ini, fim):
        indices.append(i)
    return coletar_linhas(col, indices)


def _pagina_de_coluna(col: Coluna) raises -> List[UInt8]:
    """Pagina de dados V1: [tamanho dos niveis][niveis RLE][valores PLAIN]."""
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
    for b in niveis_rle:
        pagina.append(b)
    for b in _valores_plain(col):
        pagina.append(b)
    return pagina^


def _cabecalho_de_dados(num_valores: Int, tamanho: Int) raises -> List[UInt8]:
    var w = EscritorThrift()
    w.entrar()
    w.campo_i32(1, PTipoPagina.DADOS)
    w.campo_i32(2, tamanho)
    w.campo_i32(3, tamanho)
    w.campo_struct(5)
    w.campo_i32(1, num_valores)
    w.campo_i32(2, PCodificacao.PLAIN)
    w.campo_i32(3, PCodificacao.RLE)
    w.campo_i32(4, PCodificacao.RLE)
    w.sair()
    w.sair()
    return w.finalizar()


def para_parquet_lote(
    colunas: List[Coluna],
    nomes: List[String],
    caminho: String,
    linhas_por_grupo: Int = 0,
) raises:
    """Grava um lote de colunas em Parquet.

    Subconjunto deliberado: PLAIN, sem compressao, um row group, todas as
    colunas opcionais. E o subconjunto que qualquer leitor de Parquet aceita —
    a verificacao e ler o arquivo de volta com outra implementacao, nao com
    esta.
    """
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
    for g in range(len(inicios)):
        for c in range(len(colunas)):
            var fatia = _fatiar(colunas[c], inicios[g], fins[g])
            var pagina = _pagina_de_coluna(fatia)
            var cabecalho = _cabecalho_de_dados(fins[g] - inicios[g], len(pagina))
            offsets.append(len(arquivo))
            tamanhos.append(len(cabecalho) + len(pagina))
            for b in cabecalho:
                arquivo.append(b)
            for b in pagina:
                arquivo.append(b)

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
            w.campo_lista(2, TTipo.I32, 2)
            w.zigzag(PCodificacao.PLAIN)
            w.zigzag(PCodificacao.RLE)
            w.campo_lista(3, TTipo.BINARIO, 1)
            w.binario(nomes[c])
            w.campo_i32(4, PCompressao.NENHUMA)
            w.campo_i64(5, linhas_g)
            w.campo_i64(6, tamanhos[k])
            w.campo_i64(7, tamanhos[k])
            w.campo_i64(9, offsets[k])
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
