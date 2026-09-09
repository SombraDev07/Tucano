"""Arrow IPC — escrita (M10).

O Parquet ja da interoperabilidade com o ecossistema, mas em disco e comprimido.
O Arrow e a forma **em memoria**: os buffers do arquivo IPC tem exatamente o
layout que outra implementacao usa em RAM, entao a leitura do outro lado e um
mapeamento, nao uma conversao.

Layout do arquivo:

    ARROW1\\0\\0
    <mensagem: Schema>
    <mensagem: RecordBatch>
    <mensagem: fim>
    <Footer>
    <tamanho do Footer: int32>
    ARROW1

Cada mensagem e `0xFFFFFFFF`, o tamanho dos metadados, o FlatBuffer, e o corpo.
O corpo comeca sempre em fronteira de 8 bytes — e por isso o FlatBuffer e
preenchido ate um multiplo de 8.

**A validade e invertida.** No Arrow, bit 1 significa *presente*; no Tucano, o
bitmap marca o *ausente*. Trocar isso e uma linha, e esquecer disso e um arquivo
em que todo valor vira nulo.
"""

from std.pathlib import Path
from .arquivo import ler_arquivo_inteiro
from .coluna import Coluna
from .dtype import DType
from .flatbuf import ConstrutorFlat
from .codecs import real64_para_bits
from .executor import op_concatenar


struct TipoArrow:
    comptime NULO = 1
    comptime INT = 2
    comptime PONTO_FLUTUANTE = 3
    comptime UTF8 = 5
    comptime BOOL = 6
    comptime DATA = 8
    comptime CARIMBO = 10


comptime _VERSAO_V5 = 4
comptime _CABECALHO_ESQUEMA = 1
comptime _CABECALHO_LOTE = 3
comptime _PRECISAO_DUPLA = 2
comptime _UNIDADE_DIA = 0
comptime _UNIDADE_MICRO = 2


def _alinhar(n: Int, a: Int) -> Int:
    var resto = n % a
    if resto == 0:
        return n
    return n + (a - resto)


def _por_le(mut out: List[UInt8], valor: Int, n: Int):
    for i in range(n):
        out.append(UInt8((valor >> (8 * i)) & 0xFF))


# ------------------------------------------------------------------ esquema


def _tipo_arrow(c: Coluna) raises -> Int:
    if c.tipo == DType.LOGICO:
        return TipoArrow.BOOL
    if c.tipo == DType.TEXTO:
        return TipoArrow.UTF8
    if c.tipo == DType.REAL:
        return TipoArrow.PONTO_FLUTUANTE
    if c.tipo == DType.DATA:
        return TipoArrow.DATA
    if c.tipo == DType.DATAHORA:
        return TipoArrow.CARIMBO
    return TipoArrow.INT


def _escrever_tipo(mut b: ConstrutorFlat, c: Coluna) raises -> Int:
    var t = _tipo_arrow(c)
    if t == TipoArrow.INT:
        b.iniciar_tabela()
        b.campo_i32(0, 64, 0)  # bitWidth
        b.campo_bool(1, True, False)  # is_signed
        return b.terminar_tabela()
    if t == TipoArrow.PONTO_FLUTUANTE:
        b.iniciar_tabela()
        b.campo_i16(0, _PRECISAO_DUPLA, 0)
        return b.terminar_tabela()
    if t == TipoArrow.DATA:
        b.iniciar_tabela()
        # DateUnit: DAY = 0, e o padrao do campo e MILLISECOND = 1
        b.campo_i16(0, _UNIDADE_DIA, 1)
        return b.terminar_tabela()
    if t == TipoArrow.CARIMBO:
        b.iniciar_tabela()
        b.campo_i16(0, _UNIDADE_MICRO, 0)
        return b.terminar_tabela()
    # Bool e Utf8 sao tabelas vazias
    b.iniciar_tabela()
    return b.terminar_tabela()


def _escrever_campo(mut b: ConstrutorFlat, c: Coluna) raises -> Int:
    var tipo_valor = _escrever_tipo(b, c)
    var nome = b.texto(c.nome)
    b.iniciar_tabela()
    b.campo_referencia(0, nome)
    b.campo_bool(1, True, False)  # nullable
    b.campo_i8(2, _tipo_arrow(c), 0)
    b.campo_referencia(3, tipo_valor)
    return b.terminar_tabela()


