from .dtype import DType
from .datas import (
    parse_data_iso,
    data_para_texto,
    parse_datahora_iso,
    datahora_para_texto,
)
from std.collections import Dict
from .kernels import (
    soma_f64,
    soma_i64,
    soma_f64_densa,
    soma_i64_densa,
    minimo_f64_densa,
    maximo_f64_densa,
    minimo_f64,
    maximo_f64,
    minimo_i64,
    maximo_i64,
)
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
      - codigos: Int32 por linha quando a coluna e dicionarizada (M4)

    Dictionary encoding: quando ha repeticao, `textos` guarda so os valores
    distintos e `codigos` guarda um Int32 por linha. E o que transforma
    `cidade == "SP"` em comparacao de inteiros, vetorizavel. A alternativa
    consagrada e comparar ponteiros de objeto, um por vez.
    """

    var nome: String
    var tipo: Int
    var n: Int
    var validity_bits: Validity
    var ints: List[Int64]
    var reals: List[Float64]
    var logics: List[UInt8]
    var textos: StringStore
    var codigos: List[Int32]

    @staticmethod
    def de_inteiros(
        nome: String, var valores: List[Int64], ausentes: List[Bool] = List[Bool]()
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
            slab_int64(valores^),
            List[Float64](),
            List[UInt8](),
            StringStore.vazio(),
            List[Int32](),
        )

    @staticmethod
    def de_reais(
        nome: String, var valores: List[Float64], ausentes: List[Bool] = List[Bool]()
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
            slab_float64(valores^),
            List[UInt8](),
            StringStore.vazio(),
            List[Int32](),
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
            List[Int32](),
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
        # dicionariza quando ha repeticao: valores distintos + codigo por linha
        var mapa = Dict[String, Int32]()
        var distintos = List[String]()
        var codigos = List[Int32](capacity=n)
        for i in range(n):
            var v = valores[i]
            if v in mapa:
                codigos.append(mapa[v])
            else:
                var code = Int32(len(distintos))
                mapa[v] = code
                distintos.append(v)
                codigos.append(code)

        if len(distintos) < n and len(distintos) <= 65535:
            return Self(
                nome,
                DType.TEXTO,
                n,
                val^,
                List[Int64](),
                List[Float64](),
                List[UInt8](),
                StringStore.de_valores(distintos),
                codigos^,
            )
        return Self(
            nome,
            DType.TEXTO,
            n,
            val^,
            List[Int64](),
            List[Float64](),
            List[UInt8](),
            StringStore.de_valores(valores),
            List[Int32](),
        )

    @staticmethod
    def de_datas(
        nome: String, var dias: List[Int64], ausentes: List[Bool] = List[Bool]()
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
            slab_int64(dias^),
            List[Float64](),
            List[UInt8](),
            StringStore.vazio(),
            List[Int32](),
        )

    @staticmethod
    def de_datahoras(
        nome: String, var micros: List[Int64], ausentes: List[Bool] = List[Bool]()
    ) raises -> Self:
        """Coluna de datahora a partir de microssegundos desde a epoch."""
        var n = len(micros)
        _validar_ausentes(n, ausentes)
        var val = Validity.todos_presentes(n)
        if len(ausentes) != 0:
            val = Validity.de_lista(ausentes)
        return Self(
            nome,
            DType.DATAHORA,
            n,
            val^,
            slab_int64(micros^),
            List[Float64](),
            List[UInt8](),
            StringStore.vazio(),
            List[Int32](),
        )

    @staticmethod
    def de_datahoras_texto(
        nome: String, valores: List[String], ausentes: List[Bool] = List[Bool]()
    ) raises -> Self:
        """Coluna de datahora a partir de textos ISO-8601."""
        var n = len(valores)
        _validar_ausentes(n, ausentes)
        var micros = List[Int64](capacity=n)
        for i in range(n):
            if len(ausentes) != 0 and ausentes[i]:
                micros.append(Int64(0))
            else:
                micros.append(Int64(parse_datahora_iso(valores[i])))
        return Self.de_datahoras(nome, micros^, ausentes)

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
        var codigos: List[Int32],
    ):
        self.nome = nome
        self.tipo = tipo
        self.n = n
        self.validity_bits = validity_bits^
        self.ints = ints^
        self.reals = reals^
        self.logics = logics^
        self.textos = textos^
        self.codigos = codigos^

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
        if (
            self.tipo == DType.INTEIRO
            or self.tipo == DType.DATA
            or self.tipo == DType.DATAHORA
        ):
            return Float64(self.ints[i])
        if self.tipo == DType.REAL:
            return self.reals[i]
        raise Error("coluna nao numerica: " + self.nome)

    def micros_em(self, i: Int) raises -> Int:
        """Microssegundos desde a epoch de uma coluna de datahora."""
        if self.tipo != DType.DATAHORA:
            raise Error("coluna nao e de datahora: " + self.nome)
        if i < 0 or i >= self.n:
            raise Error("indice fora da coluna: " + self.nome)
        return Int(self.ints[i])

    def dias_em(self, i: Int) raises -> Int:
        """Dias desde a epoch de uma coluna de data."""
        if self.tipo != DType.DATA:
            raise Error("coluna nao e de data: " + self.nome)
        if i < 0 or i >= self.n:
            raise Error("indice fora da coluna: " + self.nome)
        return Int(self.ints[i])

    def soma(self) raises -> Float64:
        """Soma ignorando ausentes, por kernel SIMD.

        Coluna sem nenhum valor valido levanta erro em vez de devolver zero:
        somar nada nao da zero, da desconhecido. E a mesma regra que `agrupar`
        aplica a um grupo inteiramente ausente, que sai como NA.
        """
        self._exige_numerico()
        if self.contar_validos() == 0:
            raise Error("coluna sem valores validos: " + self.nome)
        if not self.validity_bits.tem_ausentes():
            if self.tipo == DType.INTEIRO:
                return soma_i64_densa(self.ints, self.n)
            return soma_f64_densa(self.reals, self.n)
        var na = self.validity_bits.para_bytes()
        if self.tipo == DType.INTEIRO:
            return soma_i64(self.ints, na, self.n)
        return soma_f64(self.reals, na, self.n)

    def media(self) raises -> Float64:
        self._exige_numerico()
        var n_ok = self.contar_validos()
        if n_ok == 0:
            raise Error("coluna sem valores validos: " + self.nome)
        return self.soma() / Float64(n_ok)

    def minimo(self) raises -> Float64:
        self._exige_numerico()
        try:
            if not self.validity_bits.tem_ausentes() and self.tipo == DType.REAL:
                return minimo_f64_densa(self.reals, self.n)
            var na = self.validity_bits.para_bytes()
            if self.tipo == DType.INTEIRO:
                return minimo_i64(self.ints, na, self.n)
            return minimo_f64(self.reals, na, self.n)
        except:
            raise Error("coluna sem valores validos: " + self.nome)

    def maximo(self) raises -> Float64:
        self._exige_numerico()
        try:
            if not self.validity_bits.tem_ausentes() and self.tipo == DType.REAL:
                return maximo_f64_densa(self.reals, self.n)
            var na = self.validity_bits.para_bytes()
            if self.tipo == DType.INTEIRO:
                return maximo_i64(self.ints, na, self.n)
            return maximo_f64(self.reals, na, self.n)
        except:
            raise Error("coluna sem valores validos: " + self.nome)

    def maior_que(self, limiar: Float64) raises -> List[Bool]:
        self._exige_numerico()
        var mascara = List[Bool](capacity=self.n)
        for i in range(self.n):
            if self.validity_bits.eh_ausente(i):
                mascara.append(False)
            else:
                mascara.append(self._como_real(i) > limiar)
        return mascara^

    @staticmethod
    def de_dicionario(
        nome: String,
        var dicionario: StringStore,
        var codigos: List[Int32],
        var ausentes: List[Bool],
    ) raises -> Self:
        """Coluna de texto reaproveitando um dicionario ja construido.

        Filtrar, ordenar ou reamostrar uma coluna dicionarizada nao precisa
        redescobrir os valores distintos: os codigos e o dicionario sobrevivem.
        Reconstruir do zero era o custo dominante em tabela grande.
        """
        var n = len(codigos)
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
            dicionario^,
            codigos^,
        )

    def eh_dicionarizada(self) -> Bool:
        return len(self.codigos) > 0

    def cardinalidade(self) -> Int:
        """Numero de valores distintos, se dicionarizada."""
        if self.eh_dicionarizada():
            return self.textos.tamanho()
        return self.n

    def codigo_de(self, valor: String) raises -> Int32:
        """Codigo do valor no dicionario, ou -1 se ausente dele.

        Custa uma varredura sobre os DISTINTOS — uma vez por consulta, nao por
        linha. Depois disso o filtro e comparacao de Int32.
        """
        if not self.eh_dicionarizada():
            raise Error("coluna nao dicionarizada: " + self.nome)
        for i in range(self.textos.tamanho()):
            if self.textos.get(i) == valor:
                return Int32(i)
        return Int32(-1)

    def texto_bruto(self, i: Int) raises -> String:
        """Texto armazenado, sem substituir ausente por "NA"."""
        if self.tipo != DType.TEXTO:
            raise Error("coluna nao e de texto: " + self.nome)
        if self.eh_dicionarizada():
            return self.textos.get(Int(self.codigos[i]))
        return self.textos.get(i)

    def texto_em(self, i: Int) raises -> String:
        if i < 0 or i >= self.n:
            raise Error("indice fora da coluna: " + self.nome)
        if self.validity_bits.eh_ausente(i):
            return "NA"
        if self.tipo == DType.INTEIRO:
            return String(self.ints[i])
        if self.tipo == DType.DATA:
            return data_para_texto(Int(self.ints[i]))
        if self.tipo == DType.DATAHORA:
            return datahora_para_texto(Int(self.ints[i]))
        if self.tipo == DType.REAL:
            return String(self.reals[i])
        if self.tipo == DType.LOGICO:
            if Int(self.logics[i]) != 0:
                return "True"
            return "False"
        return self.texto_bruto(i)

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
