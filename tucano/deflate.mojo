"""Inflate DEFLATE cru (RFC 1951) — o metodo 8 do ZIP.

Sem enquadramento zlib: o ZIP guarda o bloco cru, sem CMF/FLG nem Adler-32.
O decoder e o mesmo papel do Snappy no Parquet: um codec, nao um formato.
"""

comptime _MAXBITS = 15
comptime _MAXLCODES = 286
comptime _MAXDCODES = 32
comptime _FIXLCODES = 288


def _ordem_clen() -> List[Int]:
    var o = List[Int]()
    o.append(16)
    o.append(17)
    o.append(18)
    o.append(0)
    o.append(8)
    o.append(7)
    o.append(9)
    o.append(6)
    o.append(10)
    o.append(5)
    o.append(11)
    o.append(4)
    o.append(12)
    o.append(3)
    o.append(13)
    o.append(2)
    o.append(14)
    o.append(1)
    o.append(15)
    return o^


def _len_base() -> List[Int]:
    var v = List[Int]()
    v.append(3)
    v.append(4)
    v.append(5)
    v.append(6)
    v.append(7)
    v.append(8)
    v.append(9)
    v.append(10)
    v.append(11)
    v.append(13)
    v.append(15)
    v.append(17)
    v.append(19)
    v.append(23)
    v.append(27)
    v.append(31)
    v.append(35)
    v.append(43)
    v.append(51)
    v.append(59)
    v.append(67)
    v.append(83)
    v.append(99)
    v.append(115)
    v.append(131)
    v.append(163)
    v.append(195)
    v.append(227)
    v.append(258)
    return v^


def _len_extra() -> List[Int]:
    var v = List[Int]()
    for _ in range(8):
        v.append(0)
    for n in range(1, 6):
        for _ in range(4):
            v.append(n)
    v.append(0)
    return v^


def _dist_base() -> List[Int]:
    var v = List[Int]()
    v.append(1)
    v.append(2)
    v.append(3)
    v.append(4)
    v.append(5)
    v.append(7)
    v.append(9)
    v.append(13)
    v.append(17)
    v.append(25)
    v.append(33)
    v.append(49)
    v.append(65)
    v.append(97)
    v.append(129)
    v.append(193)
    v.append(257)
    v.append(385)
    v.append(513)
    v.append(769)
    v.append(1025)
    v.append(1537)
    v.append(2049)
    v.append(3073)
    v.append(4097)
    v.append(6145)
    v.append(8193)
    v.append(12289)
    v.append(16385)
    v.append(24577)
    return v^


def _dist_extra() -> List[Int]:
    var v = List[Int]()
    for _ in range(4):
        v.append(0)
    for n in range(1, 14):
        v.append(n)
        v.append(n)
    return v^


struct _Bits(Movable):
    var dados: List[UInt8]
    var pos: Int
    var buf: Int
    var nbuf: Int

    def __init__(out self, var dados: List[UInt8]):
        self.dados = dados^
        self.pos = 0
        self.buf = 0
        self.nbuf = 0

    def bits(mut self, n: Int) raises -> Int:
        """Le `n` bits, menos significativo primeiro."""
        var val = self.buf
        while self.nbuf < n:
            if self.pos >= len(self.dados):
                raise Error("deflate: entrada truncada")
            val |= Int(self.dados[self.pos]) << self.nbuf
            self.pos += 1
            self.nbuf += 8
        var mascara = (1 << n) - 1
        var out = val & mascara
        self.buf = val >> n
        self.nbuf -= n
        return out

    def alinhar(mut self):
        self.buf = 0
        self.nbuf = 0


struct _Huffman(Copyable, Movable):
    """Arvore canonica: `count[len]` simbolos de comprimento `len`."""

    var count: List[Int]
    var symbol: List[Int]

    def __init__(out self, nsimbolos: Int):
        self.count = List[Int]()
        for _ in range(_MAXBITS + 1):
            self.count.append(0)
        self.symbol = List[Int]()
        for _ in range(nsimbolos):
            self.symbol.append(0)


def _construir(mut h: _Huffman, comprimentos: List[Int], n: Int) raises:
    """Monta a arvore a partir dos comprimentos. Erra se estiver superlotada."""
    for i in range(_MAXBITS + 1):
        h.count[i] = 0
    for s in range(n):
        var L = comprimentos[s]
        if L < 0 or L > _MAXBITS:
            raise Error("deflate: comprimento de codigo invalido")
        h.count[L] += 1

    if h.count[0] == n:
        return

    var left = 1
    for bits in range(1, _MAXBITS + 1):
        left <<= 1
        left -= h.count[bits]
        if left < 0:
            raise Error("deflate: arvore Huffman superlotada")

    var offs = List[Int]()
    for _ in range(_MAXBITS + 1):
        offs.append(0)
    for bits in range(1, _MAXBITS):
        offs[bits + 1] = offs[bits] + h.count[bits]

    for s in range(n):
        var L = comprimentos[s]
        if L != 0:
            h.symbol[offs[L]] = s
            offs[L] += 1


def _decodificar(mut b: _Bits, h: _Huffman) raises -> Int:
    var code = 0
    var first = 0
    var index = 0
    for bits in range(1, _MAXBITS + 1):
        code |= b.bits(1)
        var count = h.count[bits]
        if code - count < first:
            return h.symbol[index + (code - first)]
        index += count
        first += count
        first <<= 1
        code <<= 1
    raise Error("deflate: codigo Huffman invalido")


