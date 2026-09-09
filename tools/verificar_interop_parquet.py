"""Verifica que o Parquet escrito pelo Tucano e lido por outra implementacao.

Round-trip proprio nao prova nada: um leitor e um escritor com o mesmo
mal-entendido concordam entre si. O que vale e outra implementacao concordar.

    pixi run -e fixtures interop
"""

import sys
from pathlib import Path

import pyarrow.parquet as pq

RAIZ = Path(__file__).resolve().parent.parent
FIXTURES = RAIZ / "tests" / "fixtures"
ESCRITOS = Path("/tmp")

CASOS = ["simples", "com_na", "temporal", "datas", "grupos"]


def comparar(nome):
    original = pq.read_table(FIXTURES / f"{nome}.parquet")
    escrito = pq.read_table(ESCRITOS / f"tucano_escrito_{nome}.parquet")

    problemas = []
    if escrito.num_rows != original.num_rows:
        problemas.append(f"linhas {escrito.num_rows} != {original.num_rows}")
    if escrito.column_names != original.column_names:
        problemas.append(f"colunas {escrito.column_names} != {original.column_names}")

    for coluna in original.column_names:
        a = original.column(coluna).to_pylist()
        b = escrito.column(coluna).to_pylist()
        if a != b:
            for i, (x, y) in enumerate(zip(a, b)):
                if x != y:
                    problemas.append(f"{coluna}[{i}]: {y!r} != {x!r}")
                    break
            else:
                problemas.append(f"{coluna}: tamanhos diferentes")

    if problemas:
        print(f"  FALHA {nome}")
        for p in problemas[:5]:
            print(f"    - {p}")
        return False
    print(
        f"  ok    {nome:<10} {escrito.num_rows:>5} linhas  "
        f"{escrito.num_columns} colunas  "
        f"tipos: {[str(t) for t in escrito.schema.types]}"
    )
    return True


def main():
    print("lendo com pyarrow os arquivos escritos pelo Tucano:")
    faltando = [
        n for n in CASOS if not (ESCRITOS / f"tucano_escrito_{n}.parquet").exists()
    ]
    if faltando:
        print(f"  arquivos ausentes: {faltando}")
        print("  rode antes: pixi run parquet-roundtrip")
        return 1
    ok = all(comparar(n) for n in CASOS)
    print("interop confirmada" if ok else "INTEROP FALHOU")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
