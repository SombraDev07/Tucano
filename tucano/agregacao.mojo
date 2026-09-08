"""Agregacoes (M6).

Uma agregacao e um valor declarativo, nao uma funcao a ser chamada linha a
linha: diz *o que* calcular e sobre qual coluna, e o executor escolhe *como*.

    tabela.agrupar(["cidade"]).agregar([soma("valor"), media("idade"), contar()])

Ha um jeito so de agregar. Sem `apply` que devolve qualquer coisa, sem retorno
cuja forma depende do que a funcao fez — o tipo de saida e conhecido antes de
executar.
"""


struct TipoAgregacao:
    comptime SOMA = 0
    comptime MEDIA = 1
    comptime CONTAGEM = 2
    comptime MINIMO = 3
    comptime MAXIMO = 4
    comptime PRIMEIRO = 5
    comptime DISTINTOS = 6

    @staticmethod
    def nome(t: Int) raises -> String:
        if t == Self.SOMA:
            return "soma"
        if t == Self.MEDIA:
            return "media"
        if t == Self.CONTAGEM:
            return "contagem"
        if t == Self.MINIMO:
            return "minimo"
        if t == Self.MAXIMO:
            return "maximo"
        if t == Self.PRIMEIRO:
            return "primeiro"
        if t == Self.DISTINTOS:
            return "distintos"
        raise Error("agregacao desconhecida: " + String(t))


struct Agregacao(Copyable, Movable):
    """O que calcular, sobre qual coluna, com que nome de saida."""

    var tipo: Int
    var coluna: String
    var apelido: String

    def __init__(out self, tipo: Int, coluna: String, apelido: String = ""):
        self.tipo = tipo
        self.coluna = coluna
        self.apelido = apelido

    def como(var self, nome: String) -> Self:
        """Renomeia a coluna de saida."""
        self.apelido = nome
        return self^

    def nome_saida(self) raises -> String:
        if self.apelido != "":
            return self.apelido
        if self.tipo == TipoAgregacao.CONTAGEM and self.coluna == "":
            return "contagem"
        return TipoAgregacao.nome(self.tipo) + "_" + self.coluna

    def descrever(self) raises -> String:
        var alvo = self.coluna
        if alvo == "":
            alvo = "*"
        return TipoAgregacao.nome(self.tipo) + "(" + alvo + ")"


def soma(coluna: String) -> Agregacao:
    return Agregacao(TipoAgregacao.SOMA, coluna)


def media(coluna: String) -> Agregacao:
    return Agregacao(TipoAgregacao.MEDIA, coluna)


def contar() -> Agregacao:
    """Conta linhas do grupo, inclusive as com valores ausentes."""
    return Agregacao(TipoAgregacao.CONTAGEM, "")


def contar_de(coluna: String) -> Agregacao:
    """Conta valores presentes na coluna — ausentes nao entram."""
    return Agregacao(TipoAgregacao.CONTAGEM, coluna)


def minimo(coluna: String) -> Agregacao:
    return Agregacao(TipoAgregacao.MINIMO, coluna)


def maximo(coluna: String) -> Agregacao:
    return Agregacao(TipoAgregacao.MAXIMO, coluna)


def primeiro(coluna: String) -> Agregacao:
    return Agregacao(TipoAgregacao.PRIMEIRO, coluna)


def distintos(coluna: String) -> Agregacao:
    return Agregacao(TipoAgregacao.DISTINTOS, coluna)