def _escrever_esquema(mut b: ConstrutorFlat, cols: List[Coluna]) raises -> Int:
    var campos = List[Int]()
    for c in cols:
        campos.append(_escrever_campo(b, c))
    var vetor = b.vetor_de_referencias(campos)
    b.iniciar_tabela()
    b.campo_i16(0, 0, 0)  # endianness = little
    b.campo_referencia(1, vetor)
    return b.terminar_tabela()


def _mensagem(
    mut b: ConstrutorFlat, tipo_cabecalho: Int, cabecalho: Int, tamanho_corpo: Int
) raises -> Int:
    b.iniciar_tabela()
    b.campo_i16(0, _VERSAO_V5, 0)
    b.campo_i8(1, tipo_cabecalho, 0)
    b.campo_referencia(2, cabecalho)
    b.campo_i64(3, tamanho_corpo, 0)
    return b.terminar_tabela()


# -------------------------------------------------------------------- corpo


@fieldwise_init
struct FaixaBuffer(Copyable, Movable, ImplicitlyCopyable):
    var deslocamento: Int
    var tamanho: Int


def _bitmap_de_validade(c: Coluna) raises -> List[UInt8]:
    """Bitmap do Arrow: **1 = presente**, ao contrario do bitmap do Tucano."""
    var n = c.tamanho()
    var bytes = (n + 7) // 8
    var out = List[UInt8](capacity=bytes)
    for _ in range(bytes):
        out.append(UInt8(0))
    for i in range(n):
        if not c.eh_ausente(i):
            var byte_i = i // 8
            out[byte_i] = UInt8(Int(out[byte_i]) | (1 << (i % 8)))
    return out^


def _emitir_buffer(
    mut corpo: List[UInt8], mut faixas: List[FaixaBuffer], dados: List[UInt8]
):
    """Acrescenta um buffer ao corpo e anota sua faixa, com o padding do Arrow."""
    var comeco = len(corpo)
    for b in dados:
        corpo.append(b)
    faixas.append(FaixaBuffer(comeco, len(corpo) - comeco))
    while len(corpo) % 8 != 0:
        corpo.append(UInt8(0))


