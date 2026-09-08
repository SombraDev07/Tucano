"""Bench M8 — o que o otimizador poupa.

Cada medicao compara o mesmo plano executado das duas formas: como escrito e
depois de otimizado. O plano e o mesmo objeto — muda so quem decide a ordem.
"""

from std.pathlib import Path
from std.time import perf_counter_ns
from tucano import (
    Coluna,
    Tabela,
    Agregacao,
    varredura_parquet,
    para_parquet,
    ler_parquet,
    coluna,
    lit,
    lit_texto,
    soma,
    contar,
)


def _tabela(n: Int) raises -> Tabela:
    var ids = List[Int64](capacity=n)
    var valores = List[Float64](capacity=n)
    var pesos = List[Float64](capacity=n)
    var notas = List[String](capacity=n)
    var grupos = List[String](capacity=n)
    for i in range(n):
        ids.append(Int64(i))
        valores.append(Float64(i % 1000) * 1.5)
        pesos.append(Float64(i % 37) * 0.25)
        notas.append("observacao numero " + String(i % 500))
        grupos.append("grupo-" + String(i % 20))
    var cols = List[Coluna]()
    cols.append(Coluna.de_inteiros("id", ids^))
    cols.append(Coluna.de_reais("valor", valores^))
    cols.append(Coluna.de_reais("peso", pesos^))
    cols.append(Coluna.de_textos("nota", notas^))
    cols.append(Coluna.de_textos("grupo", grupos^))
    return Tabela(cols^)


def _uma(n: String) -> List[String]:
    var l = List[String]()
    l.append(n)
    return l^


def _razao(a: Int, b: Int) -> Float64:
    if b == 0:
        return 0.0
    return Float64(a) / Float64(b)


def main() raises:
    var n = 500_000
    var caminho = "/tmp/tucano_bench_m8.parquet"
    para_parquet(_tabela(n), caminho)
    var bytes = len(Path(caminho).read_bytes())
    print("bench_m8 — n =", n, "| 5 colunas |", bytes // 1024, "KiB em disco")
    print()

    # ---- poda de colunas sobre arquivo
    var chaves = _uma("grupo")
    var aggs = List[Agregacao]()
    aggs.append(soma("valor"))

    var q = varredura_parquet(caminho).agrupar(chaves).agregar(aggs^)
    print(q.explicar())
    print()

    var t0 = perf_counter_ns()
    var sem = q.coletar_sem_otimizar()
    var t1 = perf_counter_ns()
    var ns_sem = t1 - t0

    t0 = perf_counter_ns()
    var com = q.coletar()
    t1 = perf_counter_ns()
    var ns_com = t1 - t0

    print(
        "le tudo (5 colunas) ", ns_sem // 1000000, "ms | com poda (2 colunas) ",
        ns_com // 1000000, "ms | ganho", _razao(ns_sem, ns_com),
    )
    print("        resultados identicos:", sem.linhas() == com.linhas())
    print()

    # ---- empurrao de filtro: ordenar depois de filtrar
    var t = _tabela(n)
    var ordem = _uma("valor")
    var q2 = (
        t.ordenar(ordem)
        .com_coluna("dobro", coluna("valor").vezes(lit(2.0)))
        .onde(coluna("grupo").eq(lit_texto("grupo-7")))
    )
    print(q2.explicar())
    print()

    t0 = perf_counter_ns()
    var s2 = q2.coletar_sem_otimizar()
    t1 = perf_counter_ns()
    var ns_sem2 = t1 - t0

    t0 = perf_counter_ns()
    var c2 = q2.coletar()
    t1 = perf_counter_ns()
    var ns_com2 = t1 - t0

    print(
        "ordena 500k depois filtra", ns_sem2 // 1000000, "ms | filtra e ordena 25k",
        ns_com2 // 1000000, "ms | ganho", _razao(ns_sem2, ns_com2),
    )
    print(
        "        mesmas", s2.linhas(), "linhas:", s2.linhas() == c2.linhas(),
        "| mesma soma:", s2.soma("dobro") == c2.soma("dobro"),
    )
