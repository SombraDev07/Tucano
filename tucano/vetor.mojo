"""Vetor — resultado de avaliar uma expressao sobre a tabela inteira (M3).

O executor e coluna-a-coluna: uma expressao nunca e avaliada linha a linha sobre
a `Tabela`. Ela vira um `Vetor` — um slab contiguo com mascara de ausentes — e
todas as operacoes seguintes leem esse slab.

M4: a mascara `na` e `List[UInt8]` (0 presente, 1 ausente), nao `List[Bool]`,
porque e sobre ela que os kernels SIMD operam — 32 elementos por instrucao no
AVX2.
"""

from .kernels import contar_marcados


struct Unidade:
    """O que os numeros do vetor significam.

    Sem isso o executor precisaria do esquema para saber se `ano(x)` recebeu
    dias ou microssegundos. O vetor carrega a informacao consigo.
    """

    comptime NUMERO = 0
    comptime DIAS = 1
    comptime MICROS = 2


struct Vetor(Copyable, Movable):
    """Coluna intermediaria: numerica (`reais`) ou textual (`textos`)."""

    var n: Int
    var eh_texto: Bool
    var unidade: Int
    var reais: List[Float64]
    var textos: List[String]
    var na: List[UInt8]

    def __init__(
        out self,
        n: Int,
        eh_texto: Bool,
        var reais: List[Float64],
        var textos: List[String],
        var na: List[UInt8],
        unidade: Int = Unidade.NUMERO,
    ):
        self.n = n
        self.eh_texto = eh_texto
        self.unidade = unidade
        self.reais = reais^
        self.textos = textos^
        self.na = na^

    @staticmethod
    def numerico(n: Int) -> Self:
        var reais = List[Float64](capacity=n)
        var na = List[UInt8](capacity=n)
        for _ in range(n):
            reais.append(0.0)
            na.append(UInt8(0))
        return Self(n, False, reais^, List[String](), na^)

    @staticmethod
    def textual(n: Int) -> Self:
        var textos = List[String](capacity=n)
        var na = List[UInt8](capacity=n)
        for _ in range(n):
            textos.append("")
            na.append(UInt8(0))
        return Self(n, True, List[Float64](), textos^, na^)

    @staticmethod
    def constante_numerica(n: Int, valor: Float64) -> Self:
        var v = Self.numerico(n)
        for i in range(n):
            v.reais[i] = valor
        return v^

    @staticmethod
    def constante_textual(n: Int, valor: String) -> Self:
        var v = Self.textual(n)
        for i in range(n):
            v.textos[i] = valor
        return v^

    def tamanho(self) -> Int:
        return self.n

    def eh_na(self, i: Int) -> Bool:
        return self.na[i] != 0

    def marcar_na(mut self, i: Int):
        self.na[i] = UInt8(1)

    def contar_ausentes(self) -> Int:
        return contar_marcados(self.na, self.n)
