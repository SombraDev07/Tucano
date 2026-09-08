"""Bench Parquet — leitura, escrita e o ganho do column pruning.

Os metadados do Parquet ficam no rodape, o que permite saber o esquema e a
posicao de cada coluna sem tocar nos dados. Ler 2 de 6 colunas deve custar
proporcionalmente menos — e e isso que este bench mede.
"""

from std.pathlib import Path
from std.time import perf_counter_ns
from tucano import (
    Coluna,
    Tabela,
    ler_parquet,
    para_parquet,
    esquema_parquet,
    metadados_parquet,
    ler_csv,
    para_csv,
)


def _tabela(n: Int) raises -> Tabela:
    var ids = List[Int64](capacity=n)
    var valores = List[Float64](capacity=n)
    var dobros = List[Float64](capacity=n)
    var dias = List[Int64](capacity=n)
    var ativos = List[Bool](capacity=n)
    var cidades = List[String](capacity=n)
    var nomes = List[String]()
    nomes.append("SP")
    nomes.append("RJ")
    nomes.append("BH")
    nomes.append("POA")
    nomes.append("CWB")
    for i in range(n):
        ids.append(Int64(i))
        valores.append(Float64(i % 1000) * 0.5)
        dobros.append(Float64(i % 500) * 1.25)
        dias.append(Int64(19000 + (i % 365)))
        ativos.append(i % 2 == 0)
        cidades.append(nomes[i % 5])
    var cols = List[Coluna]()
    cols.append(Coluna.de_inteiros("id", ids^))
    cols.append(Coluna.de_reais("valor", valores^))
    cols.append(Coluna.de_reais("dobro", dobros^))
    cols.append(Coluna.de_datas("data", dias^))
    cols.append(Coluna.de_logicos("ativo", ativos^))
    cols.append(Coluna.de_textos("cidade", cidades^))
    return Tabela(cols^)


def main() raises:
    var n = 200_000
    var pq = "/tmp/tucano_bench.parquet"
    var csv = "/tmp/tucano_bench_comparativo.csv"
    var t = _tabela(n)
    print("bench_parquet — n =", n, "| 6 colunas")
    print()

    var t0 = perf_counter_ns()
    para_parquet(t, pq)
    var t1 = perf_counter_ns()
    var bytes_pq = len(Path(pq).read_bytes())
    print(
        "escrita  parquet", (t1 - t0) // 1000000, "ms |", (t1 - t0) // n,
        "ns/linha |", bytes_pq // 1024, "KiB",
    )

    t0 = perf_counter_ns()
    para_csv(t, csv)
    t1 = perf_counter_ns()
    var bytes_csv = len(Path(csv).read_bytes())
    print(
        "escrita  csv    ", (t1 - t0) // 1000000, "ms |", (t1 - t0) // n,
        "ns/linha |", bytes_csv // 1024, "KiB",
    )
    print()

    t0 = perf_counter_ns()
    var lido = ler_parquet(pq)
    t1 = perf_counter_ns()
    var ns_pq = t1 - t0
    print(
        "leitura  parquet", ns_pq // 1000000, "ms |", ns_pq // n,
        "ns/linha ->", lido.linhas(), "x", lido.colunas(),
    )

    t0 = perf_counter_ns()
    var lido_csv = ler_csv(csv)
    t1 = perf_counter_ns()
    var ns_csv = t1 - t0
    print(
        "leitura  csv    ", ns_csv // 1000000, "ms |", ns_csv // n,
        "ns/linha ->", lido_csv.linhas(), "x", lido_csv.colunas(),
    )
    print("         parquet e", Float64(ns_csv) / Float64(ns_pq), "x mais rapido")
    print()

    var duas = List[String]()
    duas.append("id")
    duas.append("valor")
    t0 = perf_counter_ns()
    var podado = ler_parquet(pq, duas)
    t1 = perf_counter_ns()
    var ns_podado = t1 - t0
    print(
        "pruning  2 de 6 ", ns_podado // 1000000, "ms |", ns_podado // n,
        "ns/linha ->", podado.colunas(), "colunas",
    )
    print(
        "         contra ler tudo:", Float64(ns_pq) / Float64(ns_podado),
        "x mais rapido (as colunas nao pedidas nunca sao lidas)",
    )
    print()

    t0 = perf_counter_ns()
    var esq = esquema_parquet(pq)
    var meta = metadados_parquet(pq)
    t1 = perf_counter_ns()
    print(
        "so o rodape     ", (t1 - t0) // 1000, "us ->", esq.tamanho(), "colunas,",
        meta.num_linhas, "linhas,", len(meta.grupos), "row group(s)",
    )
    print("         (esquema e contagem sem tocar em um byte de dado)")
