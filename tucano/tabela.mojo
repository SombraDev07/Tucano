"""Tabela e Consulta — a face eager e a face lazy da mesma abstracao (M3).

As duas vivem no mesmo modulo porque sao mutuamente recursivas: `Tabela.onde()`
devolve `Consulta` e `Consulta.coletar()` devolve `Tabela`. O Mojo aceita
recursao mutua dentro de um modulo, mas nao ciclo entre modulos.

**Ergonomia eager, execucao lazy.** `tabela.onde(...)` parece imediato mas devolve
um plano; `mostrar()`, `linhas()`, `soma()` e companhia materializam sozinhos.
`coletar()` continua existindo para quem quer o controle.

Abaixo das duas fica o executor, que **nao** conhece nenhuma delas: opera sobre
lotes de `Coluna`. Essa e a separacao logico/fisico do M3.
"""

from .coluna import Coluna
from .schema import Campo, Schema, Shape
from .dtype import DType
from .erros import erro_coluna
from .expr import Expr
from .plano import Etapa, TipoEtapa, descrever_logico, descrever_fisico
from .executor import executar, avisos_plano, esquema_apos, esquema_do_lote


# ---------------------------------------------------------------- Consulta



struct Consulta(Copyable, Movable):
    """Pipeline lazy sobre um lote de colunas.

    `onde` / `selecionar` / `com_coluna` so acrescentam etapas ao plano. A
    materializacao e automatica: `mostrar()`, `linhas()`, `soma()` e companhia
    executam. `coletar()` continua existindo para quem quer o controle explicito.
    """

    var fonte: List[Coluna]
    var etapas: List[Etapa]

    def __init__(out self, var fonte: List[Coluna]):
        self.fonte = fonte^
        self.etapas = List[Etapa]()

    @staticmethod
    def de(tab: Tabela) -> Self:
        return Self(tab.lote())

    # ------------------------------------------------------------ plano

    def onde(var self, var pred: Expr) -> Self:
        self.etapas.append(Etapa.filtro(pred^))
        return self^

    def selecionar(var self, nomes: List[String]) raises -> Self:
        if len(nomes) == 0:
            raise Error("selecionar exige pelo menos um nome")
        var copia = List[String]()
        for nome in nomes:
            copia.append(nome)
        self.etapas.append(Etapa.projecao(copia^))
        return self^

    def com_coluna(var self, nome: String, var expr: Expr) -> Self:
        """Coluna derivada. Substitui a coluna se o nome ja existir."""
        self.etapas.append(Etapa.com_coluna(nome, expr^))
        return self^

    # ---------------------------------------------------------- inspecao

    def descrever(self) raises -> String:
        """Plano logico: o que o usuario pediu."""
        return descrever_logico(self.etapas)

    def descrever_fisico(self) raises -> String:
        """Plano fisico, com avisos de caminho escalar."""
        var s = descrever_fisico(self.etapas)
        var notas = self.avisos()
        if len(notas) > 0:
            s += "\n\navisos:"
            for nota in notas:
                s += "\n  ! " + nota
        return s

    def avisos(self) raises -> List[String]:
        """Operacoes que ainda nao terao kernel vetorizado no M4."""
        return avisos_plano(self.fonte, self.etapas)

    def etapas_do_plano(self) -> Int:
        return len(self.etapas)

    def esquema_previsto(self) raises -> Schema:
        """Esquema do resultado **sem executar o plano**.

        O usual e so descobrir o tipo de uma coluna derivada depois de calcula-la.
        Aqui o planejador sabe antes — e e sobre isso que o otimizador do M8 vai
        raciocinar.
        """
        return Schema(esquema_apos(esquema_do_lote(self.fonte), self.etapas))

    # ----------------------------------------------------- materializacao

    def coletar(self) raises -> Tabela:
        """Executa o plano e devolve a Tabela."""
        return Tabela(executar(self.fonte, self.etapas))

    def mostrar(self) raises:
        self.coletar().mostrar()

    def primeiras(self, n: Int = 5) raises:
        self.coletar().primeiras(n)

    def linhas(self) raises -> Int:
        return self.coletar().linhas()

    def colunas(self) raises -> Int:
        return self.coletar().colunas()

    def shape(self) raises -> Shape:
        return self.coletar().shape()

    def schema(self) raises -> Schema:
        return self.coletar().schema()

    def nomes(self) raises -> List[String]:
        return self.coletar().nomes()

    def pegar(self, nome: String) raises -> Coluna:
        return self.coletar().pegar(nome)

    def soma(self, nome: String) raises -> Float64:
        return self.coletar().soma(nome)

    def media(self, nome: String) raises -> Float64:
        return self.coletar().media(nome)


def lazy(tab: Tabela) -> Consulta:
    """Entrada no pipeline lazy.

    Mantido por compatibilidade — prefira `tabela.onde(...)`, que ja devolve
    uma `Consulta`.
    """
    return Consulta.de(tab)


# ------------------------------------------------------------------ Tabela


struct Tabela(Copyable, Movable):
    """Tabela coluna-a-coluna tipada, Mojo puro.

    Storage columnar (M1). Execucao vetorizada (M3). Plano lazy: `lazy(tabela)`.

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

    def posicao(self, nome: String) raises -> Int:
        """Posicao de uma coluna pelo nome, com erro que sugere."""
        return self._posicao(nome)

    def lote(self) -> List[Coluna]:
        """Copia das colunas, no formato que o executor consome."""
        var out = List[Coluna]()
        for c in self._colunas:
            out.append(c.copy())
        return out^

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

    def onde(self, var pred: Expr) -> Consulta:
        """Filtra. Devolve uma `Consulta` lazy — o plano so executa ao exibir.

        A ergonomia e eager, a execucao e lazy: `mostrar()`, `linhas()` e
        `soma()` materializam sozinhos.
        """
        var q = Consulta(self.lote())
        return q^.onde(pred^)

    def selecionar_lazy(self, nomes: List[String]) raises -> Consulta:
        """Projecao lazy. `selecionar()` continua eager por compatibilidade."""
        var q = Consulta(self.lote())
        return q^.selecionar(nomes)

    def com_coluna(self, nome: String, var expr: Expr) -> Consulta:
        """Coluna derivada: atribui uma coluna calculada.

        Substitui a coluna se o nome ja existir. Devolve `Consulta`.
        """
        var q = Consulta(self.lote())
        return q^.com_coluna(nome, expr^)

    def consultar(self) -> Consulta:
        """Entra no pipeline lazy sem aplicar nenhuma etapa."""
        return Consulta(self.lote())

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
