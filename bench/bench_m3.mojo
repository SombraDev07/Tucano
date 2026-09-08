"""Bench M3 — o executor coluna-a-coluna escala linear.

O M2 avaliava linha a linha e buscava a coluna na `Tabela` a cada linha, com
copia profunda do slab: custo quadratico. O M3 le cada coluna uma vez.

Este bench roda o mesmo pipeline em tamanhos crescentes e imprime ns/linha. Se o
executor for linear, o ns/linha fica aproximadamente constante.
"""

from std.time import perf_counter_ns
from tucano import Coluna, Tabela, coluna, lit, lit_int, mes


def _tabela(n: Int) raises -> Tabela:
    var idades = List[Int64](capacity=n)
    var valores = List[Float64](capacity=n)
    var dias = List[Int64](capacity=n)
    for i in range(n):
        idades.append(Int64(i % 80))
        valores.append(Float64(i) * 0.5)
        dias.append(Int64(19000 + (i % 365)))
    var cols = List[Coluna]()
    cols.append(Coluna.de_inteiros("idade", idades^))
    cols.append(Coluna.de_reais("valor", valores^))
    cols.append(Coluna.de_datas("data", dias^))
    return Tabela(cols^)


def _rodar(n: Int) raises:
    var tab = _tabela(n)

    var t0 = perf_counter_ns()
    var filtrado = tab.onde(coluna("idade").gt(lit(18.0))).coletar()
    var t1 = perf_counter_ns()
    var ns_filtro = t1 - t0

    t0 = perf_counter_ns()
    var derivado = (
        tab.com_coluna("dobro", coluna("valor").vezes(lit(2.0)))
        .com_coluna("mes", mes(coluna("data")))
        .coletar()
    )
    t1 = perf_counter_ns()
    var ns_deriva = t1 - t0

    print(
        "n=",
        n,
        "| filtro",
        ns_filtro // n,
        "ns/linha ->",
        filtrado.linhas(),
        "linhas",
        "| com_coluna x2",
        ns_deriva // n,
        "ns/linha ->",
        derivado.colunas(),
        "colunas",
    )


def main() raises:
    print("bench_m3 — executor coluna-a-coluna")
    print("ns/linha constante = linear; crescente = quadratico")
    print()
    _rodar(25_000)
    _rodar(50_000)
    _rodar(100_000)
    _rodar(200_000)
