"""Codificadores e decodificadores de bytes usados pelo Parquet.

Dois formatos, ambos independentes do resto da biblioteca:

**Snappy (formato cru)** — o codec de compressao padrao na pratica. Um varint com
o tamanho descomprimido, seguido de literais e referencias para tras. Sem
enquadramento de stream: as paginas do Parquet usam o formato cru. Encoder e
decoder moram aqui; o escritor comprime, o leitor descomprime.

**RLE / bit-packing hibrido** — carrega os niveis de definicao (quais linhas sao
ausentes) e os indices de dicionario. Alterna dois tipos de trecho, escolhidos
pelo bit menos significativo do cabecalho:

    cabecalho par  -> trecho RLE:        valor repetido `n` vezes
    cabecalho impar -> trecho empacotado: `n` grupos de 8 valores, bit a bit

O empacotamento e do bit menos significativo para o mais significativo dentro de
cada byte.
"""

from std.ffi import external_call

from std.memory import bitcast
from std.ffi import external_call


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
    """Snappy cru: varint de tamanho, depois literais e copias para tras.

    O tamanho descomprimido vem no preambulo, entao a saida e alocada **uma vez**
    e escrita por ponteiro: some o `append` por byte e a verificacao de
    capacidade que vinha junto. Literal e copia em bloco.

    Copia para tras so anda byte a byte quando as faixas se sobrepoem — e a
    sobreposicao e justamente o que produz repeticao, entao ali a leitura
    precisa mesmo enxergar o que acabou de ser escrito. A partir de 16 bytes de
    distancia isso nao acontece dentro de um bloco de 16, e a copia anda larga.

    Literal curto continua no laco: abaixo de 16 bytes a chamada de `memcpy`
    custa mais que os bytes que ela copia.
    """
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
    out.resize(unsafe_uninit_length=tamanho)
    var destino = out.unsafe_ptr()
    # o mesmo buffer visto por outro ponteiro: a copia para tras le da saida que
    # ela mesma ja escreveu
    var relido = out.unsafe_ptr()
    var entrada = bytes.unsafe_ptr()
    var escritos = 0

    # a partir daqui a leitura e por ponteiro: o laco de tags roda uma vez por
    # elemento comprimido, e ali o teste de limite do `List` pesa mais que o
    # trabalho. Os limites da pagina continuam conferidos, uma vez por elemento
    # em vez de uma vez por byte.
    while pos < fim:
        var tag = Int(entrada.unsafe_load(pos))
        pos += 1
        var tipo = tag & 0x03

        if tipo == 0:
            # literal: comprimento no proprio tag, ou em ate 4 bytes a seguir
            var n = tag >> 2
            if n >= 60:
                var extras = n - 59
                n = 0
                if pos + extras > fim:
                    raise Error("snappy: literal truncado")
                for i in range(extras):
                    n |= Int(entrada.unsafe_load(pos + i)) << (8 * i)
                pos += extras
            n += 1
            if pos + n > fim:
                raise Error("snappy: literal ultrapassa a pagina")
            if escritos + n > tamanho:
                raise Error("snappy: literal ultrapassa o tamanho declarado")
            if n >= 16:
                _ = external_call["memcpy", Int](
                    destino.unsafe_offset(escritos), entrada.unsafe_offset(pos), n
                )
            else:
                for i in range(n):
                    destino.unsafe_store(escritos + i, entrada.unsafe_load(pos + i))
            escritos += n
            pos += n
            continue

        var comprimento: Int
        var deslocamento_copia: Int
        if tipo == 1:
            comprimento = 4 + ((tag >> 2) & 0x07)
            if pos >= fim:
                raise Error("snappy: copia truncada")
            deslocamento_copia = ((tag >> 5) << 8) | Int(entrada.unsafe_load(pos))
            pos += 1
        elif tipo == 2:
            comprimento = (tag >> 2) + 1
            if pos + 2 > fim:
                raise Error("snappy: copia truncada")
            deslocamento_copia = (
                Int(entrada.unsafe_load(pos))
                | (Int(entrada.unsafe_load(pos + 1)) << 8)
            )
            pos += 2
        else:
            comprimento = (tag >> 2) + 1
            if pos + 4 > fim:
                raise Error("snappy: copia truncada")
            deslocamento_copia = 0
            for i in range(4):
                deslocamento_copia |= Int(entrada.unsafe_load(pos + i)) << (8 * i)
            pos += 4

        if deslocamento_copia <= 0 or deslocamento_copia > escritos:
            raise Error("snappy: deslocamento de copia invalido")
        if escritos + comprimento > tamanho:
            raise Error("snappy: copia ultrapassa o tamanho declarado")
        var origem = escritos - deslocamento_copia
        if deslocamento_copia >= 16:
            # a origem esta pelo menos 16 bytes atras do destino, entao um bloco
            # de 16 nunca le byte que este mesmo bloco vai escrever
            var i = 0
            while i + 16 <= comprimento:
                destino.unsafe_offset(escritos + i).unsafe_store(
                    relido.unsafe_offset(origem + i).unsafe_load[width=16]()
                )
                i += 16
            while i < comprimento:
                destino.unsafe_store(escritos + i, relido.unsafe_load(origem + i))
                i += 1
        else:
            # faixas proximas: a leitura precisa enxergar o que acabou de ser
            # escrito, e e disso que sai a repeticao
            for i in range(comprimento):
                destino.unsafe_store(escritos + i, relido.unsafe_load(origem + i))
        escritos += comprimento

    if escritos != tamanho:
        raise Error(
            "snappy: descomprimiu " + String(escritos) + " bytes, esperado "
            + String(tamanho)
        )
    return out^


