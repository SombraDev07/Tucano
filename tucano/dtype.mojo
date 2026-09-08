"""DType — tipo lógico de coluna do Tucano (M0)."""


@fieldwise_init
struct DType(Copyable, Movable, Equatable, ImplicitlyCopyable):
    """Identificador de tipo de coluna.

    Códigos estáveis da API pública. Em M1 o storage muda; estes códigos
    permanecem.
    """

    var codigo: Int

    comptime INTEIRO = 0
    comptime REAL = 1
    comptime LOGICO = 2
    comptime TEXTO = 3
    comptime DATA = 4

    @staticmethod
    def inteiro() -> Self:
        return Self(Self.INTEIRO)

    @staticmethod
    def real() -> Self:
        return Self(Self.REAL)

    @staticmethod
    def logico() -> Self:
        return Self(Self.LOGICO)

    @staticmethod
    def texto() -> Self:
        return Self(Self.TEXTO)

    @staticmethod
    def data() -> Self:
        return Self(Self.DATA)

    def nome(self) raises -> String:
        if self.codigo == Self.INTEIRO:
            return "inteiro"
        if self.codigo == Self.REAL:
            return "real"
        if self.codigo == Self.LOGICO:
            return "logico"
        if self.codigo == Self.TEXTO:
            return "texto"
        if self.codigo == Self.DATA:
            return "data"
        raise Error("dtype desconhecido: " + String(self.codigo))

    def eh_numerico(self) -> Bool:
        """Data nao e numerica: `soma` de datas nao faz sentido."""
        return self.codigo == Self.INTEIRO or self.codigo == Self.REAL

    def eh_temporal(self) -> Bool:
        return self.codigo == Self.DATA
