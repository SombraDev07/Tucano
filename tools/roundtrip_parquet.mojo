from tucano import ler_parquet, para_parquet
def main() raises:
    for nome in ["simples", "com_na", "temporal", "datas", "grupos"]:
        var t = ler_parquet("tests/fixtures/" + nome + ".parquet")
        var saida = "/tmp/tucano_escrito_" + nome + ".parquet"
        para_parquet(t, saida)
        var volta = ler_parquet(saida)
        print(nome, "-> escrito e relido:", volta.linhas(), "x", volta.colunas())
        volta.primeiras(3)
        print()