def _lit_fixos() -> List[Int]:
    var lit = List[Int]()
    for _ in range(_FIXLCODES):
        lit.append(0)
    for s in range(144):
        lit[s] = 8
    for s in range(144, 256):
        lit[s] = 9
    for s in range(256, 280):
        lit[s] = 7
    for s in range(280, _FIXLCODES):
        lit[s] = 8
    return lit^


def _dist_fixos() -> List[Int]:
    var dist = List[Int]()
    for _ in range(_MAXDCODES):
        dist.append(5)
    return dist^


def _copiar(mut out: List[UInt8], distancia: Int, comprimento: Int) raises:
    var n = len(out)
    if distancia <= 0 or distancia > n:
        raise Error("deflate: distancia de copia invalida")
    var origem = n - distancia
    for i in range(comprimento):
        out.append(out[origem + i])


def _bloco_codigos(
    mut b: _Bits,
    mut out: List[UInt8],
    lit: _Huffman,
    dist: _Huffman,
    len_base: List[Int],
    len_extra: List[Int],
    dist_base: List[Int],
    dist_extra: List[Int],
) raises:
    while True:
        var s = _decodificar(b, lit)
        if s == 256:
            return
        if s < 256:
            out.append(UInt8(s))
            continue
        if s > 285:
            raise Error("deflate: simbolo de comprimento invalido")
        var i = s - 257
        var n = len_base[i]
        var extra = len_extra[i]
        if extra > 0:
            n += b.bits(extra)
        var dsim = _decodificar(b, dist)
        if dsim < 0 or dsim > 29:
            raise Error("deflate: distancia invalida")
        var d = dist_base[dsim]
        extra = dist_extra[dsim]
        if extra > 0:
            d += b.bits(extra)
        _copiar(out, d, n)


def _bloco_armazenado(mut b: _Bits, mut out: List[UInt8]) raises:
    b.alinhar()
    var nlen = b.bits(16)
    var nlen_comp = b.bits(16)
    if nlen != ((~nlen_comp) & 0xFFFF):
        raise Error("deflate: bloco armazenado com NLEN invalido")
    for _ in range(nlen):
        if b.pos >= len(b.dados):
            raise Error("deflate: entrada truncada")
        out.append(b.dados[b.pos])
        b.pos += 1


def inflar(var dados: List[UInt8]) raises -> List[UInt8]:
    """DEFLATE cru -> bytes. O ZIP chama isto no metodo 8."""
    var b = _Bits(dados^)
    var out = List[UInt8]()
    var ordem = _ordem_clen()
    var len_base = _len_base()
    var len_extra = _len_extra()
    var dist_base = _dist_base()
    var dist_extra = _dist_extra()
    while True:
        var ultimo = b.bits(1)
        var tipo = b.bits(2)
        if tipo == 0:
            _bloco_armazenado(b, out)
        elif tipo == 1:
            var lit = _Huffman(_FIXLCODES)
            var dist = _Huffman(_MAXDCODES)
            _construir(lit, _lit_fixos(), _FIXLCODES)
            _construir(dist, _dist_fixos(), _MAXDCODES)
            _bloco_codigos(
                b, out, lit, dist, len_base, len_extra, dist_base, dist_extra
            )
        elif tipo == 2:
            var hlit = b.bits(5) + 257
            var hdist = b.bits(5) + 1
            var hclen = b.bits(4) + 4
            if hlit > _MAXLCODES or hdist > _MAXDCODES:
                raise Error("deflate: tabela dinamica grande demais")

            var clen = List[Int]()
            for _ in range(19):
                clen.append(0)
            for i in range(hclen):
                clen[ordem[i]] = b.bits(3)

            var hcl = _Huffman(19)
            _construir(hcl, clen, 19)

            var ntot = hlit + hdist
            var lens = List[Int]()
            for _ in range(ntot):
                lens.append(0)
            var i = 0
            while i < ntot:
                var s = _decodificar(b, hcl)
                if s < 16:
                    lens[i] = s
                    i += 1
                    continue
                if s == 16:
                    if i == 0:
                        raise Error("deflate: repeticao sem codigo anterior")
                    var val16 = lens[i - 1]
                    var rep16 = 3 + b.bits(2)
                    if i + rep16 > ntot:
                        raise Error("deflate: repeticao ultrapassa a tabela")
                    for _ in range(rep16):
                        lens[i] = val16
                        i += 1
                elif s == 17:
                    var rep17 = 3 + b.bits(3)
                    if i + rep17 > ntot:
                        raise Error("deflate: repeticao ultrapassa a tabela")
                    for _ in range(rep17):
                        lens[i] = 0
                        i += 1
                else:
                    var rep18 = 11 + b.bits(7)
                    if i + rep18 > ntot:
                        raise Error("deflate: repeticao ultrapassa a tabela")
                    for _ in range(rep18):
                        lens[i] = 0
                        i += 1

            var lit_len = List[Int]()
            for j in range(hlit):
                lit_len.append(lens[j])
            var dist_len = List[Int]()
            for j in range(hdist):
                dist_len.append(lens[hlit + j])

            var lit = _Huffman(_MAXLCODES)
            var dist = _Huffman(_MAXDCODES)
            _construir(lit, lit_len, hlit)
            _construir(dist, dist_len, hdist)
            _bloco_codigos(
                b, out, lit, dist, len_base, len_extra, dist_base, dist_extra
            )
        else:
            raise Error("deflate: tipo de bloco invalido")
        if ultimo != 0:
            break
    return out^
