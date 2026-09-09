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


struct SlabInteiro(Copyable, Movable, Sized):
    """Slab de inteiros que carrega a **propria largura** em bytes.

    Data cabe em 32 bits com folga — dias desde 1970 nao chegam a alguns milhoes
    — e inteiro e datahora precisam dos 64. Guardar a largura no slab, em vez de
    um `List` por largura, e o que evita um campo novo por tipo na `Coluna`:
    quem le decide pela largura **uma vez, fora do laco**.

    Ler por bitcast nao custa nada a mais que ler de um `List` tipado: somar
    vinte milhoes de inteiros mede 7 ms dos dois jeitos, com a largura decidida
    fora do laco. Foi essa medida que autorizou a forma.

    `bytes` fica publico de proposito: no caminho quente quem le faz
    `bytes.unsafe_ptr().unsafe_bitcast[Int64]()` e trabalha direto no slab.
    Devolver ponteiro de um metodo esbarraria na inferencia de origin, e
    esconder o buffer so para reexpo-lo por acessor nao esconde nada.
    """

    var bytes: List[UInt8]
    var largura: Int
    var n: Int

    def __init__(out self):
        self.bytes = List[UInt8]()
        self.largura = 8
        self.n = 0

    def __init__(out self, var bytes: List[UInt8], largura: Int, n: Int):
        self.bytes = bytes^
        self.largura = largura
        self.n = n

    @staticmethod
    def de_i64(var valores: List[Int64]) -> Self:
        """Assume a lista como slab de 64 bits, sem copiar os valores."""
        var n = len(valores)
        var b = List[UInt8](capacity=n * 8)
        b.resize(unsafe_uninit_length=n * 8)
        if n > 0:
            _ = external_call["memcpy", Int](
                b.unsafe_ptr(),
                valores.unsafe_ptr().unsafe_bitcast[UInt8](),
                n * 8,
            )
        return Self(b^, 8, n)

    @staticmethod
    def de_dias(valores: List[Int64]) raises -> Self:
        """Estreita para 32 bits. So para dias — o unico tipo que cabe.

        32 bits cobrem cerca de cinco milhoes de anos para cada lado da epoch,
        muito alem do que o calendario do Tucano representa. Ainda assim o valor
        e conferido: estreitar em silencio devolveria uma data errada, e data
        errada nao denuncia — parece uma data.
        """
        var n = len(valores)
        var b = List[UInt8](capacity=n * 4)
        b.resize(unsafe_uninit_length=n * 4)
        var destino = b.unsafe_ptr().unsafe_bitcast[Int32]()
        var origem = valores.unsafe_ptr()
        for i in range(n):
            var v = origem.unsafe_load(i)
            if v > Int64(2147483647) or v < Int64(-2147483648):
                raise Error(
                    "data fora da faixa de 32 bits: " + String(v) + " dias"
                )
            destino.unsafe_store(i, Int32(v))
        return Self(b^, 4, n)

    def __len__(self) -> Int:
        return self.n

    def __getitem__(self, i: Int) -> Int64:
        if self.largura == 4:
            return Int64(
                self.bytes.unsafe_ptr().unsafe_bitcast[Int32]().unsafe_load(i)
            )
        return self.bytes.unsafe_ptr().unsafe_bitcast[Int64]().unsafe_load(i)

    def para_lista(self) -> List[Int64]:
        """Copia para `List[Int64]`. So onde a copia ja existiria."""
        var out = List[Int64](capacity=self.n)
        out.resize(unsafe_uninit_length=self.n)
        if self.n == 0:
            return out^
        if self.largura == 8:
            _ = external_call["memcpy", Int](
                out.unsafe_ptr().unsafe_bitcast[UInt8](),
                self.bytes.unsafe_ptr(),
                self.n * 8,
            )
            return out^
        var origem = self.bytes.unsafe_ptr().unsafe_bitcast[Int32]()
        var destino = out.unsafe_ptr()
        for i in range(self.n):
            destino.unsafe_store(i, Int64(origem.unsafe_load(i)))
        return out^


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


def espalhar_chave(x: Int) -> Int:
    """Espalha os bits de uma chave para virar posicao numa tabela hash.

    Multiplicar por uma constante impar e o passo barato, mas ele concentra a
    entropia nos bits **altos** — e uma tabela de potencia de dois le os
    **baixos**. Com inteiro corrido isso passa despercebido; com valor que tem
    zeros no fim, nao:

    - o padrao de bits de um `Float64` pequeno (`2.5`, `1250.0`) tem dezenas de
      zeros no fim da mantissa;
    - um carimbo de tempo em microssegundos, gravado em segundos inteiros, e
      multiplo de um milhao — seis zeros binarios no fim.

    O produto herda esses zeros, e as chaves caem todas nos mesmos slots.
    Medido, meio milhao de linhas com 9973 valores distintos de `Float64`:

        so multiplicar   4975 sondagens por linha   1088 ms
        com esta mistura    1 sondagem por linha       2 ms

    Os dois `^ (z >> k)` trazem os bits altos para baixo, e o deslocamento tem
    de ser **logico** — dai as mascaras. Com `>>` puro um valor negativo enche
    de uns, que e o mesmo defeito que ja apareceu no varint e no zigzag.
    """
    var z = x * -7046029254386353131
    z = z ^ ((z >> 32) & 0xFFFFFFFF)
    z = z * -4658895280553007687
    z = z ^ ((z >> 29) & 0x7FFFFFFFF)
    return z & 0x7FFFFFFFFFFFFFFF
