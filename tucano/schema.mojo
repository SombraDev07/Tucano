"""Schema e Shape — contrato de metadados da Tabela (M0)."""

from .dtype import DType


@fieldwise_init
struct Campo(Copyable, Movable):
    """Uma coluna no schema: nome + dtype."""

    var nome: String
    var dtype: DType


@fieldwise_init
struct Shape(Copyable, Movable, Equatable, ImplicitlyCopyable):
    """Dimensões (linhas, colunas)."""

    var linhas: Int
    var colunas: Int


struct Schema(Copyable, Movable):
    """Lista ordenada de campos da tabela."""

    var campos: List[Campo]

    def __init__(out self, campos: List[Campo]) raises:
        var vistos = List[String]()
        var copia = List[Campo]()
        for c in campos:
            for nome in vistos:
                if nome == c.nome:
                    raise Error("schema com nome duplicado: " + c.nome)
            vistos.append(c.nome)
            copia.append(c.copy())
        self.campos = copia^

    def tamanho(self) -> Int:
        return len(self.campos)

    def nomes(self) -> List[String]:
        var saida = List[String]()
        for c in self.campos:
            saida.append(c.nome)
        return saida^

    def contem(self, nome: String) -> Bool:
        for c in self.campos:
            if c.nome == nome:
                return True
        return False

    def dtype_de(self, nome: String) raises -> DType:
        for c in self.campos:
            if c.nome == nome:
                return c.dtype
        raise Error("campo inexistente no schema: " + nome)

    def campo_em(self, i: Int) raises -> Campo:
        if i < 0 or i >= self.tamanho():
            raise Error("indice de schema fora do intervalo")
        return self.campos[i].copy()
