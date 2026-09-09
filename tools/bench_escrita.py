"""So a escrita: quanto cada engine leva para gravar o mesmo Parquet, e com
quantos bytes.

    pixi run bench-escrita            # o lado do Tucano
    pixi run -e comparativo escrita

Tempo sozinho nao diz nada aqui. Escrever PLAIN sem dicionario e rapido e
produz um arquivo que todo leitor vai pagar para sempre; e por isso que as duas
colunas — ms e MiB — andam juntas nesta tabela.

Menor de tres execucoes, mesmo destino, pagina de dados V1 dos dois lados.
"""

import sys
import time
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq
import polars as pl

ENTRADA = Path("/tmp/tucano_bench_escrita.txt")
DESTINO = Path("/tmp/bench_escrita_referencia.parquet")
REPETICOES = 3


def menor(fn):
    melhor = None
    for _ in range(REPETICOES):
        t0 = time.perf_counter_ns()
        fn()
        ns = time.perf_counter_ns() - t0
        if melhor is None or ns < melhor:
            melhor = ns
    return melhor / 1e6


def tabela(n):
    return pa.table(
        {
            "id": pa.array(range(n), type=pa.int64()),
            "valor": pa.array([(i % 9973) * 1.5 for i in range(n)], type=pa.float64()),
            "peso": pa.array([(i % 41) * 0.25 for i in range(n)], type=pa.float64()),
            "grupo": pa.array([f"grupo-{i % 24}" for i in range(n)]),
            "nota": pa.array([f"registro {i % 500}" for i in range(n)]),
        }
    )


def main():
    if not ENTRADA.exists():
        print(f"faltam os tempos do Tucano em {ENTRADA}")
        print("rode antes: pixi run bench-escrita")
        return 1

    linha = [
        l.split() for l in ENTRADA.read_text().splitlines() if l and not l.startswith("#")
    ][0]
    n, ns_um, bytes_um, ns_cem, bytes_cem = (int(x) for x in linha)

    t = tabela(n)
    df = pl.from_arrow(t)
    rotulo = f"{n:,}".replace(",", ".")
    print(f"escrita de Parquet — {rotulo} linhas x 5 colunas")
    print(f"menor de {REPETICOES} execucoes")
    print()

    def com_pyarrow(por_grupo):
        pq.write_table(t, DESTINO, compression="snappy", row_group_size=por_grupo)

    def com_polars(por_grupo):
        df.write_parquet(DESTINO, compression="snappy", row_group_size=por_grupo)

    for titulo, por_grupo, ns_tucano, bytes_tucano in [
        ("um row group", n, ns_um, bytes_um),
        ("grupos de 100k", 100_000, ns_cem, bytes_cem),
    ]:
        print(f"  {titulo}")
        print(f"    {'':<10} {'ms':>8} {'MiB':>8}")
        print(f"    {'tucano':<10} {ns_tucano / 1e6:>8.0f} {bytes_tucano / 1048576:>8.1f}")
        for nome, fn in [("pyarrow", com_pyarrow), ("polars", com_polars)]:
            ms = menor(lambda: fn(por_grupo))
            print(f"    {nome:<10} {ms:>8.0f} {DESTINO.stat().st_size / 1048576:>8.1f}")
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
