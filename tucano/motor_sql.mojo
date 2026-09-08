"""SQL -> plano (M10).

A ponte entre o texto e o mesmo `Consulta` que a API fluente produz. Nao ha um
segundo motor: o `SELECT` vira etapas, passa pelo mesmo otimizador e pelo mesmo
executor.

    var t = consultar_sql("SELECT cidade, SUM(valor) AS total FROM 'v.parquet'"
                          " WHERE valor > 1000 GROUP BY cidade ORDER BY total DESC")
    t.mostrar()
"""

from .tabela import Tabela, Consulta, varredura_parquet, ler_parquet
from .csv import ler_csv
from .agregacao import Agregacao
from .sql import ConsultaSQL, ItemSelecao, analisar
from .erros import erro_coluna


struct Catalogo(Movable):
    """Tabelas registradas por nome, para o `FROM`."""

    var nomes: List[String]
    var tabelas: List[Tabela]

    def __init__(out self):
        self.nomes = List[String]()
        self.tabelas = List[Tabela]()

    def registrar(mut self, nome: String, tabela: Tabela) raises:
        for n in self.nomes:
            if n == nome:
                raise Error("catalogo: '" + nome + "' ja esta registrado")
        self.nomes.append(nome)
        self.tabelas.append(tabela.copy())

    def obter(self, nome: String) raises -> Tabela:
        for i in range(len(self.nomes)):
            if self.nomes[i] == nome:
                return self.tabelas[i].copy()
        raise erro_coluna(nome, self.nomes)

    def tem(self, nome: String) -> Bool:
        for n in self.nomes:
            if n == nome:
                return True
        return False


def _termina_com(texto: String, sufixo: String) -> Bool:
    var a = texto.as_bytes()
    var b = sufixo.as_bytes()
    if len(b) > len(a):
        return False
    for i in range(len(b)):
        var x = a[len(a) - len(b) + i]
        if x >= UInt8(65) and x <= UInt8(90):
            x += UInt8(32)
        if x != b[i]:
            return False
    return True


def _consulta_da_fonte(fonte: String, catalogo: Catalogo) raises -> Consulta:
    if catalogo.tem(fonte):
        return Consulta(catalogo.obter(fonte).lote())
    if _termina_com(fonte, ".parquet"):
        return varredura_parquet(fonte)
    if _termina_com(fonte, ".csv"):
        return Consulta(ler_csv(fonte).lote())
    raise Error(
        "SQL: FROM '" + fonte + "' nao e tabela registrada nem arquivo"
        + " .csv/.parquet"
    )


def _tabela_da_fonte(fonte: String, catalogo: Catalogo) raises -> Tabela:
    """Lado direito da juncao: `unir` recebe `Tabela`, nao consulta."""
    if catalogo.tem(fonte):
        return catalogo.obter(fonte)
    if _termina_com(fonte, ".parquet"):
        return ler_parquet(fonte)
    if _termina_com(fonte, ".csv"):
        return ler_csv(fonte)
    raise Error(
        "SQL: JOIN '" + fonte + "' nao e tabela registrada nem arquivo"
        + " .csv/.parquet"
    )


def _nome_de_saida(item: ItemSelecao) raises -> String:
    if item.apelido != "":
        return item.apelido
    if item.eh_agregacao:
        return item.agregacao.nome_saida()
    return item.coluna


def plano_do_sql(texto: String, catalogo: Catalogo) raises -> Consulta:
    """Texto SQL -> `Consulta`, pronta para otimizar e executar."""
    var c = analisar(texto)
    var q = _consulta_da_fonte(c.fonte, catalogo)

    if c.tem_juncao:
        var dir = _tabela_da_fonte(c.fonte_dir, catalogo)
        var chaves = List[String]()
        for k in c.chaves_juncao:
            chaves.append(k)
        q = q^.unir(dir, chaves^, c.tipo_juncao)

    if c.tem_onde:
        q = q^.onde(c.onde.copy())

    var nomes_saida = List[String]()
    for item in c.itens:
        nomes_saida.append(_nome_de_saida(item))

    if c.tem_agregacao() or len(c.agrupar) > 0:
        var aggs = List[Agregacao]()
        for item in c.itens:
            if item.eh_agregacao:
                aggs.append(item.agregacao.copy())
            else:
                # coluna simples num SELECT agregado precisa estar no GROUP BY
                var na_chave = False
                for g in c.agrupar:
                    if g == item.coluna:
                        na_chave = True
                if not na_chave:
                    raise Error(
                        "SQL: a coluna '" + item.coluna + "' esta no SELECT mas"
                        + " nao no GROUP BY — agregue-a ou agrupe por ela"
                    )
        if len(aggs) == 0:
            raise Error("SQL: GROUP BY sem nenhuma agregacao no SELECT")

        if len(c.agrupar) == 0:
            q = q^.agregar_total(aggs^)
        else:
            var chaves = List[String]()
            for g in c.agrupar:
                chaves.append(g)
            q = q^.agrupar(chaves).agregar(aggs^)

    # ordenar por coluna que sobrevive a projecao vai depois dela; por coluna
    # que a projecao descarta, vai antes — assim `ORDER BY` por apelido funciona
    var ordenar_depois = True
    for o in c.ordenar:
        var achou = False
        for n in nomes_saida:
            if n == o:
                achou = True
        if not achou:
            ordenar_depois = False

    if len(c.ordenar) > 0 and not ordenar_depois:
        var por = List[String]()
        for o in c.ordenar:
            por.append(o)
        q = q^.ordenar(por, c.descendente)

    if not c.tudo:
        q = q^.selecionar(nomes_saida)

    if len(c.ordenar) > 0 and ordenar_depois:
        var por = List[String]()
        for o in c.ordenar:
            por.append(o)
        q = q^.ordenar(por, c.descendente)

    if c.limite >= 0:
        q = q^.limite(c.limite)

    return q^


def consultar_sql(texto: String) raises -> Tabela:
    """Executa o SQL sobre arquivo. Atalho de `plano_do_sql(...).coletar()`."""
    return plano_do_sql(texto, Catalogo()).coletar()


def consultar_sql_em(texto: String, catalogo: Catalogo) raises -> Tabela:
    """Executa o SQL usando tabelas registradas."""
    return plano_do_sql(texto, catalogo).coletar()
