"""So a leitura: quanto cada engine leva para materializar o mesmo Parquet.

    pixi run bench-leitura            # o lado do Tucano
    pixi run -e comparativo leitura

Mede duas coisas diferentes, e a distincao importa:

- **tudo**: materializar as 5 colunas do arquivo;
- **2 de 5**: materializar so as colunas pedidas, que e o caso real de quem
  consulta.

Menor de tres execucoes. O arquivo ja esta no cache do sistema em todos os
casos — ninguem paga disco frio e ninguem e favorecido por isso.
"""

import sys
import time
from pathlib import Path

import duckdb
import pandas as pd
import polars as pl
import pyarrow.parquet as pq

ENTRADA = Path("/tmp/tucano_bench_leitura.txt")
COLUNAS = ["valor", "grupo"]
REPETICOES = 3


def menor(fn):
    melhor = None
    for _ in range(REPETICOES):
        t0 = time.perf_counter_ns()
        r = fn()
        ns = time.perf_counter_ns() - t0
        _ = r
        if melhor is None or ns < melhor:
            melhor = ns
    return melhor / 1e6


def main():
    if not ENTRADA.exists():
        print(f"faltam os tempos do Tucano em {ENTRADA}")
        print("rode antes: pixi run bench-leitura")
        return 1

    linhas = [l.split() for l in ENTRADA.read_text().splitlines() if l and not l.startswith("#")]

    print("leitura de Parquet — materializar em memoria")
    print(f"menor de {REPETICOES} execucoes, mesmo arquivo, arquivo em cache")
    print()

    for n, caminho, ns_tudo, ns_podado in linhas:
        tamanho = Path(caminho).stat().st_size / 1048576
        rotulo = f"{int(n):,}".replace(",", ".")
        print(f"{rotulo} linhas x 5 colunas — {tamanho:.0f} MiB")
        print(f"  {'':<22} {'tudo (5 col)':>14} {'2 de 5 col':>14}")

        medidas = [
            ("tucano", int(ns_tudo) / 1e6, int(ns_podado) / 1e6),
            (
                "polars",
                menor(lambda: pl.read_parquet(caminho)),
                menor(lambda: pl.read_parquet(caminho, columns=COLUNAS)),
            ),
            (
                "pandas",
                menor(lambda: pd.read_parquet(caminho, use_threads=False)),
                menor(lambda: pd.read_parquet(caminho, columns=COLUNAS, use_threads=False)),
            ),
            (
                "pyarrow",
                menor(lambda: pq.read_table(caminho)),
                menor(lambda: pq.read_table(caminho, columns=COLUNAS)),
            ),
            (
                "duckdb",
                menor(lambda: duckdb.sql(f"SELECT * FROM read_parquet('{caminho}')").arrow()),
                menor(
                    lambda: duckdb.sql(
                        f"SELECT valor, grupo FROM read_parquet('{caminho}')"
                    ).arrow()
                ),
            ),
        ]
        for nome, tudo, podado in medidas:
            print(f"  {nome:<22} {tudo:>13.0f}m {podado:>13.0f}m")
        print()

    print("polars", pl.__version__, "| pandas", pd.__version__, "| duckdb", duckdb.__version__)
    return 0


if __name__ == "__main__":
    sys.exit(main())