def _buffers_da_coluna(
    c: Coluna, mut corpo: List[UInt8], mut faixas: List[FaixaBuffer]
) raises:
    var n = c.tamanho()
    _emitir_buffer(corpo, faixas, _bitmap_de_validade(c))

    if c.tipo == DType.LOGICO:
        var bits = (n + 7) // 8
        var vals = List[UInt8](capacity=bits)
        for _ in range(bits):
            vals.append(UInt8(0))
        for i in range(n):
            if not c.eh_ausente(i) and Int(c.logics[i]) != 0:
                vals[i // 8] = UInt8(Int(vals[i // 8]) | (1 << (i % 8)))
        _emitir_buffer(corpo, faixas, vals)
        return

    if c.tipo == DType.TEXTO:
        var offsets = List[UInt8]()
        var dados = List[UInt8]()
        _por_le(offsets, 0, 4)
        for i in range(n):
            if not c.eh_ausente(i):
                for b in c.texto_bruto(i).as_bytes():
                    dados.append(b)
            _por_le(offsets, len(dados), 4)
        _emitir_buffer(corpo, faixas, offsets)
        _emitir_buffer(corpo, faixas, dados)
        return

    var vals = List[UInt8]()
    if c.tipo == DType.REAL:
        for i in range(n):
            _por_le(vals, real64_para_bits(c.reals[i]), 8)
    elif c.tipo == DType.DATA:
        for i in range(n):
            _por_le(vals, Int(c.ints[i]), 4)
    else:
        for i in range(n):
            _por_le(vals, Int(c.ints[i]), 8)
    _emitir_buffer(corpo, faixas, vals)


def _escrever_lote(
    mut b: ConstrutorFlat, cols: List[Coluna], faixas: List[FaixaBuffer]
) raises -> Int:
    var n = 0
    if len(cols) > 0:
        n = cols[0].tamanho()

    # vetor de Buffer (struct inline: offset i64, length i64), de tras para frente
    b.iniciar_vetor(16, len(faixas), 8)
    for i in range(len(faixas) - 1, -1, -1):
        b.por_i64_cru(faixas[i].tamanho)
        b.por_i64_cru(faixas[i].deslocamento)
    var vetor_buffers = b.terminar_vetor(len(faixas))

    # vetor de FieldNode (length i64, null_count i64)
    b.iniciar_vetor(16, len(cols), 8)
    for i in range(len(cols) - 1, -1, -1):
        b.por_i64_cru(cols[i].contar_ausentes())
        b.por_i64_cru(cols[i].tamanho())
    var vetor_nos = b.terminar_vetor(len(cols))

    b.iniciar_tabela()
    b.campo_i64(0, n, 0)
    b.campo_referencia(1, vetor_nos)
    b.campo_referencia(2, vetor_buffers)
    return b.terminar_tabela()


def _por_mensagem(
    mut arquivo: List[UInt8], metadados: List[UInt8], corpo: List[UInt8]
) -> Int:
    """Escreve uma mensagem e devolve o tamanho do bloco de metadados."""
    var preenchido = _alinhar(len(metadados), 8)
    _por_le(arquivo, 0xFFFFFFFF, 4)
    _por_le(arquivo, preenchido, 4)
    for b in metadados:
        arquivo.append(b)
    for _ in range(preenchido - len(metadados)):
        arquivo.append(UInt8(0))
    for b in corpo:
        arquivo.append(b)
    return 8 + preenchido


def escrever_arrow(
    colunas: List[Coluna], caminho: String
) raises:
    """Grava um arquivo Arrow IPC com um unico record batch."""
    var arquivo = List[UInt8]()
    for b in String("ARROW1").as_bytes():
        arquivo.append(b)
    arquivo.append(UInt8(0))
    arquivo.append(UInt8(0))

    # ---- mensagem de esquema
    var be = ConstrutorFlat()
    var esquema = _escrever_esquema(be, colunas)
    var msg_esquema = _mensagem(be, _CABECALHO_ESQUEMA, esquema, 0)
    var bytes_esquema = be.finalizar(msg_esquema)
    _ = _por_mensagem(arquivo, bytes_esquema, List[UInt8]())

    # ---- mensagem de lote
    var corpo = List[UInt8]()
    var faixas = List[FaixaBuffer]()
    for c in colunas:
        _buffers_da_coluna(c, corpo, faixas)

    var bl = ConstrutorFlat()
    var lote = _escrever_lote(bl, colunas, faixas)
    var msg_lote = _mensagem(bl, _CABECALHO_LOTE, lote, len(corpo))
    var bytes_lote = bl.finalizar(msg_lote)

    var offset_lote = len(arquivo)
    var meta_lote = _por_mensagem(arquivo, bytes_lote, corpo)

    # ---- marcador de fim
    _por_le(arquivo, 0xFFFFFFFF, 4)
    _por_le(arquivo, 0, 4)

    # ---- rodape: esquema de novo + o bloco do lote
    var bf = ConstrutorFlat()
    var esquema_rodape = _escrever_esquema(bf, colunas)

    # vetor de Block (offset i64, metaDataLength i32, padding i32, bodyLength i64)
    bf.iniciar_vetor(24, 1, 8)
    bf.por_i64_cru(len(corpo))
    bf.por_i32_cru(0)
    bf.por_i32_cru(meta_lote)
    bf.por_i64_cru(offset_lote)
    var vetor_lotes = bf.terminar_vetor(1)

    bf.iniciar_vetor(24, 0, 8)
    var vetor_dicionarios = bf.terminar_vetor(0)

    bf.iniciar_tabela()
    bf.campo_i16(0, _VERSAO_V5, 0)
    bf.campo_referencia(1, esquema_rodape)
    bf.campo_referencia(2, vetor_dicionarios)
    bf.campo_referencia(3, vetor_lotes)
    var rodape = bf.terminar_tabela()
    var bytes_rodape = bf.finalizar(rodape)

    for b in bytes_rodape:
        arquivo.append(b)
    _por_le(arquivo, len(bytes_rodape), 4)
    for b in String("ARROW1").as_bytes():
        arquivo.append(b)

    Path(caminho).write_bytes(arquivo)


# ------------------------------------------------------------------ leitura

from .flatbuf import (
    ler_u8,
    ler_i16,
    ler_i32,
    ler_u32,
    ler_i64,
    raiz_flat,
    campo_flat,
    referencia_flat,
    texto_flat,
    tamanho_vetor_flat,
    inicio_vetor_flat,
)
from .codecs import bits_para_real64, bits_para_real32


@fieldwise_init
struct CampoArrow(Copyable, Movable):
    var nome: String
    var tipo: Int
    var largura: Int
    var unidade: Int
    var com_sinal: Bool
    """`is_signed` do `Int` do Arrow. Sem isto, um `uint32` volta como `int32` e
    4294967295 vira -1 — numero errado, sem aviso."""

    var dicionarizada: Bool
    """Coluna com `DictionaryEncoding` no esquema: os buffers sao indices."""


def _ler_campo_arrow(b: List[UInt8], pos_campo: Int) raises -> CampoArrow:
    var nome = String("")
    var p = campo_flat(b, pos_campo, 0)
    if p >= 0:
        nome = texto_flat(b, p)

    var tipo = 0
    p = campo_flat(b, pos_campo, 2)
    if p >= 0:
        tipo = ler_u8(b, p)

    # campo 4 do `Field` e `dictionary`: presente quer dizer coluna
    # dicionarizada, cujos buffers sao indices e nao valores. O Tucano
    # dicionariza texto por conta propria, mas nao le o dicionario do arquivo —
    # e sem esta deteccao a mensagem sairia falando de buffer, nao de tipo.
    var dicionarizada = campo_flat(b, pos_campo, 4) >= 0

    var largura = 0
    var unidade = -1
    var com_sinal = True
    var pt = campo_flat(b, pos_campo, 3)
    if pt >= 0:
        var t = referencia_flat(b, pt)
        if tipo == TipoArrow.INT:
            var pw = campo_flat(b, t, 0)
            largura = ler_i32(b, pw) if pw >= 0 else 32
            # `is_signed` e booleano do flatbuffer: campo ausente quer dizer
            # falso, e o Arrow escreve o campo sempre que ele e verdadeiro
            var ps = campo_flat(b, t, 1)
            com_sinal = ler_u8(b, ps) != 0 if ps >= 0 else False
        elif tipo == TipoArrow.PONTO_FLUTUANTE:
            var pp = campo_flat(b, t, 0)
            largura = ler_i16(b, pp) if pp >= 0 else 0
        elif tipo == TipoArrow.DATA:
            var pu = campo_flat(b, t, 0)
            # o padrao do campo e MILLISECOND
            unidade = ler_i16(b, pu) if pu >= 0 else 1
        elif tipo == TipoArrow.CARIMBO:
            var pu = campo_flat(b, t, 0)
            unidade = ler_i16(b, pu) if pu >= 0 else 0

    return CampoArrow(nome, tipo, largura, unidade, com_sinal, dicionarizada)


def _ler_esquema_arrow(b: List[UInt8], pos_esquema: Int) raises -> List[CampoArrow]:
    var out = List[CampoArrow]()
    var pf = campo_flat(b, pos_esquema, 1)
    if pf < 0:
        return out^
    var n = tamanho_vetor_flat(b, pf)
    var inicio = inicio_vetor_flat(b, pf)
    for i in range(n):
        out.append(_ler_campo_arrow(b, referencia_flat(b, inicio + i * 4)))
    return out^


def _tipo_tucano_de(c: CampoArrow) raises -> Int:
    if c.tipo == TipoArrow.BOOL:
        return DType.LOGICO
    if c.tipo == TipoArrow.UTF8:
        return DType.TEXTO
    if c.tipo == TipoArrow.PONTO_FLUTUANTE:
        return DType.REAL
    if c.tipo == TipoArrow.DATA:
        return DType.DATA
    if c.tipo == TipoArrow.CARIMBO:
        return DType.DATAHORA
    if c.tipo == TipoArrow.INT:
        return DType.INTEIRO
    raise Error(
        "arrow: coluna '" + c.nome + "' usa tipo " + String(c.tipo)
        + ", ainda nao suportado"
    )


def _bit(b: List[UInt8], base: Int, i: Int) -> Bool:
    return ((Int(b[base + i // 8]) >> (i % 8)) & 1) == 1


def _faixa(faixas: List[FaixaBuffer], i: Int, nome: String) raises -> FaixaBuffer:
    """Pega o i-esimo buffer da coluna, ou **levanta**.

    Um tipo do Arrow que o Tucano nao conhece pode trazer menos buffers do que o
    leitor espera — o tipo `Null` traz zero. Indexar direto nao da erro: aborta o
    processo com falha de limite, que nem `try` pega. Num leitor de arquivo de
    fora, todo caminho de arquivo estranho tem de sair por `raise`.
    """
    if i < 0 or i >= len(faixas):
        raise Error(
            "arrow: coluna '" + nome + "' tem " + String(len(faixas))
            + " buffer(s), e o leitor esperava mais — tipo nao suportado no"
            + " arquivo?"
        )
    return faixas[i]


def _coluna_do_lote(
    corpo: List[UInt8],
    campo: CampoArrow,
    n: Int,
    nulos: Int,
    faixas: List[FaixaBuffer],
    mut prox: Int,
) raises -> Coluna:
    if campo.dicionarizada:
        raise Error(
            "arrow: coluna '" + campo.nome + "' vem dicionarizada no arquivo, e"
            + " o leitor ainda nao desfaz o dicionario do Arrow"
        )
    if campo.tipo == TipoArrow.NULO:
        # o tipo `Null` do Arrow nao tem buffer nenhum, e o Tucano nao tem
        # coluna cujo tipo seja "so ausentes" — recusar diz a verdade; ler como
        # texto vazio inventaria um tipo que o arquivo nao tem
        raise Error(
            "arrow: coluna '" + campo.nome + "' e do tipo Null, que nao tem"
            + " equivalente no Tucano"
        )
    var validade = _faixa(faixas, prox, campo.nome)
    prox += 1

    var ausentes = List[Bool](capacity=n)
    for i in range(n):
        if nulos == 0 or validade.tamanho == 0:
            ausentes.append(False)
        else:
            ausentes.append(not _bit(corpo, validade.deslocamento, i))

    var tipo = _tipo_tucano_de(campo)

    if tipo == DType.TEXTO:
        var offs = _faixa(faixas, prox, campo.nome)
        prox += 1
        var dados = _faixa(faixas, prox, campo.nome)
        prox += 1
        var vals = List[String](capacity=n)
        for i in range(n):
            var a = ler_u32(corpo, offs.deslocamento + i * 4)
            var z = ler_u32(corpo, offs.deslocamento + (i + 1) * 4)
            if ausentes[i] or z <= a:
                vals.append("")
            else:
                vals.append(
                    String(
                        from_utf8=Span(corpo)[
                            dados.deslocamento + a : dados.deslocamento + z
                        ]
                    )
                )
        return Coluna.de_textos(campo.nome, vals^, ausentes^)

    var valores = _faixa(faixas, prox, campo.nome)
    prox += 1

    if tipo == DType.LOGICO:
        var vals = List[Bool](capacity=n)
        for i in range(n):
            vals.append(_bit(corpo, valores.deslocamento, i))
        return Coluna.de_logicos(campo.nome, vals^, ausentes^)

    if tipo == DType.REAL:
        var vals = List[Float64](capacity=n)
        for i in range(n):
            if campo.largura == 1:  # precisao simples
                vals.append(bits_para_real32(ler_u32(corpo, valores.deslocamento + i * 4)))
            else:
                vals.append(bits_para_real64(ler_i64(corpo, valores.deslocamento + i * 8)))
        return Coluna.de_reais(campo.nome, vals^, ausentes^)

    var vals = List[Int64](capacity=n)
    if tipo == DType.DATA:
        for i in range(n):
            var v = ler_i32(corpo, valores.deslocamento + i * 4)
            if campo.unidade == 1:  # milissegundos desde a epoca
                v = v // 86_400_000
            vals.append(Int64(v))
        return Coluna.de_datas(campo.nome, vals^, ausentes^)

    if tipo == DType.DATAHORA:
        for i in range(n):
            var v = ler_i64(corpo, valores.deslocamento + i * 8)
            if campo.unidade == 0:  # segundos
                v *= 1_000_000
            elif campo.unidade == 1:  # milissegundos
                v *= 1000
            elif campo.unidade == 3:  # nanossegundos
                v //= 1000
            vals.append(Int64(v))
        return Coluna.de_datahoras(campo.nome, vals^, ausentes^)

    var largura = campo.largura // 8
    if largura <= 0:
        largura = 4
    for i in range(n):
        if largura == 8:
            vals.append(Int64(ler_i64(corpo, valores.deslocamento + i * 8)))
        elif largura == 4:
            vals.append(Int64(ler_i32(corpo, valores.deslocamento + i * 4)))
        elif largura == 2:
            vals.append(Int64(ler_i16(corpo, valores.deslocamento + i * 2)))
        else:
            vals.append(Int64(ler_u8(corpo, valores.deslocamento + i)))

    if not campo.com_sinal and campo.largura > 0:
        # os leitores de 8, 16 e 32 bits estendem o sinal; sem sinal, o que
        # ficou negativo recebe a potencia de dois de volta e volta a caber com
        # folga. Em 64 bits nao ha correcao: acima de 2^63 o valor nao existe no
        # inteiro com sinal do Tucano, e recusar e o que nao mente.
        var volta = 1 << campo.largura
        for i in range(len(vals)):
            if vals[i] < 0:
                if campo.largura >= 64:
                    raise Error(
                        "arrow: coluna '" + campo.nome + "' e inteiro sem sinal"
                        + " de 64 bits com valor acima de 2^63, que nao cabe no"
                        + " inteiro com sinal do Tucano"
                    )
                vals[i] = vals[i] + Int64(volta)
    return Coluna.de_inteiros(campo.nome, vals^, ausentes^)


def ler_arrow_lote(caminho: String) raises -> List[Coluna]:
    """Le um arquivo Arrow IPC. Lotes multiplos sao concatenados."""
    var b = ler_arquivo_inteiro(caminho, "Arrow IPC")
    var n = len(b)
    if n < 20:
        raise Error("arrow: arquivo curto demais: " + caminho)
    var esperado = String("ARROW1").as_bytes()
    for i in range(6):
        if b[i] != esperado[i] or b[n - 6 + i] != esperado[i]:
            raise Error("arrow: magica ARROW1 ausente em " + caminho)

    var tamanho_rodape = ler_i32(b, n - 10)
    var pos_rodape = n - 10 - tamanho_rodape
    var rodape = raiz_flat(b, pos_rodape)

    var pe = campo_flat(b, rodape, 1)
    if pe < 0:
        raise Error("arrow: rodape sem esquema em " + caminho)
    var campos = _ler_esquema_arrow(b, referencia_flat(b, pe))

    var plotes = campo_flat(b, rodape, 3)
    if plotes < 0:
        raise Error("arrow: rodape sem record batches em " + caminho)
    var n_lotes = tamanho_vetor_flat(b, plotes)
    var inicio_blocos = inicio_vetor_flat(b, plotes)

    var saida = List[Coluna]()
    for l in range(n_lotes):
        var bloco = inicio_blocos + l * 24
        var deslocamento = ler_i64(b, bloco)
        var tamanho_meta = ler_i32(b, bloco + 8)

        var pos_meta = deslocamento + 8
        var mensagem = raiz_flat(b, pos_meta)
        var pc = campo_flat(b, mensagem, 2)
        if pc < 0:
            raise Error("arrow: mensagem sem cabecalho")
        var lote = referencia_flat(b, pc)
        var corpo_base = deslocamento + tamanho_meta

        var linhas = 0
        var pl = campo_flat(b, lote, 0)
        if pl >= 0:
            linhas = ler_i64(b, pl)

        var nulos = List[Int]()
        var pn = campo_flat(b, lote, 1)
        if pn >= 0:
            var qn = tamanho_vetor_flat(b, pn)
            var iv = inicio_vetor_flat(b, pn)
            for i in range(qn):
                nulos.append(ler_i64(b, iv + i * 16 + 8))

        var faixas = List[FaixaBuffer]()
        var pb = campo_flat(b, lote, 2)
        if pb >= 0:
            var qb = tamanho_vetor_flat(b, pb)
            var iv = inicio_vetor_flat(b, pb)
            for i in range(qb):
                faixas.append(
                    FaixaBuffer(
                        corpo_base + ler_i64(b, iv + i * 16),
                        ler_i64(b, iv + i * 16 + 8),
                    )
                )

        var prox = 0
        var deste = List[Coluna]()
        for i in range(len(campos)):
            var nulos_i = nulos[i] if i < len(nulos) else 0
            deste.append(
                _coluna_do_lote(b, campos[i], linhas, nulos_i, faixas, prox)
            )
        if len(saida) == 0:
            saida = deste^
        else:
            saida = _emendar(saida, deste)
    return saida^


def _emendar(a: List[Coluna], b: List[Coluna]) raises -> List[Coluna]:
    return op_concatenar(a, b)