def _snappy_varint(mut out: List[UInt8], n: Int):
    var v = n
    while v >= 128:
        out.append(UInt8((v & 0x7F) | 0x80))
        v >>= 7
    out.append(UInt8(v))


def _snappy_literal(
    mut out: List[UInt8], src: List[UInt8], ini: Int, n: Int
):
    """Literal de `n` bytes a partir de `ini`."""
    if n <= 0:
        return
    var menos_um = n - 1
    if n <= 60:
        out.append(UInt8(menos_um << 2))
    elif menos_um < 256:
        out.append(UInt8(60 << 2))
        out.append(UInt8(menos_um))
    elif menos_um < 65536:
        out.append(UInt8(61 << 2))
        out.append(UInt8(menos_um & 0xFF))
        out.append(UInt8(menos_um >> 8))
    elif menos_um < 16777216:
        out.append(UInt8(62 << 2))
        out.append(UInt8(menos_um & 0xFF))
        out.append(UInt8((menos_um >> 8) & 0xFF))
        out.append(UInt8(menos_um >> 16))
    else:
        out.append(UInt8(63 << 2))
        out.append(UInt8(menos_um & 0xFF))
        out.append(UInt8((menos_um >> 8) & 0xFF))
        out.append(UInt8((menos_um >> 16) & 0xFF))
        out.append(UInt8(menos_um >> 24))
    var antes = len(out)
    out.resize(unsafe_uninit_length=antes + n)
    _ = external_call["memcpy", Int](
        out.unsafe_ptr().unsafe_offset(antes),
        src.unsafe_ptr().unsafe_offset(ini),
        n,
    )


def _snappy_copia(mut out: List[UInt8], comprimento: Int, offset: Int):
    """Uma ou mais copias cobrindo `comprimento` bytes a `offset` de distancia."""
    var rest = comprimento
    while rest > 0:
        var n = rest
        if n > 64:
            n = 64
        if n >= 4 and n <= 11 and offset < 2048:
            var tag = 1 | ((n - 4) << 2) | ((offset >> 8) << 5)
            out.append(UInt8(tag))
            out.append(UInt8(offset & 0xFF))
        else:
            var tag = 2 | ((n - 1) << 2)
            out.append(UInt8(tag))
            out.append(UInt8(offset & 0xFF))
            out.append(UInt8((offset >> 8) & 0xFF))
        rest -= n


