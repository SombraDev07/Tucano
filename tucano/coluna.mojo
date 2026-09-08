from .dtype import DType
from .datas import parse_data_iso, data_para_texto
from .buffer import (
    Validity,
    StringStore,
    slab_int64,
    slab_float64,
    slab_bool_u8,
)


def _validar_ausentes(n: Int, ausentes: List[Bool]) raises:
    if len(ausentes) != 0 and len(ausentes) != n:
        raise Error("mascara de ausentes com tamanho diferente da coluna")


struct Coluna(Copyable, Movable):
    """Vetor nomeado tipado sobre storage columnar (M1).

    Layout:
      - validity: bitmap empacotado
      - ints/reals/logics: slab contiguidade (capacity == len)
      - textos: StringStore (offsets + bytes UTF-8)
    """

    var nome: String
    var tipo: Int
    var n: Int
    var validity_bits: Validity
    var ints: List[Int64]
    var reals: List[Float64]
    var logics: List[UInt8]
    var textos: StringStore

    @staticmethod
    def de_inteiros(
        nome: String, valores: List[Int64], ausentes: List[Bool] = List[Bool]()
    ) raises -> Self:
        var n = len(valores)
        _validar_ausentes(n, ausentes)
        var val = Validity.todos_presentes(n)
        if len(ausentes) != 0:
            val = Validity.de_lista(ausentes)
        return Self(
            nome,
            DType.INTEIRO,
            n,
            val^,
            slab_int64(valores),
            List[Float64](),
            List[UInt8](),
            StringStore.vazio(),
        )

    @staticmethod
    def de_reais(
        nome: String, valores: List[Float64], ausentes: List[Bool] = List[Bool]()
    ) raises -> Self:
        var n = len(valores)
        _validar_ausentes(n, ausentes)
        var val = Validity.todos_presentes(n)
        if len(ausentes) != 0:
            val = Validity.de_lista(ausentes)
        return Self(
            nome,
            DType.REAL,
            n,
            val^,
            List[Int64](),
            slab_float64(valores),
            List[UInt8](),
            StringStore.vazio(),
        )

    @staticmethod
    def de_logicos(
        nome: String, valores: List[Bool], ausentes: List[Bool] = List[Bool]()
    ) raises -> Self:
        var n = len(valores)
        _validar_ausentes(n, ausentes)
        var val = Validity.todos_presentes(n)
        if len(ausentes) != 0:
            val = Validity.de_lista(ausentes)
        return Self(
            nome,
            DType.LOGICO,
            n,
            val^,
            List[Int64](),
            List[Float64](),
            slab_bool_u8(valores),
            StringStore.vazio(),
        )

    @staticmethod
    def de_textos(
        nome: String, valores: List[String], ausentes: List[Bool] = List[Bool]()
    ) raises -> Self:
        var n = len(valores)
        _validar_ausentes(n, ausentes)
        var val = Validity.todos_presentes(n)
        if len(ausentes) != 0:
            val = Validity.de_lista(ausentes)
        return Self(
            nome,
            DType.TEXTO,
            n,
            val^,
            List[Int64](),
            List[Float64](),
            List[UInt8](),
            StringStore.de_valores(valores),
        )

    @staticmethod
    def de_datas(
        nome: String, dias: List[Int64], ausentes: List[Bool] = List[Bool]()
    ) raises -> Self:
        """Coluna de datas a partir de dias desde 1970-01-01."""
        var n = len(dias)
        _validar_ausentes(n, ausentes)
        var val = Validity.todos_presentes(n)
        if len(ausentes) != 0:
            val = Validity.de_lista(ausentes)
        return Self(
            nome,
            DType.DATA,
            n,
            val^,
            slab_int64(dias),
            List[Float64](),
            List[UInt8](),
            StringStore.vazio(),
        )

    @staticmethod
    def de_datas_texto(
        nome: String, valores: List[String], ausentes: List[Bool] = List[Bool]()
    ) raises -> Self:
        """Coluna de datas a partir de textos AAAA-MM-DD."""
        var n = len(valores)
        _validar_ausentes(n, ausentes)
        var dias = List[Int64](capacity=n)
        for i in range(n):
            if len(ausentes) != 0 and ausentes[i]:
                dias.append(Int64(0))
            else:
                dias.append(Int64(parse_data_iso(valores[i])))
        return Self.de_datas(nome, dias^, ausentes)

    def __init__(
        out self,
        nome: String,
        tipo: Int,
        n: Int,
        var validity_bits: Validity,
        var ints: List[Int64],
        var reals: List[Float64],
        var logics: List[UInt8],
        var textos: StringStore,
    ):
        self.nome = nome
        self.tipo = tipo
        self.n = n
        self.validity_bits = validity_bits^
        self.ints = ints^
        self.reals = reals^
        self.logics = logics^
        self.textos = textos^

    def tamanho(self) -> Int:
        return self.n

    def dtype(self) -> DType:
        return DType(self.tipo)

    def validity(self) -> Validity:
        return self.validity_bits.copy()

    def tipo_nome(self) raises -> String:
        return self.dtype().nome()

    def eh_ausente(self, i: Int) raises -> Bool:
        if i < 0 or i >= self.n:
            raise Error("indice fora da coluna: " + self.nome)
        return self.validity_bits.eh_ausente(i)

    def contar_ausentes(self) -> Int:
        return self.validity_bits.contar_ausentes()

    def contar_validos(self) -> Int:
        return self.validity_bits.contar_validos()

    def _exige_numerico(self) raises:
        if not self.dtype().eh_numerico():
            raise Error("operacao numerica exige coluna inteira ou real: " + self.nome)

    def _como_real(self, i: Int) raises -> Float64:
        if self.tipo == DType.INTEIRO or self.tipo == DType.DATA:
            return Float64(self.ints[i])
        if self.tipo == DType.REAL:
            return self.reals[i]
        raise Error("coluna nao numerica: " + self.nome)

    def dias_em(self, i: Int) raises -> Int:
        """Dias desde a epoch de uma coluna de data."""
        if self.tipo != DType.DATA:
            raise Error("coluna nao e de data: " + self.nome)
        if i < 0 or i >= self.n:
            raise Error("indice fora da coluna: " + self.nome)
        return Int(self.ints[i])

    def soma(self) raises -> Float64:
        self._exige_numerico()
        var total = Float64(0)
        for i in range(self.n):
            if not self.validity_bits.eh_ausente(i):
                total += self._como_real(i)
        return total

    def media(self) raises -> Float64:
        self._exige_numerico()
        var n_ok = self.contar_validos()
        if n_ok == 0:
            raise Error("coluna sem valores validos: " + self.nome)
        return self.soma() / Float64(n_ok)

    def minimo(self) raises -> Float64:
        self._exige_numerico()
        var achou = False
        var menor = Float64(0)
        for i in range(self.n):
            if self.validity_bits.eh_ausente(i):
                continue
            var valor = self._como_real(i)
            if not achou or valor < menor:
                menor = valor
                achou = True
        if not achou:
            raise Error("coluna sem valores validos: " + self.nome)
        return menor

    def maximo(self) raises -> Float64:
        self._exige_numerico()
        var achou = False
        var maior = Float64(0)
        for i in range(self.n):
            if self.validity_bits.eh_ausente(i):
                continue
            var valor = self._como_real(i)
            if not achou or valor > maior:
                maior = valor
                achou = True
        if not achou:
            raise Error("coluna sem valores validos: " + self.nome)
        return maior

    def maior_que(self, limiar: Float64) raises -> List[Bool]:
        self._exige_numerico()
        var mascara = List[Bool](capacity=self.n)
        for i in range(self.n):
            if self.validity_bits.eh_ausente(i):
                mascara.append(False)
            else:
                mascara.append(self._como_real(i) > limiar)
        return mascara^

    def texto_em(self, i: Int) raises -> String:
        if i < 0 or i >= self.n:
            raise Error("indice fora da coluna: " + self.nome)
        if self.validity_bits.eh_ausente(i):
            return "NA"
        if self.tipo == DType.INTEIRO:
            return String(self.ints[i])
        if self.tipo == DType.DATA:
            return data_para_texto(Int(self.ints[i]))
        if self.tipo == DType.REAL:
            return String(self.reals[i])
        if self.tipo == DType.LOGICO:
            if Int(self.logics[i]) != 0:
                return "True"
            return "False"
        return self.textos.get(i)

    def mostrar(self) raises:
        var partes = String()
        for i in range(self.n):
            if i > 0:
                partes += ", "
            partes += self.texto_em(i)
        print(
            self.nome,
            "(" + self.tipo_nome() + "):",
            "[" + partes + "]",
        )
