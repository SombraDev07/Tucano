"""Descompressao Zstandard (RFC 8878) — so o lado de leitura.

E o codec que falta para abrir o Parquet que o mundo escreve: o Polars grava
zstd por padrao, e o Spark grava com frequencia. Snappy e o inflate do gzip ja
estavam aqui; este e o terceiro e o maior.

O formato tem tres camadas, e vale ter o mapa antes de ler o codigo:

1. **Frame** — magica, cabecalho e uma sequencia de blocos. Um bloco e cru
   (copie), RLE (repita um byte) ou comprimido.
2. **Bloco comprimido** — duas secoes: os *literais* (os bytes que nao vieram de
   uma copia) e as *sequencias* (quantos literais copiar, e depois de que
   distancia e quanto casar de novo).
3. **Entropia** — os literais podem vir crus, em RLE ou em Huffman; as
   sequencias vem em FSE, que e o tANS. As duas leem o fluxo de bits **de tras
   para a frente**, que e a parte que mais surpreende quem ja escreveu um
   inflate.

Nada aqui comprime. Escrever zstd exigiria escolher casamentos e montar tabelas
de entropia, que e um projeto por si — e o Tucano escreve Snappy, que todo
leitor abre.
"""

from std.ffi import external_call
from std.memory import UnsafePointer


comptime _MAGICA = 0xFD2FB528

# Tipos de bloco (RFC 8878, 3.1.1.2)
comptime _BLOCO_CRU = 0
comptime _BLOCO_RLE = 1
comptime _BLOCO_COMPRIMIDO = 2


def _u8(b: List[UInt8], i: Int) raises -> Int:
    if i < 0 or i >= len(b):
        raise Error("zstd: leitura fora do quadro")
    return Int(b[i])


def _le(b: List[UInt8], i: Int, n: Int) raises -> Int:
    """`n` bytes little-endian a partir de `i`."""
    var v = 0
    for k in range(n):
        v |= _u8(b, i + k) << (8 * k)
    return v


struct _Quadro(Copyable, Movable):
    """O que o cabecalho do frame diz."""

    var inicio_blocos: Int
    var tem_checksum: Bool
    var tamanho_declarado: Int
    """Tamanho do conteudo, ou -1 quando o frame nao declara."""

    def __init__(out self):
        self.inicio_blocos = 0
        self.tem_checksum = False
        self.tamanho_declarado = -1


def _ler_cabecalho(b: List[UInt8]) raises -> _Quadro:
    """Cabecalho do frame: magica, descritor, janela, dicionario, tamanho.

    O descritor e um byte de campos empacotados, e o tamanho de tudo que vem
    depois dele depende desses campos — por isso a leitura e passo a passo em
    vez de um struct fixo.
    """
    if len(b) < 6:
        raise Error("zstd: quadro curto demais")
    if _le(b, 0, 4) != _MAGICA:
        raise Error("zstd: magica ausente")

    var fhd = _u8(b, 4)
    var flag_tamanho = (fhd >> 6) & 3
    var segmento_unico = ((fhd >> 5) & 1) == 1
    var tem_checksum = ((fhd >> 2) & 1) == 1
    var flag_dic = fhd & 3
    if (fhd >> 3) & 1 != 0:
        raise Error("zstd: bit reservado do descritor ligado")

    var pos = 5
    if not segmento_unico:
        pos += 1  # descritor de janela

    var bytes_dic = 0
    if flag_dic == 1:
        bytes_dic = 1
    elif flag_dic == 2:
        bytes_dic = 2
    elif flag_dic == 3:
        bytes_dic = 4
    if bytes_dic > 0:
        # ha dicionario: sem ele os literais nao sao reconstituiveis, e recusar
        # e melhor que devolver bytes que nao sao os do arquivo
        raise Error("zstd: quadro usa dicionario, que o Tucano nao carrega")

    var declarado = -1
    if flag_tamanho == 0:
        if segmento_unico:
            declarado = _u8(b, pos)
            pos += 1
    elif flag_tamanho == 1:
        declarado = _le(b, pos, 2) + 256
        pos += 2
    elif flag_tamanho == 2:
        declarado = _le(b, pos, 4)
        pos += 4
    else:
        declarado = _le(b, pos, 8)
        pos += 8

    var q = _Quadro()
    q.inicio_blocos = pos
    q.tem_checksum = tem_checksum
    q.tamanho_declarado = declarado
    return q^