def _snappy_hash4(src: List[UInt8], i: Int) -> Int:
    var v = Int(src[i])
    v |= Int(src[i + 1]) << 8
    v |= Int(src[i + 2]) << 16
    v |= Int(src[i + 3]) << 24
    return ((v * 0x1E35A7BD) >> 18) & 16383


def comprimir_snappy(src: List[UInt8]) raises -> List[UInt8]:
    """Snappy cru: o inverso de `descomprimir_snappy`.

    Greedy: literal ate achar 4 bytes que ja apareceram a ate 64 KiB.
    Copia de 1 ou 2 bytes de deslocamento, a mesma que o decoder le.
    """
    var n = len(src)
    var out = List[UInt8]()
    _snappy_varint(out, n)
    if n == 0:
        return out^
    if n < 4:
        _snappy_literal(out, src, 0, n)
        return out^

    var tab = List[Int](capacity=16384)
    tab.resize(16384, -1)
    var i = 0
    var lit = 0
    while i + 4 <= n:
        var h = _snappy_hash4(src, i)
        var cand = tab[h]
        tab[h] = i
        var off = i - cand
        if cand >= 0 and off > 0 and off <= 65535:
            if (
                src[cand] == src[i]
                and src[cand + 1] == src[i + 1]
                and src[cand + 2] == src[i + 2]
                and src[cand + 3] == src[i + 3]
            ):
                var m = 4
                while i + m < n and src[cand + m] == src[i + m]:
                    m += 1
                if i > lit:
                    _snappy_literal(out, src, lit, i - lit)
                _snappy_copia(out, m, off)
                var k = i + 1
                var fim = i + m
                while k + 4 <= n and k < fim:
                    tab[_snappy_hash4(src, k)] = k
                    k += 1
                i = fim
                lit = i
                continue
        i += 1
    if lit < n:
        _snappy_literal(out, src, lit, n - lit)
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
    """Le `quantidade` valores de `largura` bits, do menos ao mais significativo.

    Um trecho empacotado tem tamanho fechado — `quantidade * largura` bits — e
    da para conferir isso uma vez, na entrada, em vez de perguntar "cabe?" a
    cada byte. O resto e leitura por ponteiro e escrita em posicao ja reservada:
    e o laco mais quente da leitura de coluna dicionarizada, e nele o teste de
    limite do `List` custava mais que o deslocamento de bits.
    """
    if largura == 0:
        saida.resize(len(saida) + quantidade, 0)
        return
    var necessarios = (quantidade * largura + 7) // 8
    if cursor.pos + necessarios > fim:
        raise Error("rle: fim inesperado no trecho empacotado")
    var mascara = (1 << largura) - 1
    var antes = len(saida)
    saida.resize(antes + quantidade, 0)
    var destino = saida.unsafe_ptr().unsafe_offset(antes)
    var origem = bytes.unsafe_ptr()
    var pos = cursor.pos
    var buffer = 0
    var bits = 0
    for i in range(quantidade):
        while bits < largura:
            buffer |= Int(origem.unsafe_load(pos)) << bits
            pos += 1
            bits += 8
        destino.unsafe_store(i, buffer & mascara)
        buffer >>= largura
        bits -= largura
    cursor.pos = pos


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
            var alvo = len(saida)
            desempacotar_bits(bytes, cursor, n, largura, saida, fim)
            # o ultimo grupo pode trazer valores de enchimento
            if n > faltam:
                saida.resize(alvo + faltam, 0)
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
            saida.resize(len(saida) + repeticoes, valor)

    return saida^


