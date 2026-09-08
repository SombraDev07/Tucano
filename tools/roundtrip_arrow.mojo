"""Escreve, com o Tucano, os arquivos Arrow que outra implementacao vai ler.

    pixi run arrow-roundtrip
    pixi run -e fixtures interop-arrow

Round-trip proprio nao prova nada: um leitor e um escritor com o mesmo
mal-entendido concordam entre si. Estes arquivos existem para serem lidos por
outra implementacao.
"""

from tucano import ler_parquet, ler_csv, para_arrow


def main() raises:
    for nome in ["simples", "com_na", "temporal", "grupos", "dicionario"]:
        var t = ler_parquet("tests/fixtures/" + nome + ".parquet")
        para_arrow(t, "/tmp/tucano_arrow_" + nome + ".arrow")
        print("  ", nome, "->", t.linhas(), "linhas")

    para_arrow(ler_csv("tests/fixtures/eventos.csv"), "/tmp/tucano_arrow_eventos.arrow")
    para_arrow(ler_csv("tests/fixtures/citado.csv"), "/tmp/tucano_arrow_citado.arrow")
    print("   eventos, citado -> escritos")
