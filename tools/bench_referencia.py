"""Suite comparativa — o lado dos engines de referencia.

    pixi run bench-comparativo            # gera os arquivos e mede o Tucano
    pixi run -e comparativo referencia

Le o mesmo arquivo Parquet, roda a mesma consulta em cada engine e junta os
numeros. Nao ha ajuste favorecendo ninguem: mesmo arquivo, mesma pergunta,
mesmo criterio (menor de tres execucoes).

Mede tambem com **uma thread** em cada engine de referencia. O Tucano nao tem
paralelismo — o stdlib do Mojo 1.0 nao expoe primitiva — e sem isolar esse
fator a comparacao mistura duas coisas: quanto do atraso e de maturidade de
decodificacao, e quanto e simplesmente de nao usar os outros nucleos.

Um numero desfavoravel aqui e informacao, nao derrota. O ponto da suite e saber
onde o Tucano esta, nao provar que ele ganhou.
"""

import os
import sys
import time
from pathlib import Path

UMA_THREAD = "--uma-thread" in sys.argv
if UMA_THREAD:
    # o pool do Polars e fixado no import
    os.environ["POLARS_MAX_THREADS"] = "1"

import duckdb  # noqa: E402
import pandas as pd  # noqa: E402
import polars as pl  # noqa: E402

ENTRADA = Path("/tmp/tucano_bench_comparativo.txt")
REPETICOES = 3


def menor(fn):
    melhor = None
    for _ in range(REPETICOES):
        t0 = time.perf_counter_ns()
        _ = fn()
        ns = time.perf_counter_ns() - t0
        if melhor is None or ns < melhor:
            melhor = ns
    return melhor


def com_polars(caminho):
    return (
        pl.scan_parquet(caminho)
        .filter(pl.col("valor") > 1000.0)
        .group_by("grupo")
        .agg(
            pl.col("valor").sum().alias("soma_valor"),
            pl.col("peso").mean().alias("media_peso"),
            pl.len().alias("contagem"),
        )
        .collect()
    )


CONSULTA = """
    SELECT grupo, SUM(valor) AS soma_valor, AVG(peso) AS media_peso,
           COUNT(*) AS contagem
    FROM read_parquet('{c}')
    WHERE valor > 1000.0
    GROUP BY grupo
"""


def com_pandas(caminho):
    df = pd.read_parquet(
        caminho, columns=["valor", "peso", "grupo"], use_threads=False
    )
    f = df[df["valor"] > 1000.0]
    return f.groupby("grupo", observed=True).agg(
        soma_valor=("valor", "sum"),
        media_peso=("peso", "mean"),
        contagem=("valor", "size"),
    )


def com_duckdb(conexao, caminho):
    return conexao.sql(CONSULTA.format(c=caminho)).fetchall()


def main():
    if not ENTRADA.exists():
        print(f"faltam os tempos do Tucano em {ENTRADA}")
        print("rode antes: pixi run bench-comparativo")
        return 1

    linhas = [
        l.split() for l in ENTRADA.read_text().splitlines() if not l.startswith("#")
    ]

    conexao = duckdb.connect()
    if UMA_THREAD:
        conexao.sql("SET threads TO 1")

    threads_polars = pl.thread_pool_size()
    threads_duck = conexao.sql("SELECT current_setting('threads')").fetchone()[0]

    modo = "UMA THREAD" if UMA_THREAD else "todos os nucleos"
    print(f"bench comparativo — Parquet -> filtro -> agrupar -> 3 agregacoes  [{modo}]")
    print(
        f"menor de {REPETICOES} execucoes | polars usa {threads_polars} thread(s), "
        f"duckdb usa {threads_duck} | pandas e Tucano em uma thread"
    )
    print()
    cab = (
        f"{'linhas':>11} {'tucano':>9} {'em fluxo':>9} {'pandas':>9} "
        f"{'polars':>9} {'duckdb':>9}"
    )
    print(cab)
    print("-" * len(cab))

    for n, caminho, ns_tucano, ns_fluxo in linhas:
        ms_t = int(ns_tucano) / 1e6
        ms_f = int(ns_fluxo) / 1e6
        ms_pd = menor(lambda: com_pandas(caminho)) / 1e6
        ms_p = menor(lambda: com_polars(caminho)) / 1e6
        ms_d = menor(lambda: com_duckdb(conexao, caminho)) / 1e6
        rotulo = f"{int(n):,}".replace(",", ".")
        print(
            f"{rotulo:>11} {ms_t:>8.0f}m {ms_f:>8.0f}m {ms_pd:>8.0f}m "
            f"{ms_p:>8.0f}m {ms_d:>8.0f}m"
        )
        veredito = "mais rapido que pandas" if ms_t < ms_pd else "atraso para pandas"
        print(
            f"{'':>11} {'':>9} {'':>9} "
            f"{'x' + format(ms_t / ms_pd, '.2f'):>9} "
            f"{'x' + format(ms_t / ms_p, '.1f'):>9} "
            f"{'x' + format(ms_t / ms_d, '.1f'):>9}   ({veredito})"
        )

    print()
    print(
        "polars", pl.__version__, "| duckdb", duckdb.__version__,
        "| pandas", pd.__version__,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