def rle_valor_unico(
    bytes: List[UInt8], ini: Int, fim: Int, largura: Int, quantidade: Int
) raises -> Int:
    """Devolve o valor se a faixa inteira for **um unico trecho repetido**.

    Existe para a pergunta mais comum sobre niveis de definicao: "a pagina tem
    algum ausente?". A resposta quase sempre e nao, e escrita como um trecho RLE
    so — mas descobrir isso via `decodificar_rle` custa materializar um `Int` por
    linha (40 MiB em 5 milhoes) para depois compara-los todos com o mesmo numero.
    Aqui se le o cabecalho e pronto. Devolve -1 quando nao e trecho unico; o
    chamador entao decodifica de verdade.
    """
    if largura == 0:
        # largura zero: o valor e sempre 0 e nem bytes existem
        return 0
    var cursor = Cursor(ini)
    if cursor.pos >= fim:
        return -1
    var cabecalho = _varint(bytes, cursor, fim)
    if cabecalho & 1 == 1:
        return -1
    var repeticoes = cabecalho >> 1
    if repeticoes < quantidade:
        return -1
    var bytes_valor = (largura + 7) // 8
    var valor = 0
    for i in range(bytes_valor):
        if cursor.pos >= fim:
            return -1
        valor |= Int(bytes[cursor.pos]) << (8 * i)
        cursor.pos += 1
    return valor


def _varint_para(mut out: List[UInt8], valor: Int):
    var v = valor
    while True:
        var b = v & 0x7F
        v >>= 7
        if v != 0:
            out.append(UInt8(b | 0x80))
        else:
            out.append(UInt8(b))
            break


def desempacotar_bits_i32(
    bytes: List[UInt8], mut cursor: Cursor, quantidade: Int, largura: Int,
    mut saida: List[Int32], inicio: Int, guardar: Int, fim: Int
) raises:
    """Como `desempacotar_bits`, mas escreve `Int32` a partir de `inicio`.

    Le `quantidade` valores (o grupo empacotado, com enchimento) e guarda so
    os primeiros `guardar` — o restante e padding do ultimo grupo.
    """
    if largura == 0:
        var dest = saida.unsafe_ptr().unsafe_offset(inicio)
        for i in range(guardar):
            dest.unsafe_store(i, Int32(0))
        return
    var necessarios = (quantidade * largura + 7) // 8
    if cursor.pos + necessarios > fim:
        raise Error("rle: fim inesperado no trecho empacotado")
    var mascara = (1 << largura) - 1
    var dest = saida.unsafe_ptr().unsafe_offset(inicio)
    var origem = bytes.unsafe_ptr()
    var pos = cursor.pos
    var buffer = 0
    var bits = 0
    for i in range(quantidade):
        while bits < largura:
            buffer |= Int(origem.unsafe_load(pos)) << bits
            pos += 1
            bits += 8
        if i < guardar:
            dest.unsafe_store(i, Int32(buffer & mascara))
        buffer >>= largura
        bits -= largura
    cursor.pos = pos


def preencher_rle_i32(
    bytes: List[UInt8], ini: Int, fim: Int, largura: Int, quantidade: Int,
    mut saida: List[Int32], inicio: Int
) raises:
    """Decodifica RLE/bit-packing direto num `List[Int32]` ja dimensionado.

    O caminho antigo devolvia `List[Int]` — 8 bytes por indice, o dobro do
    codigo de dicionario, e ainda pedia um segundo laco para estreitar. Aqui o
    indice ja nasce no tipo em que a coluna o guarda.
    """
    if quantidade <= 0:
        return
    if inicio < 0 or inicio + quantidade > len(saida):
        raise Error("rle: destino nao comporta a quantidade pedida")
    if largura == 0:
        var dest = saida.unsafe_ptr().unsafe_offset(inicio)
        for i in range(quantidade):
            dest.unsafe_store(i, Int32(0))
        return

    var escrito = 0
    var cursor = Cursor(ini)
    var dest = saida.unsafe_ptr().unsafe_offset(inicio)

    while escrito < quantidade:
        if cursor.pos >= fim:
            raise Error(
                "rle: acabaram os bytes com " + String(escrito) + " de "
                + String(quantidade) + " valores"
            )
        var cabecalho = _varint(bytes, cursor, fim)
        if cabecalho & 1 == 1:
            var grupos = cabecalho >> 1
            var n = grupos * 8
            var faltam = quantidade - escrito
            var guardar = n
            if guardar > faltam:
                guardar = faltam
            desempacotar_bits_i32(
                bytes, cursor, n, largura, saida, inicio + escrito, guardar, fim
            )
            escrito += guardar
        else:
            var repeticoes = cabecalho >> 1
            var bytes_valor = (largura + 7) // 8
            var valor = 0
            for i in range(bytes_valor):
                if cursor.pos >= fim:
                    raise Error("rle: fim inesperado no valor repetido")
                valor |= Int(bytes[cursor.pos]) << (8 * i)
                cursor.pos += 1
            var faltam = quantidade - escrito
            if repeticoes > faltam:
                repeticoes = faltam
            var v = Int32(valor)
            for i in range(repeticoes):
                dest.unsafe_store(escrito + i, v)
            escrito += repeticoes