def descomprimir_zstd(dados: List[UInt8], ini: Int, fim: Int) raises -> List[UInt8]:
    """Descomprime um frame zstd inteiro.

    `ini`/`fim` recortam o frame de dentro de um buffer maior — e como o Parquet
    entrega a pagina, sem copiar.
    """
    var b = List[UInt8](capacity=fim - ini)
    for i in range(ini, fim):
        b.append(dados[i])
    return _descomprimir_quadro(b)


def _descomprimir_quadro(b: List[UInt8]) raises -> List[UInt8]:
    var q = _ler_cabecalho(b)
    var pos = q.inicio_blocos
    var est = _EstadoQuadro()
    var out = List[UInt8]()
    if q.tamanho_declarado > 0:
        out.reserve(q.tamanho_declarado)

    while True:
        if pos + 3 > len(b):
            raise Error("zstd: cabecalho de bloco truncado")
        var cab = _le(b, pos, 3)
        pos += 3
        var ultimo = (cab & 1) == 1
        var tipo = (cab >> 1) & 3
        var tamanho = cab >> 3

        if tipo == _BLOCO_CRU:
            if pos + tamanho > len(b):
                raise Error("zstd: bloco cru ultrapassa o quadro")
            for i in range(tamanho):
                out.append(b[pos + i])
            pos += tamanho
        elif tipo == _BLOCO_RLE:
            var v = UInt8(_u8(b, pos))
            pos += 1
            for _ in range(tamanho):
                out.append(v)
        elif tipo == _BLOCO_COMPRIMIDO:
            if pos + tamanho > len(b):
                raise Error("zstd: bloco comprimido ultrapassa o quadro")
            _bloco_comprimido_com_estado(b, pos, pos + tamanho, out, est)
            pos += tamanho
        else:
            raise Error("zstd: tipo de bloco reservado")

        if ultimo:
            break

    if q.tem_checksum:
        pos += 4  # XXH64 truncado; ver nota em `_descomprimir_quadro`

    if q.tamanho_declarado >= 0 and len(out) != q.tamanho_declarado:
        raise Error(
            "zstd: quadro declara " + String(q.tamanho_declarado)
            + " bytes e produziu " + String(len(out))
        )
    return out^


# --------------------------------------------------- fluxo de bits ao contrario


struct _BitsTras(Movable):
    """Le bits do **fim para o comeco**, do mais significativo para o menos.

    E a parte que surpreende quem ja escreveu um inflate, onde tudo anda para a
    frente. No zstd o ultimo byte do fluxo carrega um marcador: o bit 1 mais
    alto dele nao e dado, e sim o sinal de onde os dados terminam. Abaixo dele
    comeca a leitura, andando para tras byte a byte.

    Passado o inicio do fluxo, os bits que faltam sao **zeros fabricados** — e
    `esgotou()` diz se isso aconteceu, para o chamador recusar em vez de aceitar
    dado inventado.

    O buffer entra como **endereco**, nao como `List`: um bloco tem ate cinco
    fluxos sobre faixas diferentes do mesmo buffer, e guardar a lista em cada um
    copiaria o bloco cinco vezes. E a mesma forma que `_do_ambiente` usa com o
    `getenv` — o buffer vive na pilha de quem chamou, do inicio ao fim.
    """

    var endereco: Int
    var ini: Int
    var pos: Int
    var acc: Int
    var nbits: Int
    var consumidos: Int
    var total: Int
    """Bits de dado que o fluxo tem, contados no construtor. Saber o total de
    antemao e o que deixa `esgotou()` ser exato em vez de heuristico."""

    def __init__(out self, b: List[UInt8], ini: Int, fim: Int) raises:
        self.endereco = Int(b.unsafe_ptr())
        self.ini = ini
        self.acc = 0
        self.nbits = 0
        self.consumidos = 0
        self.total = 0
        if fim <= ini:
            raise Error("zstd: fluxo de bits vazio")
        var ultimo = Int(b[fim - 1])
        if ultimo == 0:
            raise Error("zstd: ultimo byte do fluxo sem marcador")
        var alto = 7
        while (ultimo >> alto) & 1 == 0:
            alto -= 1
        self.acc = ultimo & ((1 << alto) - 1)
        self.nbits = alto
        self.pos = fim - 2
        self.total = (fim - 1 - ini) * 8 + alto

    def ler(mut self, n: Int) raises -> Int:
        if n == 0:
            return 0
        if n > 32:
            raise Error("zstd: leitura de mais de 32 bits")
        var p = UnsafePointer[UInt8, origin=AnyOrigin[mut=True]](
            unsafe_from_address=self.endereco
        )
        while self.nbits < n:
            var b = 0
            if self.pos >= self.ini:
                b = Int(p.unsafe_load(self.pos))
            self.pos -= 1
            self.acc = (self.acc << 8) | b
            self.nbits += 8
        var v = (self.acc >> (self.nbits - n)) & ((1 << n) - 1)
        self.nbits -= n
        self.acc = self.acc & ((1 << self.nbits) - 1)
        self.consumidos += n
        return v

    def esgotou(self) -> Bool:
        """O fluxo ja entregou todos os bits que tinha."""
        return self.consumidos > self.total


