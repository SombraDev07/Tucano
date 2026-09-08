from tucano import ler_csv, lazy, coluna, lit, lit_int, lit_texto, lit_data, mes


def main() raises:
    print("=== pessoas.csv ===")
    var t = ler_csv("tests/fixtures/pessoas.csv")
    var sh = t.shape()
    print("shape:", sh.linhas, "x", sh.colunas)
    print("schema:", t.schema().nomes())
    t.mostrar()
    print()
    print("media idade:", t.media("idade"))
    print("soma salario (ignora NA):", t.soma("salario"))
    print()

    var q = (
        lazy(t)
        .onde(coluna("idade").gt(lit(18.0)).e(coluna("cidade").eq(lit_texto("SP"))))
        .selecionar(["cidade", "idade", "salario"])
    )
    print("plano:", q.descrever())
    q.coletar().mostrar()
    print()

    print("=== NA em logica de tres valores ===")
    # salario tem NA na linha RJ. A linha ausente sai nos dois casos:
    print("salario > 1000:")
    lazy(t).onde(coluna("salario").gt(lit(1000.0))).coletar().mostrar()
    print("nao(salario <= 2000):")
    lazy(t).onde(coluna("salario").le(lit(2000.0)).nao()).coletar().mostrar()
    print()

    print("=== erro que ensina ===")
    try:
        _ = t.pegar("idadee")
    except e:
        print(e)
    print()

    print("=== vendas.csv: tipo data ===")
    var v = ler_csv("tests/fixtures/vendas.csv")
    print("schema:", v.schema().nomes())
    print("tipo de 'data':", v.dtype_de("data").nome())
    v.mostrar()
    print()

    var por_data = lazy(v).onde(coluna("data").ge(lit_data("2024-02-01")))
    print("plano:", por_data.descrever())
    por_data.coletar().mostrar()
    print()

    var fevereiro = lazy(v).onde(mes(coluna("data")).eq(lit_int(2)))
    print("plano:", fevereiro.descrever())
    fevereiro.coletar().mostrar()