def decodificar_rle_i32(
    bytes: List[UInt8], ini: Int, fim: Int, largura: Int, quantidade: Int
) raises -> List[Int32]:
    var out = List[Int32](capacity=quantidade)
    if quantidade > 0:
        out.resize(unsafe_uninit_length=quantidade)
        preencher_rle_i32(bytes, ini, fim, largura, quantidade, out, 0)
    return out^


def remapeia_i32(
    mut v: List[Int32], inicio: Int, quantidade: Int, mapa: List[Int32]
) raises:
    """Troca indice local da pagina pelo codigo global, no proprio vetor."""
    if quantidade <= 0:
        return
    var p = v.unsafe_ptr().unsafe_offset(inicio)
    var m = mapa.unsafe_ptr()
    var n_mapa = len(mapa)
    for i in range(quantidade):
        var k = Int(p.unsafe_load(i))
        if k < 0 or k >= n_mapa:
            raise Error("parquet: indice de dicionario fora do mapa")
        p.unsafe_store(i, m.unsafe_load(k))


def _empacota_8(
    valores: List[Int32], ini: Int, n_vals: Int, largura: Int, mut out: List[UInt8]
):
    """Empacota exatamente 8 valores (faltantes viram 0), LSB primeiro."""
    if largura <= 0:
        return
    var mascara = (1 << largura) - 1
    var buffer = 0
    var bits = 0
    var n = len(valores)
    for k in range(8):
        var v = 0
        if k < n_vals and ini + k < n:
            v = Int(valores[ini + k]) & mascara
        buffer |= v << bits
        bits += largura
        while bits >= 8:
            out.append(UInt8(buffer & 0xFF))
            buffer >>= 8
            bits -= 8
    if bits > 0:
        out.append(UInt8(buffer & 0xFF))


def codificar_rle_i32(valores: List[Int32], largura: Int) -> List[UInt8]:
    """RLE/bit-packing hibrido de indices de dicionario.

    Trecho repetido de 8 ou mais vira RLE; o resto vai em grupos de 8
    empacotados. So RLE (o encoder antigo de niveis) em `i % 24` geraria um
    trecho por linha — o bit-packing e o que deixa o arquivo pequeno.
    """
    var out = List[UInt8]()
    var n = len(valores)
    if n == 0:
        return out^
    if largura == 0:
        _varint_para(out, n << 1)
        return out^

    var bytes_valor = (largura + 7) // 8
    var i = 0
    while i < n:
        var valor = valores[i]
        var fim = i + 1
        while fim < n and valores[fim] == valor:
            fim += 1
        var repeticoes = fim - i
        if repeticoes >= 8:
            _varint_para(out, repeticoes << 1)
            for k in range(bytes_valor):
                out.append(UInt8((Int(valor) >> (8 * k)) & 0xFF))
            i = fim
        else:
            var restam = n - i
            var neste = 8
            if restam < 8:
                neste = restam
            _varint_para(out, (1 << 1) | 1)
            _empacota_8(valores, i, neste, largura, out)
            i += 8
    return out^


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
