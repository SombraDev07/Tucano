from tucano import ler_csv, coluna, lit, lit_int, lit_texto, lit_data, mes


def main() raises:
    print("=== pessoas.csv ===")
    var t = ler_csv("tests/fixtures/pessoas.csv")
    print("shape:", t.shape().linhas, "x", t.shape().colunas)
    t.mostrar()
    print()
    print("media idade:", t.media("idade"))
    print("soma salario (ignora NA):", t.soma("salario"))
    print()

    print("=== ergonomia eager, execucao lazy ===")
    # onde() devolve um plano; mostrar() materializa sozinho
    var q = t.onde(coluna("idade").gt(lit(18.0)).e(coluna("cidade").eq(lit_texto("SP"))))
    print("plano:", q.descrever())
    q.mostrar()
    print()

    print("=== NA em logica de tres valores ===")
    print("salario > 1000:")
    t.onde(coluna("salario").gt(lit(1000.0))).mostrar()
    print("nao(salario <= 2000) — a linha ausente sai nos dois casos:")
    t.onde(coluna("salario").le(lit(2000.0)).nao()).mostrar()
    print()

    print("=== erro que ensina ===")
    try:
        _ = t.pegar("idadee")
    except e:
        print(e)
    print()

    print("=== vendas.csv: data + coluna derivada ===")
    var v = ler_csv("tests/fixtures/vendas.csv")
    v.mostrar()
    print()

    var pipeline = (
        v.com_coluna("dobro", coluna("valor").vezes(lit(2.0)))
        .com_coluna("mes", mes(coluna("data")))
        .onde(coluna("mes").eq(lit_int(2)))
        .selecionar(["data", "cidade", "valor", "dobro", "mes"])
    )

    print("plano logico:")
    print(pipeline.descrever())
    print()
    print("plano fisico:")
    print(pipeline.descrever_fisico())
    print()

    print("esquema previsto (sem executar):")
    var esq = pipeline.esquema_previsto()
    for campo in esq.campos:
        print("  ", campo.nome, "->", campo.dtype.nome())
    print()

    print("resultado:")
    pipeline.mostrar()
    print()

    print("filtro por data:")
    v.onde(coluna("data").ge(lit_data("2024-02-01"))).mostrar()
