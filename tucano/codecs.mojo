"""Decodificadores de bytes usados pelo Parquet (M5).

Dois formatos, ambos independentes do resto da biblioteca:

**Snappy (formato cru)** — o codec de compressao padrao na pratica. Um varint com
o tamanho descomprimido, seguido de literais e referencias para tras. Sem
enquadramento de stream: as paginas do Parquet usam o formato cru.

**RLE / bit-packing hibrido** — carrega os niveis de definicao (quais linhas sao
ausentes) e os indices de dicionario. Alterna dois tipos de trecho, escolhidos
pelo bit menos significativo do cabecalho:

    cabecalho par  -> trecho RLE:        valor repetido `n` vezes
    cabecalho impar -> trecho empacotado: `n` grupos de 8 valores, bit a bit

O empacotamento e do bit menos significativo para o mais significativo dentro de
cada byte.
"""

from std.memory import bitcast


def bits_para_real64(bits: Int) -> Float64:
    """Reinterpreta 8 bytes little-endian como Float64 (IEEE-754).

    Mora aqui, e nao no leitor de Parquet, porque o `DType` que parametriza
    `bitcast` e o do Mojo — e no leitor esse nome ja pertence ao tipo logico do
    Tucano.
    """
    return bitcast[DType.float64](Int64(bits))


def bits_para_real32(bits: Int) -> Float64:
    return Float64(bitcast[DType.float32](Int32(bits)))


def descomprimir_snappy(bytes: List[UInt8], ini: Int, fim: Int) raises -> List[UInt8]:
    """Snappy cru: varint de tamanho, depois literais e copias para tras."""
    var pos = ini

    var tamanho = 0
    var deslocamento = 0
    while True:
        if pos >= fim:
            raise Error("snappy: fim inesperado no preambulo")
        var b = Int(bytes[pos])
        pos += 1
        tamanho |= (b & 0x7F) << deslocamento
        if b & 0x80 == 0:
            break
        deslocamento += 7
        if deslocamento > 35:
            raise Error("snappy: preambulo invalido")

    var out = List[UInt8](capacity=tamanho)

    while pos < fim:
        var tag = Int(bytes[pos])
        pos += 1
        var tipo = tag & 0x03

        if tipo == 0:
            # literal: comprimento no proprio tag, ou em ate 4 bytes a seguir
            var n = tag >> 2
            if n >= 60:
                var extras = n - 59
                n = 0
                for i in range(extras):
                    if pos + i >= fim:
                        raise Error("snappy: literal truncado")
                    n |= Int(bytes[pos + i]) << (8 * i)
                pos += extras
            n += 1
            if pos + n > fim:
                raise Error("snappy: literal ultrapassa a pagina")
            for i in range(n):
                out.append(bytes[pos + i])
            pos += n
            continue

        var comprimento: Int
        var deslocamento_copia: Int
        if tipo == 1:
            comprimento = 4 + ((tag >> 2) & 0x07)
            if pos >= fim:
                raise Error("snappy: copia truncada")
            deslocamento_copia = ((tag >> 5) << 8) | Int(bytes[pos])
            pos += 1
        elif tipo == 2:
            comprimento = (tag >> 2) + 1
            if pos + 2 > fim:
                raise Error("snappy: copia truncada")
            deslocamento_copia = Int(bytes[pos]) | (Int(bytes[pos + 1]) << 8)
            pos += 2
        else:
            comprimento = (tag >> 2) + 1
            if pos + 4 > fim:
                raise Error("snappy: copia truncada")
            deslocamento_copia = 0
            for i in range(4):
                deslocamento_copia |= Int(bytes[pos + i]) << (8 * i)
            pos += 4

        if deslocamento_copia <= 0 or deslocamento_copia > len(out):
            raise Error("snappy: deslocamento de copia invalido")
        # copia byte a byte: as faixas podem se sobrepor, e a sobreposicao e
        # justamente o que produz repeticao
        var origem = len(out) - deslocamento_copia
        for i in range(comprimento):
            out.append(out[origem + i])

    if len(out) != tamanho:
        raise Error(
            "snappy: descomprimiu " + String(len(out)) + " bytes, esperado "
            + String(tamanho)
        )
    return out^


def largura_de_bits(valor_max: Int) -> Int:
    """Bits necessarios para representar 0..valor_max."""
    var bits = 0
    var v = valor_max
    while v > 0:
        bits += 1
        v >>= 1
    return bits


