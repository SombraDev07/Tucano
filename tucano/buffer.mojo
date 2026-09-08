"""Memory Engine M1 — buffers columnars e validity bitmap.

Layout:
  Validity  → bitmap empacotado (1 bit/linha, 1 = NA)
  Numeric   → List tipada com capacity == len (slab contiguidade)
  String    → offsets[n+1] + bytes UTF-8 contiguidade

`List` aqui e o backing contiguidade do Mojo (nao lista de objetos).
A API publica nao expoe o layout interno alem de `unsafe` futuro (M4).
"""

from std.ffi import external_call


def _bytes_para_bits(n: Int) -> Int:
    if n <= 0:
        return 0
    return (n + 7) // 8


struct Validity(Copyable, Movable):
    """Bitmap de ausentes: bit 1 = NA, bit 0 = presente."""

    var n: Int
    var bits: List[UInt8]
    var n_ausentes: Int
    """Contagem mantida na construcao: `contar_ausentes()` e O(1).

    Sem isso, todo kernel que quer saber "esta coluna tem ausente?" paga uma
    varredura antes de comecar — e no caso comum (nenhum ausente) essa varredura
    custa mais que a reducao inteira.
    """

    def __init__(out self, n: Int, var bits: List[UInt8], n_ausentes: Int = -1):
        self.n = n
        self.bits = bits^
        if n_ausentes >= 0:
            self.n_ausentes = n_ausentes
        else:
            self.n_ausentes = 0
            for i in range(self.n):
                if ((Int(self.bits[i // 8]) >> (i % 8)) & 1) == 1:
                    self.n_ausentes += 1

    @staticmethod
    def todos_presentes(n: Int) -> Self:
        var nb = _bytes_para_bits(n)
        var bits = List[UInt8](capacity=nb)
        for _ in range(nb):
            bits.append(UInt8(0))
        return Self(n, bits^, 0)

    @staticmethod
    def de_lista(ausentes: List[Bool]) -> Self:
        """Empacota a lista de ausentes na mascara de bits.

        Percorre de oito em oito e monta o byte inteiro antes de escrever: o
        laco anterior lia e reescrevia o mesmo byte oito vezes, uma por bit. Na
        pratica quase toda coluna chega sem nenhum ausente, e ai o byte sai zero
        sem nenhuma escrita — por isso o caso de todos presentes tambem sai
        barato, sem precisar de um caminho proprio.
        """
        var n = len(ausentes)
        var nb = _bytes_para_bits(n)
        var bits = List[UInt8]()
        bits.resize(nb, UInt8(0))
        var total = 0
        var origem = ausentes.unsafe_ptr()
        var destino = bits.unsafe_ptr()
        var completos = n // 8
        for b in range(completos):
            var base = b * 8
            var acumulado = 0
            for k in range(8):
                if origem[unsafe_offset=base + k]:
                    acumulado |= 1 << k
                    total += 1
            if acumulado != 0:
                destino.unsafe_store(b, UInt8(acumulado))
        var acumulado = 0
        for i in range(completos * 8, n):
            if origem[unsafe_offset=i]:
                acumulado |= 1 << (i % 8)
                total += 1
        if acumulado != 0:
            destino.unsafe_store(completos, UInt8(acumulado))
        return Self(n, bits^, total)

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
        if ((atual >> bit_i) & 1) == 0:
            self.n_ausentes += 1
        self.bits[byte_i] = UInt8(atual | (1 << bit_i))

    def contar_ausentes(self) -> Int:
        return self.n_ausentes

    def tem_ausentes(self) -> Bool:
        return self.n_ausentes > 0

    def contar_validos(self) -> Int:
        return self.n - self.contar_ausentes()

    def para_bytes(self) -> List[UInt8]:
        """Desempacota o bitmap para um byte por linha (0 presente, 1 ausente).

        Os kernels SIMD do M4 operam sobre bytes: extrair bit a bit dentro do
        laco de dados custa mais do que desempacotar uma vez.
        """
        var out = List[UInt8](capacity=self.n)
        if self.n_ausentes == 0:
            for _ in range(self.n):
                out.append(UInt8(0))
            return out^
        var i = 0
        while i < self.n:
            var byte = Int(self.bits[i // 8])
            var restantes = self.n - i
            var ate = 8
            if restantes < 8:
                ate = restantes
            for b in range(ate):
                out.append(UInt8((byte >> b) & 1))
            i += ate
        return out^

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


def slab_int64(var valores: List[Int64]) -> List[Int64]:
    """Assume a lista como slab da coluna.

    Um `List` do Mojo **ja e** um slab contiguo — nao ha layout a converter.
    Esta funcao existia para copiar mesmo assim, garantindo `capacity == len`;
    o que a coluna precisa de verdade e contiguidade, e isso o `List` da de
    graca. A copia custava tocar 40 MiB de paginas novas por coluna de 5
    milhoes, so para chegar aos mesmos bytes.

    Continua sendo o unico ponto por onde valores viram slab: o nome marca a
    fronteira, mesmo quando a fronteira nao custa nada.
    """
    return valores^


def slab_float64(var valores: List[Float64]) -> List[Float64]:
    return valores^


def slab_bool_u8(valores: List[Bool]) -> List[UInt8]:
    var n = len(valores)
    var out = List[UInt8](capacity=n)
    for v in valores:
        if v:
            out.append(UInt8(1))
        else:
            out.append(UInt8(0))
    return out^
