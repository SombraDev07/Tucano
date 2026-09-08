"""Vetor — resultado de avaliar uma expressao sobre a tabela inteira (M3).

O executor do M3 e coluna-a-coluna: uma expressao nunca e avaliada linha a linha
sobre a `Tabela`. Ela vira um `Vetor` — um slab contiguo com mascara de ausentes
— e todas as operacoes seguintes leem esse slab.

E essa forma que o M4 substitui por kernels SIMD: o laco interno ja opera sobre
`List[Float64]` contiguo, sem tocar em `Tabela` nem em `Coluna`.
"""


struct Vetor(Copyable, Movable):
    """Coluna intermediaria: numerica (`reais`) ou textual (`textos`)."""

    var n: Int
    var eh_texto: Bool
    var reais: List[Float64]
    var textos: List[String]
    var na: List[Bool]

    def __init__(
        out self,
        n: Int,
        eh_texto: Bool,
        var reais: List[Float64],
        var textos: List[String],
        var na: List[Bool],
    ):
        self.n = n
        self.eh_texto = eh_texto
        self.reais = reais^
        self.textos = textos^
        self.na = na^

    @staticmethod
    def numerico(n: Int) -> Self:
        var reais = List[Float64](capacity=n)
        var na = List[Bool](capacity=n)
        for _ in range(n):
            reais.append(0.0)
            na.append(False)
        return Self(n, False, reais^, List[String](), na^)

    @staticmethod
    def textual(n: Int) -> Self:
        var textos = List[String](capacity=n)
        var na = List[Bool](capacity=n)
        for _ in range(n):
            textos.append("")
            na.append(False)
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

    def contar_ausentes(self) -> Int:
        var total = 0
        for i in range(self.n):
            if self.na[i]:
                total += 1
        return total