struct _BitsFrente(Movable):
    """Fluxo de bits para a frente, do menos significativo para o mais.

    So a descricao das tabelas FSE usa este sentido; os dados usam o outro. Ter
    os dois no mesmo arquivo e desconfortavel, e e o que o formato pede.
    """

    var endereco: Int
    var pos: Int
    var fim: Int
    var acc: Int
    var nbits: Int

    def __init__(out self, b: List[UInt8], ini: Int, fim: Int):
        self.endereco = Int(b.unsafe_ptr())
        self.pos = ini
        self.fim = fim
        self.acc = 0
        self.nbits = 0

    def ler(mut self, n: Int) -> Int:
        var p = UnsafePointer[UInt8, origin=AnyOrigin[mut=True]](
            unsafe_from_address=self.endereco
        )
        while self.nbits < n:
            var b = 0
            if self.pos < self.fim:
                b = Int(p.unsafe_load(self.pos))
            self.pos += 1
            self.acc |= b << self.nbits
            self.nbits += 8
        var v = self.acc & ((1 << n) - 1)
        self.acc = (self.acc >> n) & ((1 << (63 - n)) - 1)
        self.nbits -= n
        return v

    def bytes_consumidos(self) -> Int:
        return self.pos - (self.nbits // 8)


# ------------------------------------------------------------------- FSE


struct _TabelaFSE(Copyable, Movable):
    """Tabela de decodificacao FSE: por estado, o simbolo e como andar."""

    var simbolo: List[UInt8]
    var nbits: List[UInt8]
    var base: List[Int32]
    var accuracy: Int

    def __init__(out self):
        self.simbolo = List[UInt8]()
        self.nbits = List[UInt8]()
        self.base = List[Int32]()
        self.accuracy = 0


def _construir_fse(contagens: List[Int], maior_simbolo: Int, accuracy: Int) raises -> _TabelaFSE:
    """Monta a tabela a partir da distribuicao normalizada.

    O espalhamento e o do formato: anda de `(tam>>1) + (tam>>3) + 3` em `tam`,
    pulando as posicoes altas reservadas aos simbolos de contagem -1. Nao e uma
    escolha do decodificador — o codificador espalhou assim, e so a mesma ordem
    reconstroi as mesmas transicoes.
    """
    var tam = 1 << accuracy
    var t = _TabelaFSE()
    t.accuracy = accuracy
    t.simbolo.resize(tam, UInt8(0))
    t.nbits.resize(tam, UInt8(0))
    t.base.resize(tam, Int32(0))

    var alto = tam - 1
    var posicao = List[Int]()
    posicao.resize(tam, 0)

    # contagem -1 ("menos provavel") ocupa o fim da tabela, de tras para a frente
    for s in range(maior_simbolo + 1):
        if contagens[s] == -1:
            t.simbolo[alto] = UInt8(s)
            alto -= 1
            posicao[alto + 1] = 1

    var passo = (tam >> 1) + (tam >> 3) + 3
    var mascara = tam - 1
    var p = 0
    for s in range(maior_simbolo + 1):
        var c = contagens[s]
        if c <= 0:
            continue
        for _ in range(c):
            t.simbolo[p] = UInt8(s)
            p = (p + passo) & mascara
            while p > alto:
                p = (p + passo) & mascara

    if p != 0:
        raise Error("zstd: espalhamento FSE nao fechou")

    # quantos bits ler em cada estado, e para onde ir
    var proximo = List[Int]()
    proximo.resize(maior_simbolo + 1, 0)
    for s in range(maior_simbolo + 1):
        if contagens[s] == -1:
            proximo[s] = 1
        elif contagens[s] > 0:
            proximo[s] = contagens[s]

    for i in range(tam):
        var s = Int(t.simbolo[i])
        var n = proximo[s]
        proximo[s] = n + 1
        var bits = accuracy - _log2_teto(n)
        t.nbits[i] = UInt8(bits)
        t.base[i] = Int32((n << bits) - tam)
    return t^


def _log2_teto(v: Int) -> Int:
    var n = 0
    while (1 << (n + 1)) <= v:
        n += 1
    return n


def _ler_distribuicao(
    b: List[UInt8], ini: Int, fim: Int, maior_permitido: Int, accuracy_max: Int
) raises -> Tuple[_TabelaFSE, Int]:
    """Le a descricao da tabela e devolve a tabela e quantos bytes ela ocupou.

    A descricao vem em bitstream **para a frente**, com um numero de bits que
    encolhe conforme o que sobra para distribuir — e a parte do formato que mais
    parece arbitraria e a que menos perdoa erro de um bit.
    """
    var bits = _BitsFrente(b, ini, fim)
    var accuracy = bits.ler(4) + 5
    if accuracy > accuracy_max:
        raise Error("zstd: accuracy FSE acima do permitido")
    var tam = 1 << accuracy

    var contagens = List[Int]()
    contagens.resize(maior_permitido + 1, 0)
    var restante = tam + 1
    var simbolo = 0
    var anterior_zero = False

    while restante > 1 and simbolo <= maior_permitido:
        if anterior_zero:
            # sequencias de simbolos com contagem zero vem em grupos de 2 bits
            var zeros = 0
            while True:
                var r = bits.ler(2)
                zeros += r
                if r != 3:
                    break
            for _ in range(zeros):
                if simbolo > maior_permitido:
                    break
                contagens[simbolo] = 0
                simbolo += 1
            anterior_zero = False
            continue

        var teto = _log2_teto(restante) + 1
        var limite = (1 << teto) - 1 - restante
        var v = bits.ler(teto - 1)
        if v < limite:
            pass
        else:
            var extra = bits.ler(1)
            v = v + (extra << (teto - 1))
            if v >= (1 << (teto - 1)):
                v -= limite
        var contagem = v - 1
        if simbolo > maior_permitido:
            raise Error("zstd: distribuicao FSE com simbolo alem do permitido")
        contagens[simbolo] = contagem
        if contagem == 0:
            anterior_zero = True
        var usado = contagem
        if usado < 0:
            usado = -usado
        restante -= usado
        simbolo += 1

    if restante != 1:
        raise Error("zstd: distribuicao FSE nao soma o tamanho da tabela")

    var maior = simbolo - 1
    var t = _construir_fse(contagens, maior, accuracy)
    return (t^, bits.bytes_consumidos() - ini)


# ---------------------------------------------------------------- Huffman


struct _Huff(Copyable, Movable):
    """Tabela de Huffman achatada: `2^maxbits` entradas de (simbolo, bits)."""

    var simbolo: List[UInt8]
    var nbits: List[UInt8]
    var maxbits: Int

    def __init__(out self):
        self.simbolo = List[UInt8]()
        self.nbits = List[UInt8]()
        self.maxbits = 0


def _huff_de_pesos(pesos: List[Int], n: Int) raises -> _Huff:
    """Dos pesos para a tabela achatada.

    Peso zero quer dizer "simbolo ausente"; peso `w` quer dizer que o simbolo
    ocupa `2^(w-1)` das entradas. O **ultimo** peso nao vem no fluxo: ele e o
    que falta para a soma virar potencia de dois, e e por isso que a soma tem de
    ser conferida — um peso corrompido apareceria aqui como tabela impossivel.
    """
    var total = 0
    for i in range(n):
        if pesos[i] > 0:
            total += 1 << (pesos[i] - 1)
    if total == 0:
        raise Error("zstd: tabela Huffman sem simbolo")
    var maxbits = _log2_teto(total) + 1
    var resto = (1 << maxbits) - total
    if resto <= 0 or (resto & (resto - 1)) != 0:
        raise Error("zstd: pesos Huffman nao fecham em potencia de dois")

    var todos = List[Int]()
    for i in range(n):
        todos.append(pesos[i])
    todos.append(_log2_teto(resto) + 1)  # o peso derivado do ultimo simbolo

    var h = _Huff()
    h.maxbits = maxbits
    var tam = 1 << maxbits
    h.simbolo.resize(tam, UInt8(0))
    h.nbits.resize(tam, UInt8(0))

    # entradas em ordem de peso decrescente, como o codificador montou
    var pos = 0
    for peso in range(1, maxbits + 1):
        for s in range(len(todos)):
            if todos[s] != peso:
                continue
            var quantas = 1 << (peso - 1)
            var bits = maxbits + 1 - peso
            for _ in range(quantas):
                if pos >= tam:
                    raise Error("zstd: tabela Huffman transbordou")
                h.simbolo[pos] = UInt8(s)
                h.nbits[pos] = UInt8(bits)
                pos += 1
    if pos != tam:
        raise Error("zstd: tabela Huffman incompleta")
    return h^


def _ler_huffman(b: List[UInt8], ini: Int, fim: Int) raises -> Tuple[_Huff, Int]:
    """Descricao da tabela de Huffman; devolve a tabela e os bytes que ocupou."""
    var cab = _u8(b, ini)
    var pos = ini + 1
    var pesos = List[Int]()

    if cab >= 128:
        # pesos diretos, 4 bits cada
        var n = cab - 127
        var lidos = 0
        while lidos < n:
            var byte = _u8(b, pos)
            pos += 1
            pesos.append((byte >> 4) & 0xF)
            lidos += 1
            if lidos < n:
                pesos.append(byte & 0xF)
                lidos += 1
        return (_huff_de_pesos(pesos, n), pos - ini)

    # pesos comprimidos em FSE, com accuracy de no maximo 6
    var fim_pesos = pos + cab
    if fim_pesos > fim:
        raise Error("zstd: pesos Huffman ultrapassam a secao")
    var par = _ler_distribuicao(b, pos, fim_pesos, 255, 6)
    var tabela = par[0].copy()
    var gastos = par[1]
    var inicio_fluxo = pos + gastos

    # dois estados alternados sobre o mesmo fluxo, lido de tras para frente
    var bits = _BitsTras(b, inicio_fluxo, fim_pesos)
    var e1 = bits.ler(tabela.accuracy)
    var e2 = bits.ler(tabela.accuracy)
    var n = 0
    while n < 255:
        pesos.append(Int(tabela.simbolo[e1]))
        n += 1
        e1 = Int(tabela.base[e1]) + bits.ler(Int(tabela.nbits[e1]))
        if bits.esgotou():
            pesos.append(Int(tabela.simbolo[e2]))
            n += 1
            break
        pesos.append(Int(tabela.simbolo[e2]))
        n += 1
        e2 = Int(tabela.base[e2]) + bits.ler(Int(tabela.nbits[e2]))
        if bits.esgotou():
            pesos.append(Int(tabela.simbolo[e1]))
            n += 1
            break
    return (_huff_de_pesos(pesos, n), fim_pesos - ini)


def _decodificar_huff(
    mut bits: _BitsTras, h: _Huff, quantos: Int, mut out: List[UInt8]
) raises:
    var estado = bits.ler(h.maxbits)
    var feitos = 0
    while feitos < quantos:
        var s = h.simbolo[estado]
        var usados = Int(h.nbits[estado])
        out.append(s)
        feitos += 1
        if feitos == quantos:
            break
        var novos = bits.ler(usados)
        estado = ((estado << usados) | novos) & ((1 << h.maxbits) - 1)


# ------------------------------------------------------- tabelas do formato


def _ll_base() -> List[Int]:
    var v = List[Int]()
    for i in range(16):
        v.append(i)
    for x in [16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024,
              2048, 4096, 8192, 16384, 32768, 65536]:
        v.append(x)
    return v^


def _ll_bits() -> List[Int]:
    var v = List[Int]()
    for _ in range(16):
        v.append(0)
    for x in [1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]:
        v.append(x)
    return v^


def _ml_base() -> List[Int]:
    var v = List[Int]()
    for i in range(32):
        v.append(3 + i)
    for x in [35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027,
              2051, 4099, 8195, 16387, 32771, 65539]:
        v.append(x)
    return v^


def _ml_bits() -> List[Int]:
    var v = List[Int]()
    for _ in range(32):
        v.append(0)
    for x in [1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]:
        v.append(x)
    return v^


def _dist_ll_padrao() -> List[Int]:
    return [4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2,
            2, 2, 2, 3, 2, 1, 1, 1, 1, 1, -1, -1, -1, -1]


def _dist_ml_padrao() -> List[Int]:
    """Distribuicao normalizada padrao do comprimento de casamento.

    Cinquenta e tres simbolos que somam 64 — a soma **tem** de fechar em 2^6, e
    e a unica conferencia barata contra erro de transcricao. Escrita de memoria
    na primeira versao, com um `1` a mais e um `-1` a menos: somava 64 do mesmo
    jeito e produzia uma tabela deslocada, que decodificava comprimento 7963
    onde o certo era 998. Errar aqui nao da erro — da bytes.
    """
    var v = List[Int]()
    for x in [1, 4, 3, 2, 2, 2, 2, 2, 2]:
        v.append(x)          # simbolos 0..8
    for _ in range(37):
        v.append(1)          # simbolos 9..45
    for _ in range(7):
        v.append(-1)         # simbolos 46..52
    return v^


def _dist_of_padrao() -> List[Int]:
    return [1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
            1, 1, -1, -1, -1, -1, -1]


struct _EstadoQuadro(Movable):
    """O que atravessa blocos dentro do mesmo frame.

    Tres coisas sobrevivem de um bloco para o outro, e esquecer qualquer uma
    delas produz bytes errados sem erro nenhum: os deslocamentos repetidos, as
    tabelas FSE em modo "repetir" e a tabela de Huffman dos literais sem arvore.
    """

    var rep: List[Int]
    var huff: _Huff
    var tem_huff: Bool
    var fse_ll: _TabelaFSE
    var fse_of: _TabelaFSE
    var fse_ml: _TabelaFSE
    var tem_ll: Bool
    var tem_of: Bool
    var tem_ml: Bool

    def __init__(out self):
        self.rep = [1, 4, 8]
        self.huff = _Huff()
        self.tem_huff = False
        self.fse_ll = _TabelaFSE()
        self.fse_of = _TabelaFSE()
        self.fse_ml = _TabelaFSE()
        self.tem_ll = False
        self.tem_of = False
        self.tem_ml = False


# ------------------------------------------------------------ bloco comprimido


def _ler_literais(
    b: List[UInt8], ini: Int, fim: Int, mut est: _EstadoQuadro
) raises -> Tuple[List[UInt8], Int]:
    """Secao de literais: crua, RLE, Huffman com tabela, ou Huffman herdada."""
    var cab = _u8(b, ini)
    var tipo = cab & 3
    var formato = (cab >> 2) & 3
    var pos = ini
    var regenerado = 0
    var comprimido = 0
    var fluxos = 1

    if tipo == 0 or tipo == 1:  # cru ou RLE
        if formato == 0 or formato == 2:
            regenerado = (cab >> 3) & 0x1F
            pos += 1
        elif formato == 1:
            regenerado = ((cab >> 4) & 0xF) | (_u8(b, ini + 1) << 4)
            pos += 2
        else:
            regenerado = (
                ((cab >> 4) & 0xF) | (_u8(b, ini + 1) << 4)
                | (_u8(b, ini + 2) << 12)
            )
            pos += 3
        var out = List[UInt8](capacity=regenerado)
        if tipo == 0:
            if pos + regenerado > fim:
                raise Error("zstd: literais crus ultrapassam o bloco")
            for i in range(regenerado):
                out.append(b[pos + i])
            return (out^, pos + regenerado - ini)
        var v = UInt8(_u8(b, pos))
        for _ in range(regenerado):
            out.append(v)
        return (out^, pos + 1 - ini)

    # comprimido (2) ou sem arvore (3)
    if formato == 0:
        fluxos = 1
        regenerado = ((cab >> 4) & 0xF) | ((_u8(b, ini + 1) & 0x3F) << 4)
        comprimido = (
            ((_u8(b, ini + 1) >> 6) & 3) | (_u8(b, ini + 2) << 2)
        )
        pos += 3
    elif formato == 1:
        fluxos = 4
        regenerado = ((cab >> 4) & 0xF) | ((_u8(b, ini + 1) & 0x3F) << 4)
        comprimido = (
            ((_u8(b, ini + 1) >> 6) & 3) | (_u8(b, ini + 2) << 2)
        )
        pos += 3
    elif formato == 2:
        fluxos = 4
        regenerado = (
            ((cab >> 4) & 0xF) | (_u8(b, ini + 1) << 4)
            | ((_u8(b, ini + 2) & 3) << 12)
        )
        comprimido = (
            ((_u8(b, ini + 2) >> 2) & 0x3F) | (_u8(b, ini + 3) << 6)
        )
        pos += 4
    else:
        fluxos = 4
        regenerado = (
            ((cab >> 4) & 0xF) | (_u8(b, ini + 1) << 4)
            | ((_u8(b, ini + 2) & 0x3F) << 12)
        )
        comprimido = (
            ((_u8(b, ini + 2) >> 6) & 3) | (_u8(b, ini + 3) << 2)
            | (_u8(b, ini + 4) << 10)
        )
        pos += 5

    var fim_secao = pos + comprimido
    if fim_secao > fim:
        raise Error("zstd: literais comprimidos ultrapassam o bloco")

    var inicio_fluxos = pos
    if tipo == 2:
        var par = _ler_huffman(b, pos, fim_secao)
        est.huff = par[0].copy()
        est.tem_huff = True
        inicio_fluxos = pos + par[1]
    elif not est.tem_huff:
        raise Error("zstd: literais sem arvore, mas nenhuma tabela anterior")

    var out = List[UInt8](capacity=regenerado)
    if fluxos == 1:
        var bits = _BitsTras(b, inicio_fluxos, fim_secao)
        _decodificar_huff(bits, est.huff, regenerado, out)
        return (out^, fim_secao - ini)

    # quatro fluxos: tabela de saltos com os tres primeiros tamanhos
    if inicio_fluxos + 6 > fim_secao:
        raise Error("zstd: tabela de saltos truncada")
    var t1 = _le(b, inicio_fluxos, 2)
    var t2 = _le(b, inicio_fluxos + 2, 2)
    var t3 = _le(b, inicio_fluxos + 4, 2)
    var p0 = inicio_fluxos + 6
    var p1 = p0 + t1
    var p2 = p1 + t2
    var p3 = p2 + t3
    if p3 > fim_secao:
        raise Error("zstd: fluxos de literais ultrapassam a secao")

    # os tres primeiros levam o mesmo tanto; o quarto leva o que sobrar
    var por_fluxo = (regenerado + 3) // 4
    var ultimo = regenerado - 3 * por_fluxo
    if ultimo < 0:
        raise Error("zstd: reparticao dos fluxos de literais impossivel")
    var limites = [p0, p1, p2, p3, fim_secao]
    var quantidades = [por_fluxo, por_fluxo, por_fluxo, ultimo]
    for f in range(4):
        var bits = _BitsTras(b, limites[f], limites[f + 1])
        _decodificar_huff(bits, est.huff, quantidades[f], out)
    return (out^, fim_secao - ini)


def _tabela_de_modo(
    b: List[UInt8], pos: Int, fim: Int, modo: Int, padrao: List[Int],
    maior: Int, accuracy_padrao: Int, accuracy_max: Int,
    mut destino: _TabelaFSE, mut tem: Bool,
) raises -> Int:
    """Uma das tres tabelas de sequencia; devolve quantos bytes consumiu.

    Quatro modos: predefinida, RLE (um simbolo so), descrita no fluxo, ou
    repetida do bloco anterior. O modo "repetir" e a razao de as tabelas viverem
    no estado do frame e nao numa variavel local.
    """
    if modo == 0:
        destino = _construir_fse(padrao, maior, accuracy_padrao)
        tem = True
        return 0
    if modo == 1:
        var s = _u8(b, pos)
        var c = List[Int]()
        c.resize(s + 1, 0)
        c[s] = 1
        destino = _construir_fse(c, s, 0)
        tem = True
        return 1
    if modo == 2:
        var par = _ler_distribuicao(b, pos, fim, maior, accuracy_max)
        destino = par[0].copy()
        tem = True
        return par[1]
    if not tem:
        raise Error("zstd: tabela FSE em modo repetir sem tabela anterior")
    return 0


def _bloco_comprimido_com_estado(
    b: List[UInt8], ini: Int, fim: Int, mut saida: List[UInt8],
    mut est: _EstadoQuadro,
) raises:
    var par = _ler_literais(b, ini, fim, est)
    var literais = par[0].copy()
    var pos = ini + par[1]

    # ---- quantas sequencias
    if pos >= fim:
        # bloco so de literais: copia e acabou
        for x in literais:
            saida.append(x)
        return
    var b0 = _u8(b, pos)
    pos += 1
    var n_seq = 0
    if b0 == 0:
        for x in literais:
            saida.append(x)
        return
    elif b0 < 128:
        n_seq = b0
    elif b0 < 255:
        n_seq = ((b0 - 128) << 8) + _u8(b, pos)
        pos += 1
    else:
        n_seq = _le(b, pos, 2) + 0x7F00
        pos += 2

    var modos = _u8(b, pos)
    pos += 1
    if modos & 3 != 0:
        raise Error("zstd: bits reservados dos modos de sequencia ligados")
    var modo_ll = (modos >> 6) & 3
    var modo_of = (modos >> 4) & 3
    var modo_ml = (modos >> 2) & 3

    pos += _tabela_de_modo(
        b, pos, fim, modo_ll, _dist_ll_padrao(), 35, 6, 9,
        est.fse_ll, est.tem_ll,
    )
    pos += _tabela_de_modo(
        b, pos, fim, modo_of, _dist_of_padrao(), 28, 5, 8,
        est.fse_of, est.tem_of,
    )
    pos += _tabela_de_modo(
        b, pos, fim, modo_ml, _dist_ml_padrao(), 52, 6, 9,
        est.fse_ml, est.tem_ml,
    )

    # ---- o fluxo de sequencias, de tras para a frente
    var bits = _BitsTras(b, pos, fim)
    var ll_base = _ll_base()
    var ll_bits = _ll_bits()
    var ml_base = _ml_base()
    var ml_bits = _ml_bits()

    # ordem de inicializacao: comprimento de literal, deslocamento, casamento
    var e_ll = bits.ler(est.fse_ll.accuracy)
    var e_of = bits.ler(est.fse_of.accuracy)
    var e_ml = bits.ler(est.fse_ml.accuracy)

    var pl = 0  # quantos literais ja foram copiados
    for s in range(n_seq):
        var cod_ll = Int(est.fse_ll.simbolo[e_ll])
        var cod_ml = Int(est.fse_ml.simbolo[e_ml])
        var cod_of = Int(est.fse_of.simbolo[e_of])
        if cod_ll > 35 or cod_ml > 52:
            raise Error("zstd: codigo de sequencia fora da tabela")

        # ordem de leitura dos extras: deslocamento, casamento, literal
        var desloc_bruto = (1 << cod_of) + bits.ler(cod_of)
        var casamento = ml_base[cod_ml] + bits.ler(ml_bits[cod_ml])
        var literal = ll_base[cod_ll] + bits.ler(ll_bits[cod_ll])

        # ---- deslocamentos repetidos
        var desloc = 0
        if desloc_bruto > 3:
            desloc = desloc_bruto - 3
            est.rep[2] = est.rep[1]
            est.rep[1] = est.rep[0]
            est.rep[0] = desloc
        else:
            var idx = desloc_bruto
            if literal == 0:
                idx += 1
            if idx == 1:
                desloc = est.rep[0]
            elif idx == 2:
                desloc = est.rep[1]
                est.rep[1] = est.rep[0]
                est.rep[0] = desloc
            elif idx == 3:
                desloc = est.rep[2]
                est.rep[2] = est.rep[1]
                est.rep[1] = est.rep[0]
                est.rep[0] = desloc
            else:
                desloc = est.rep[0] - 1
                if desloc < 1:
                    raise Error("zstd: deslocamento repetido invalido")
                est.rep[2] = est.rep[1]
                est.rep[1] = est.rep[0]
                est.rep[0] = desloc

        # ---- executa: literais, depois o casamento
        if pl + literal > len(literais):
            raise Error("zstd: sequencia pede mais literais do que ha")
        for i in range(literal):
            saida.append(literais[pl + i])
        pl += literal

        if desloc <= 0 or desloc > len(saida):
            raise Error(
                "zstd: deslocamento " + String(desloc) + " alem do ja produzido"
            )
        var origem = len(saida) - desloc
        for i in range(casamento):
            saida.append(saida[origem + i])

        # ---- anda os estados: literal, casamento, deslocamento
        if s + 1 < n_seq:
            e_ll = Int(est.fse_ll.base[e_ll]) + bits.ler(Int(est.fse_ll.nbits[e_ll]))
            e_ml = Int(est.fse_ml.base[e_ml]) + bits.ler(Int(est.fse_ml.nbits[e_ml]))
            e_of = Int(est.fse_of.base[e_of]) + bits.ler(Int(est.fse_of.nbits[e_of]))

    # o que sobrou de literais vai inteiro no fim
    for i in range(pl, len(literais)):
        saida.append(literais[i])
