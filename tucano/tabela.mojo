from .coluna import Coluna
from .schema import Campo, Schema, Shape
from .dtype import DType
from .erros import erro_coluna


struct Tabela(Copyable, Movable):
    """Tabela coluna-a-coluna tipada, Mojo puro.

    Storage columnar (M1). Pipeline lazy: `Consulta.de(tabela)` (M2).

    Nao existe index de rotulo (Decisao 1 do CONTRATO): a contagem de linhas vem
    das proprias colunas, nunca de um campo paralelo que possa divergir. Duas
    tabelas so se combinam por join explicito.
    """

    var _colunas: List[Coluna]

    def __init__(out self, colunas: List[Coluna]) raises:
        if len(colunas) == 0:
            raise Error("tabela precisa de pelo menos uma coluna")
        var n = colunas[0].tamanho()
        var nomes_vistos = List[String]()
        var copia = List[Coluna]()
        for c in colunas:
            if c.tamanho() != n:
                raise Error("todas as colunas precisam ter o mesmo tamanho")
            for nome in nomes_vistos:
                if nome == c.nome:
                    raise Error("nome de coluna duplicado: " + c.nome)
            nomes_vistos.append(c.nome)
            copia.append(c.copy())
        self._colunas = copia^

    def linhas(self) -> Int:
        return self._colunas[0].tamanho()

    def colunas(self) -> Int:
        return len(self._colunas)

    def shape(self) -> Shape:
        return Shape(self.linhas(), self.colunas())

    def schema(self) raises -> Schema:
        var campos = List[Campo]()
        for c in self._colunas:
            campos.append(Campo(c.nome, c.dtype()))
        return Schema(campos^)

    def nomes(self) raises -> List[String]:
        return self.schema().nomes()

    def _posicao(self, nome: String) raises -> Int:
        for i in range(len(self._colunas)):
            if self._colunas[i].nome == nome:
                return i
        raise erro_coluna(nome, self.nomes())

    def pegar(self, nome: String) raises -> Coluna:
        return self._colunas[self._posicao(nome)].copy()

    def dtype_de(self, nome: String) raises -> DType:
        """Tipo de uma coluna sem copiar a coluna."""
        return self._colunas[self._posicao(nome)].dtype()

    def eh_ausente(self, nome: String, i: Int) raises -> Bool:
        """Consulta de validade sem copiar a coluna."""
        return self._colunas[self._posicao(nome)].eh_ausente(i)

    def adicionar(self, coluna: Coluna) raises -> Self:
        if coluna.tamanho() != self.linhas():
            raise Error("coluna nova deve ter o mesmo numero de linhas")
        for c in self._colunas:
            if c.nome == coluna.nome:
                raise Error("coluna ja existe: " + coluna.nome)
        var cols = List[Coluna]()
        for c in self._colunas:
            cols.append(c.copy())
        cols.append(coluna.copy())
        return Self(cols^)

    def remover(self, nome: String) raises -> Self:
        if self.colunas() == 1:
            raise Error("nao e possivel remover a unica coluna")
        var cols = List[Coluna]()
        var achou = False
        for c in self._colunas:
            if c.nome == nome:
                achou = True
                continue
            cols.append(c.copy())
        if not achou:
            raise erro_coluna(nome, self.nomes())
        return Self(cols^)

    def selecionar(self, nomes: List[String]) raises -> Self:
        if len(nomes) == 0:
            raise Error("selecionar exige pelo menos um nome")
        var escolhidas = List[Coluna]()
        for nome in nomes:
            escolhidas.append(self.pegar(nome))
        return Self(escolhidas^)

    def media(self, nome: String) raises -> Float64:
        return self.pegar(nome).media()

    def soma(self, nome: String) raises -> Float64:
        return self.pegar(nome).soma()

    def primeiras(self, n: Int = 5) raises:
        var limite = n
        if limite > self.linhas():
            limite = self.linhas()
        var cabecalho = String("#")
        for c in self._colunas:
            cabecalho += "\t" + c.nome
        print(cabecalho)
        for linha in range(limite):
            var texto = String(linha)
            for c in self._colunas:
                texto += "\t" + c.texto_em(linha)
            print(texto)

    def mostrar(self) raises:
        var s = self.shape()
        print("Tabela", s.linhas, "x", s.colunas)
        self.primeiras(self.linhas())
