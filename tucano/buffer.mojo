"""Memory Engine M1 — buffers columnars e validity bitmap.

Layout:
  Validity  → bitmap empacotado (1 bit/linha, 1 = NA)
  Numeric   → List tipada com capacity == len (slab contiguidade)
  String    → offsets[n+1] + bytes UTF-8 contiguidade

`List` aqui e o backing contiguidade do Mojo (nao lista de objetos).
A API publica nao expoe o layout interno alem de `unsafe` futuro (M4).
"""


def _bytes_para_bits(n: Int) -> Int:
    if n <= 0:
        return 0
    return (n + 7) // 8


struct Validity(Copyable, Movable):
    """Bitmap de ausentes: bit 1 = NA, bit 0 = presente."""

    var n: Int
    var bits: List[UInt8]

    def __init__(out self, n: Int, var bits: List[UInt8]):
        self.n = n
        self.bits = bits^

    @staticmethod
    def todos_presentes(n: Int) -> Self:
        var nb = _bytes_para_bits(n)
        var bits = List[UInt8](capacity=nb)
        for _ in range(nb):
            bits.append(UInt8(0))
        return Self(n, bits^)

    @staticmethod
    def de_lista(ausentes: List[Bool]) -> Self:
        var n = len(ausentes)
        var nb = _bytes_para_bits(n)
        var bits = List[UInt8](capacity=nb)
        for _ in range(nb):
            bits.append(UInt8(0))
        for i in range(n):
            if ausentes[i]:
                var byte_i = i // 8
                var bit_i = i % 8
                var atual = Int(bits[byte_i])
                bits[byte_i] = UInt8(atual | (1 << bit_i))
        return Self(n, bits^)

    def tamanho(self) -> Int:
        return self.n

    def eh_ausente(self, i: Int) raises -> Bool:
        if i < 0 or i >= self.n:
            raise Error("indice fora da mascara de validade")
        var byte_i = i // 8
        var bit_i = i % 8
        return ((Int(self.bits[byte_i]) >> bit_i) & 1) == 1

    def marcar_ausente(mut self, i: Int) raises:
        if i < 0 or i >= self.n:
            raise Error("indice fora da mascara de validade")
        var byte_i = i // 8
        var bit_i = i % 8
        var atual = Int(self.bits[byte_i])
        self.bits[byte_i] = UInt8(atual | (1 << bit_i))

    def contar_ausentes(self) -> Int:
        var total = 0
        for i in range(self.n):
            var byte_i = i // 8
            var bit_i = i % 8
            if ((Int(self.bits[byte_i]) >> bit_i) & 1) == 1:
                total += 1
        return total

    def contar_validos(self) -> Int:
        return self.n - self.contar_ausentes()

    def para_lista(self) raises -> List[Bool]:
        var saida = List[Bool](capacity=self.n)
        for i in range(self.n):
            saida.append(self.eh_ausente(i))
        return saida^

    def bytes_alocados(self) -> Int:
        return len(self.bits)


struct StringStore(Copyable, Movable):
    """Coluna de texto: offsets[n+1] + bytes UTF-8 contiguidade."""

    var offsets: List[Int]
    var bytes: List[UInt8]

    def __init__(out self, var offsets: List[Int], var bytes: List[UInt8]):
        self.offsets = offsets^
        self.bytes = bytes^

    @staticmethod
    def vazio() -> Self:
        var offsets = List[Int]()
        offsets.append(0)
        return Self(offsets^, List[UInt8]())

    @staticmethod
    def de_valores(valores: List[String]) -> Self:
        var n = len(valores)
        var offsets = List[Int](capacity=n + 1)
        var bytes = List[UInt8]()
        offsets.append(0)
        for s in valores:
            for b in s.as_bytes():
                bytes.append(b)
            offsets.append(len(bytes))
        return Self(offsets^, bytes^)

    def tamanho(self) -> Int:
        if len(self.offsets) == 0:
            return 0
        return len(self.offsets) - 1

    def get(self, i: Int) raises -> String:
        if i < 0 or i >= self.tamanho():
            raise Error("indice fora do StringStore")
        var start = self.offsets[i]
        var end = self.offsets[i + 1]
        if start == end:
            return ""
        return String(from_utf8=Span(self.bytes)[start:end])

    def bytes_dados(self) -> Int:
        return len(self.bytes)


def slab_int64(valores: List[Int64]) -> List[Int64]:
    """Copia para slab contiguidade com capacity == len."""
    var n = len(valores)
    var out = List[Int64](capacity=n)
    for v in valores:
        out.append(v)
    return out^


def slab_float64(valores: List[Float64]) -> List[Float64]:
    var n = len(valores)
    var out = List[Float64](capacity=n)
    for v in valores:
        out.append(v)
    return out^


def slab_bool_u8(valores: List[Bool]) -> List[UInt8]:
    var n = len(valores)
    var out = List[UInt8](capacity=n)
    for v in valores:
        if v:
            out.append(UInt8(1))
        else:
            out.append(UInt8(0))
    return out^
