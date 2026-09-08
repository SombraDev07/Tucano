"""Gera fixtures Parquet para os testes do Tucano.

Roda no ambiente `fixtures` do pixi, que e separado do runtime:

    pixi run fixtures

Nenhum modulo em `tucano/` importa nada daqui. Este script existe porque um
parser de formato binario sem arquivo real para verificar nao e codigo pronto —
e sem ferramenta que escreva Parquet, nao ha arquivo real.

Os .parquet gerados sao commitados, entao rodar isto e necessario apenas quando
as fixtures mudarem.
"""

from datetime import date, datetime
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

DESTINO = Path(__file__).resolve().parent.parent / "tests" / "fixtures"


def _escrever(nome, tabela, **kwargs):
    caminho = DESTINO / nome
    pq.write_table(tabela, caminho, **kwargs)
    meta = pq.ParquetFile(caminho).metadata
    print(
        f"  {nome:<28} {meta.num_rows:>6} linhas  "
        f"{meta.num_columns} colunas  {caminho.stat().st_size:>6} bytes  "
        f"{meta.num_row_groups} row group(s)"
    )


def main():
    DESTINO.mkdir(parents=True, exist_ok=True)
    print("gerando fixtures Parquet em", DESTINO)

    # 1. tipos basicos, sem compressao, sem dicionario: o caminho PLAIN puro
    simples = pa.table(
        {
            "id": pa.array([1, 2, 3, 4, 5], type=pa.int64()),
            "valor": pa.array([10.5, 20.25, 30.0, 40.75, 50.125], type=pa.float64()),
            "ativo": pa.array([True, False, True, True, False], type=pa.bool_()),
            "cidade": pa.array(["SP", "RJ", "SP", "BH", "SP"], type=pa.string()),
        }
    )
    _escrever(
        "simples.parquet", simples, compression="none", use_dictionary=False
    )

    # 2. com ausentes, para exercitar os niveis de definicao
    com_na = pa.table(
        {
            "id": pa.array([1, None, 3, None, 5], type=pa.int64()),
            "valor": pa.array([10.5, 20.25, None, 40.75, None], type=pa.float64()),
            "cidade": pa.array(["SP", None, "SP", "BH", None], type=pa.string()),
        }
    )
    _escrever("com_na.parquet", com_na, compression="none", use_dictionary=False)

    # 3. dicionario ligado: paginas RLE_DICTIONARY
    dicionario = pa.table(
        {
            "cidade": pa.array(["SP", "RJ", "SP", "BH", "SP", "RJ", "SP"] * 20),
            "n": pa.array(list(range(140)), type=pa.int64()),
        }
    )
    _escrever(
        "dicionario.parquet", dicionario, compression="none", use_dictionary=True
    )

    # 4. temporais
    temporal = pa.table(
        {
            "quando": pa.array(
                [date(2024, 1, 15), date(2024, 2, 29), date(2023, 12, 1)],
                type=pa.date32(),
            ),
            "carimbo": pa.array(
                [
                    datetime(2024, 1, 15, 8, 30, 0),
                    datetime(2024, 2, 29, 23, 59, 59, 500000),
                    datetime(1969, 12, 31, 23, 59, 59),
                ],
                type=pa.timestamp("us"),
            ),
        }
    )
    _escrever("temporal.parquet", temporal, compression="none", use_dictionary=False)

    # 5. snappy, a compressao padrao na pratica
    _escrever("snappy.parquet", simples, compression="snappy", use_dictionary=False)

    # 6. varios row groups, para exercitar pruning por grupo
    grande = pa.table(
        {
            "id": pa.array(list(range(3000)), type=pa.int64()),
            "grupo": pa.array([["a", "b", "c"][i % 3] for i in range(3000)]),
            "valor": pa.array([i * 0.5 for i in range(3000)], type=pa.float64()),
        }
    )
    _escrever(
        "grupos.parquet",
        grande,
        compression="none",
        use_dictionary=False,
        row_group_size=1000,
    )

    print("pronto — os .parquet sao commitados; rode de novo so se mudarem")


if __name__ == "__main__":
    main()