@fieldwise_init
struct Cursor(Copyable, Movable, ImplicitlyCopyable):
    var pos: Int


def desempacotar_bits(
    bytes: List[UInt8], mut cursor: Cursor, quantidade: Int, largura: Int,
    mut saida: List[Int], fim: Int
) raises:
    """Le `quantidade` valores de `largura` bits, do menos ao mais significativo."""
    if largura == 0:
        for _ in range(quantidade):
            saida.append(0)
        return
    var mascara = (1 << largura) - 1
    var buffer = 0
    var bits = 0
    for _ in range(quantidade):
        while bits < largura:
            if cursor.pos >= fim:
                raise Error("rle: fim inesperado no trecho empacotado")
            buffer |= Int(bytes[cursor.pos]) << bits
            cursor.pos += 1
            bits += 8
        saida.append(buffer & mascara)
        buffer >>= largura
        bits -= largura


def _varint(bytes: List[UInt8], mut cursor: Cursor, fim: Int) raises -> Int:
    var resultado = 0
    var deslocamento = 0
    while True:
        if cursor.pos >= fim:
            raise Error("rle: fim inesperado no varint")
        var b = Int(bytes[cursor.pos])
        cursor.pos += 1
        resultado |= (b & 0x7F) << deslocamento
        if b & 0x80 == 0:
            break
        deslocamento += 7
        if deslocamento > 63:
            raise Error("rle: varint longo demais")
    return resultado


def decodificar_rle(
    bytes: List[UInt8], ini: Int, fim: Int, largura: Int, quantidade: Int
) raises -> List[Int]:
    """RLE / bit-packing hibrido: devolve exatamente `quantidade` valores."""
    var saida = List[Int](capacity=quantidade)
    var cursor = Cursor(ini)

    while len(saida) < quantidade:
        if cursor.pos >= fim:
            raise Error(
                "rle: acabaram os bytes com " + String(len(saida)) + " de "
                + String(quantidade) + " valores"
            )
        var cabecalho = _varint(bytes, cursor, fim)
        if cabecalho & 1 == 1:
            # trecho empacotado: o cabecalho conta GRUPOS de 8
            var grupos = cabecalho >> 1
            var n = grupos * 8
            var faltam = quantidade - len(saida)
            var lidos = List[Int](capacity=n)
            desempacotar_bits(bytes, cursor, n, largura, lidos, fim)
            # o ultimo grupo pode trazer valores de enchimento
            var usar = n
            if usar > faltam:
                usar = faltam
            for i in range(usar):
                saida.append(lidos[i])
        else:
            var repeticoes = cabecalho >> 1
            var bytes_valor = (largura + 7) // 8
            var valor = 0
            for i in range(bytes_valor):
                if cursor.pos >= fim:
                    raise Error("rle: fim inesperado no valor repetido")
                valor |= Int(bytes[cursor.pos]) << (8 * i)
                cursor.pos += 1
            var faltam = quantidade - len(saida)
            if repeticoes > faltam:
                repeticoes = faltam
            for _ in range(repeticoes):
                saida.append(valor)

    return saida^


def codificar_rle(valores: List[UInt8], largura: Int) -> List[UInt8]:
    """Codifica em trechos RLE, agrupando iguais consecutivos.

    Usado para os niveis de definicao na escrita. Com largura 1 e valores 0/1,
    trechos repetidos sao o caso comum e ficam com poucos bytes.
    """
    var out = List[UInt8]()
    var bytes_valor = (largura + 7) // 8
    var i = 0
    var n = len(valores)
    while i < n:
        var valor = valores[i]
        var fim = i + 1
        while fim < n and valores[fim] == valor:
            fim += 1
        var repeticoes = fim - i

        # cabecalho par = trecho RLE
        var cabecalho = repeticoes << 1
        while True:
            var b = cabecalho & 0x7F
            cabecalho >>= 7
            if cabecalho != 0:
                out.append(UInt8(b | 0x80))
            else:
                out.append(UInt8(b))
                break

        for k in range(bytes_valor):
            out.append(UInt8((Int(valor) >> (8 * k)) & 0xFF))
        i = fim
    return out^


def real64_para_bits(valor: Float64) -> Int:
    return Int(bitcast[DType.int64](valor))
