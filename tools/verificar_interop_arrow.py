"""Verifica que o Arrow IPC escrito pelo Tucano e lido por outra implementacao.

    pixi run -e fixtures interop-arrow

O Arrow e o layout **em memoria**: se os buffers estiverem certos, o outro lado
mapeia em vez de converter. Se estiverem errados, nada disso e detectavel sem um
leitor independente.
"""

import sys
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

RAIZ = Path(__file__).resolve().parent.parent
FIXTURES = RAIZ / "tests" / "fixtures"

DE_PARQUET = ["simples", "com_na", "temporal", "grupos", "dicionario"]


def comparar_com_parquet(nome):
    esperado = pq.read_table(FIXTURES / f"{nome}.parquet")
    lido = pa.ipc.open_file(f"/tmp/tucano_arrow_{nome}.arrow").read_all()

    problemas = []
    if lido.num_rows != esperado.num_rows:
        problemas.append(f"linhas {lido.num_rows} != {esperado.num_rows}")
    if lido.column_names != esperado.column_names:
        problemas.append(f"colunas {lido.column_names} != {esperado.column_names}")
    for coluna in esperado.column_names:
        a = esperado.column(coluna).to_pylist()
        b = lido.column(coluna).to_pylist()
        if a != b:
            for i, (x, y) in enumerate(zip(a, b)):
                if x != y:
                    problemas.append(f"{coluna}[{i}]: {y!r} != {x!r}")
                    break
            else:
                problemas.append(f"{coluna}: tamanhos diferentes")
    return lido, problemas


def relatar(nome, lido, problemas):
    if problemas:
        print(f"  FALHA {nome}")
        for p in problemas[:5]:
            print(f"    - {p}")
        return False
    print(
        f"  ok    {nome:<12} {lido.num_rows:>5} linhas  {lido.num_columns} colunas  "
        f"tipos: {[str(t) for t in lido.schema.types]}"
    )
    return True


def main():
    print("lendo com pyarrow os arquivos Arrow escritos pelo Tucano:")
    ok = True
    for nome in DE_PARQUET:
        caminho = Path(f"/tmp/tucano_arrow_{nome}.arrow")
        if not caminho.exists():
            print(f"  ausente: {caminho} — rode antes: pixi run arrow-roundtrip")
            return 1
        lido, problemas = comparar_com_parquet(nome)
        ok = relatar(nome, lido, problemas) and ok

    # os que vem de CSV nao tem par em Parquet: so precisam abrir e bater os tipos
    for nome, linhas in [("eventos", 4), ("citado", 3)]:
        lido = pa.ipc.open_file(f"/tmp/tucano_arrow_{nome}.arrow").read_all()
        problemas = []
        if lido.num_rows != linhas:
            problemas.append(f"linhas {lido.num_rows} != {linhas}")
        ok = relatar(nome, lido, problemas) and ok

    print("interop Arrow confirmada" if ok else "INTEROP ARROW FALHOU")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
