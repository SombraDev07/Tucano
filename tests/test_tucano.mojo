from std.testing import assert_equal, assert_true, assert_false, TestSuite
from tucano import (
    Coluna,
    Tabela,
    Tipo,
    DType,
    Schema,
    Campo,
    Validity,
    ler_csv,
    para_csv,
    lazy,
    coluna,
    lit,
    lit_int,
    lit_texto,
    lit_data,
    ano,
    mes,
    dia,
    Tri,
    dias_desde_epoch,
    civil_de_dias,
    eh_data_iso,
    data_para_texto,
    sugerir_nome,
)


def test_coluna_reais_basico() raises:
    var c = Coluna.de_reais("x", [1.0, 2.0, 3.0])
    assert_equal(c.tamanho(), 3)
    assert_equal(c.tipo, Tipo.REAL)
    assert_equal(c.dtype().codigo, DType.real().codigo)
    assert_equal(c.soma(), 6.0)
    assert_equal(c.media(), 2.0)
    assert_equal(c.minimo(), 1.0)
    assert_equal(c.maximo(), 3.0)
    assert_equal(c.contar_ausentes(), 0)


def test_coluna_inteiros_com_na() raises:
    var c = Coluna.de_inteiros(
        "n",
        [Int64(10), Int64(20), Int64(30)],
        [False, True, False],
    )
    assert_equal(c.contar_ausentes(), 1)
    assert_equal(c.contar_validos(), 2)
    assert_true(c.eh_ausente(1))
    assert_false(c.eh_ausente(0))
    assert_equal(c.soma(), 40.0)
    assert_equal(c.media(), 20.0)
    assert_equal(c.texto_em(1), "NA")
    assert_equal(c.validity().contar_ausentes(), 1)


def test_coluna_maior_que() raises:
    var c = Coluna.de_reais("idade", [10.0, 20.0, 30.0])
    var m = c.maior_que(18.0)
    assert_false(m[0])
    assert_true(m[1])
    assert_true(m[2])


def test_coluna_texto_e_logico() raises:
    var t = Coluna.de_textos("nome", ["a", "b"])
    assert_equal(t.tipo, Tipo.TEXTO)
    assert_equal(t.texto_em(0), "a")
    var l = Coluna.de_logicos("ok", [True, False])
    assert_equal(l.tipo, Tipo.LOGICO)
    assert_equal(l.texto_em(1), "False")


def test_tabela_selecionar() raises:
    var idade = Coluna.de_inteiros("idade", [Int64(18), Int64(40)])
    var cidade = Coluna.de_textos("cidade", ["SP", "RJ"])
    var cols = List[Coluna]()
    cols.append(idade.copy())
    cols.append(cidade.copy())
    var tab = Tabela(cols^)
    assert_equal(tab.linhas(), 2)
    assert_equal(tab.colunas(), 2)
    var recorte = tab.selecionar(["cidade"])
    assert_equal(recorte.colunas(), 1)
    assert_equal(recorte.pegar("cidade").texto_em(0), "SP")
    assert_equal(tab.media("idade"), 29.0)


def test_schema_shape_adicionar_remover() raises:
    var idade = Coluna.de_inteiros("idade", [Int64(18), Int64(40)])
    var cidade = Coluna.de_textos("cidade", ["SP", "RJ"])
    var cols = List[Coluna]()
    cols.append(idade.copy())
    cols.append(cidade.copy())
    var tab = Tabela(cols^)

    var sh = tab.shape()
    assert_equal(sh.linhas, 2)
    assert_equal(sh.colunas, 2)

    var sch = tab.schema()
    assert_equal(sch.tamanho(), 2)
    assert_true(sch.contem("idade"))
    assert_equal(sch.dtype_de("idade").codigo, DType.inteiro().codigo)
    assert_equal(sch.dtype_de("cidade").codigo, DType.texto().codigo)

    var ativo = Coluna.de_logicos("ativo", [True, False])
    var com_ativo = tab.adicionar(ativo)
    assert_equal(com_ativo.colunas(), 3)
    assert_true(com_ativo.schema().contem("ativo"))
    assert_equal(tab.colunas(), 2)

    var sem_cidade = com_ativo.remover("cidade")
    assert_equal(sem_cidade.colunas(), 2)
    assert_false(sem_cidade.schema().contem("cidade"))
    assert_true(sem_cidade.schema().contem("ativo"))


def test_validity_todos_presentes() raises:
    var v = Validity.todos_presentes(3)
    assert_equal(v.tamanho(), 3)
    assert_equal(v.contar_ausentes(), 0)
    assert_false(v.eh_ausente(0))
    assert_equal(v.bytes_alocados(), 1)


def test_validity_bitmap_compacto() raises:
    var v = Validity.de_lista([False, True, False, True, False, False, False, False, True])
    assert_equal(v.tamanho(), 9)
    assert_equal(v.bytes_alocados(), 2)
    assert_true(v.eh_ausente(1))
    assert_true(v.eh_ausente(3))
    assert_true(v.eh_ausente(8))
    assert_false(v.eh_ausente(0))
    assert_equal(v.contar_ausentes(), 3)


def test_string_store_utf8_columnar() raises:
    var c = Coluna.de_textos("nome", ["ação", "xy", ""])
    assert_equal(c.texto_em(0), "ação")
    assert_equal(c.texto_em(1), "xy")
    assert_equal(c.texto_em(2), "")
    assert_true(c.textos.bytes_dados() > 0)
    assert_equal(c.textos.tamanho(), 3)
    # slab numerico com capacity == len
    var n = Coluna.de_inteiros("i", [Int64(1), Int64(2), Int64(3)])
    assert_equal(n.ints.capacity(), 3)
    assert_equal(len(n.ints), 3)


def test_ler_csv_infere_tipos_e_na() raises:
    var tab = ler_csv("tests/fixtures/pessoas.csv")
    assert_equal(tab.linhas(), 4)
    assert_equal(tab.colunas(), 4)
    assert_equal(tab.pegar("idade").tipo, Tipo.INTEIRO)
    assert_equal(tab.pegar("salario").tipo, Tipo.REAL)
    assert_equal(tab.pegar("cidade").tipo, Tipo.TEXTO)
    assert_equal(tab.pegar("ativo").tipo, Tipo.LOGICO)
    assert_equal(tab.pegar("salario").contar_ausentes(), 1)
    assert_equal(tab.media("idade"), 29.25)
    assert_equal(tab.pegar("ativo").texto_em(2), "False")
    assert_equal(tab.schema().dtype_de("idade").codigo, DType.inteiro().codigo)


def test_ler_csv_nrows() raises:
    var tab = ler_csv("tests/fixtures/pessoas.csv", nrows=2)
    assert_equal(tab.linhas(), 2)
    assert_equal(tab.pegar("cidade").texto_em(1), "RJ")


def test_para_csv_redondo() raises:
    var original = ler_csv("tests/fixtures/pessoas.csv")
    var saida = "tests/fixtures/_saida_teste.csv"
    para_csv(original, saida)
    var de_novo = ler_csv(saida)
    assert_equal(de_novo.linhas(), original.linhas())
    assert_equal(de_novo.colunas(), original.colunas())
    assert_equal(de_novo.pegar("cidade").texto_em(0), "SP")
    assert_equal(de_novo.pegar("salario").texto_em(1), "NA")


def test_expr_descrever() raises:
    var e = coluna("idade").gt(lit(18.0)).e(coluna("cidade").eq(lit_texto("SP")))
    assert_equal(
        e.descrever(),
        '((coluna(idade) > lit(18.0)) & (coluna(cidade) == lit("SP")))',
    )


def test_lazy_filtro_e_projeto() raises:
    var t = ler_csv("tests/fixtures/pessoas.csv")
    var q = (
        lazy(t)
        .onde(coluna("idade").gt(lit(25.0)))
        .selecionar(["cidade", "idade"])
    )
    var plano = q.descrever()
    assert_true(plano.startswith("SCAN -> FILTER"))
    assert_true("PROJECT [cidade, idade]" in plano)
    var out = q.coletar()
    assert_equal(out.linhas(), 2)
    assert_equal(out.colunas(), 2)
    assert_equal(out.pegar("cidade").texto_em(0), "RJ")
    assert_equal(out.pegar("idade").texto_em(1), "40")


def test_lazy_and_texto() raises:
    var t = ler_csv("tests/fixtures/pessoas.csv")
    var out = (
        lazy(t)
        .onde(coluna("idade").gt(lit(22.0)).e(coluna("cidade").eq(lit_texto("SP"))))
        .coletar()
    )
    assert_equal(out.linhas(), 1)
    assert_equal(out.pegar("cidade").texto_em(0), "SP")
    assert_equal(out.pegar("idade").texto_em(0), "25")


def test_lazy_na_em_filtro_exclui() raises:
    var t = ler_csv("tests/fixtures/pessoas.csv")
    # salario NA na linha RJ: predicao numerica deve excluir a linha
    var out = lazy(t).onde(coluna("salario").gt(lit(1000.0))).coletar()
    assert_equal(out.linhas(), 3)
    assert_equal(out.pegar("cidade").texto_em(1), "BH")


# ---------------------------------------------------------------- M2.5


def test_sem_index_de_rotulo() raises:
    """Decisao 1: linhas() vem das colunas, nao de um campo paralelo."""
    var idade = Coluna.de_inteiros("idade", [Int64(1), Int64(2), Int64(3)])
    var cols = List[Coluna]()
    cols.append(idade.copy())
    var tab = Tabela(cols^)
    assert_equal(tab.linhas(), 3)
    assert_equal(tab.linhas(), tab.pegar("idade").tamanho())


def test_erro_coluna_sugere_nome() raises:
    var t = ler_csv("tests/fixtures/pessoas.csv")
    var pegou = False
    try:
        _ = t.pegar("idadee")
    except e:
        pegou = True
        assert_true("Voce quis dizer 'idade'" in String(e))
    assert_true(pegou)


def test_erro_coluna_lista_quando_nao_ha_sugestao() raises:
    var t = ler_csv("tests/fixtures/pessoas.csv")
    var pegou = False
    try:
        _ = t.pegar("zzzzzzzz")
    except e:
        pegou = True
        assert_true("Colunas disponiveis" in String(e))
    assert_true(pegou)


def test_sugerir_nome_nao_chuta() raises:
    var nomes = List[String]()
    nomes.append("idade")
    nomes.append("cidade")
    assert_equal(sugerir_nome("idadee", nomes), "idade")
    assert_equal(sugerir_nome("salario", nomes), "")


def test_na_tres_valores_negacao() raises:
    """O bug do M2: nao(NA > x) devolvia True e mantinha a linha ausente."""
    var t = ler_csv("tests/fixtures/pessoas.csv")
    # salario: 2000 / NA / 5000 / 1800.5
    var out = lazy(t).onde(coluna("salario").le(lit(2000.0)).nao()).coletar()
    # so BH (5000) e Verdadeiro; a linha NA e Desconhecido e sai
    assert_equal(out.linhas(), 1)
    assert_equal(out.pegar("cidade").texto_em(0), "BH")


def test_na_tres_valores_resultado_vazio() raises:
    var t = ler_csv("tests/fixtures/pessoas.csv")
    var out = lazy(t).onde(coluna("salario").gt(lit(1000.0)).nao()).coletar()
    assert_equal(out.linhas(), 0)
    assert_equal(out.colunas(), 4)


def test_na_tres_valores_e_ou() raises:
    var t = ler_csv("tests/fixtures/pessoas.csv")
    # Desconhecido & Falso = Falso -> nenhuma linha entra pelo lado NA
    var e_falso = (
        lazy(t)
        .onde(coluna("salario").gt(lit(1000.0)).e(coluna("idade").gt(lit(100.0))))
        .coletar()
    )
    assert_equal(e_falso.linhas(), 0)
    # Desconhecido | Verdadeiro = Verdadeiro -> a linha NA entra pelo outro lado
    var ou_verdadeiro = (
        lazy(t)
        .onde(coluna("salario").gt(lit(1000.0)).ou(coluna("cidade").eq(lit_texto("RJ"))))
        .coletar()
    )
    assert_equal(ou_verdadeiro.linhas(), 4)


def test_coluna_logica_como_predicado() raises:
    var t = ler_csv("tests/fixtures/pessoas.csv")
    var out = lazy(t).onde(coluna("ativo")).coletar()
    assert_equal(out.linhas(), 3)
    assert_equal(out.pegar("cidade").texto_em(2), "SP")


def test_tri_constantes() raises:
    assert_equal(Tri.FALSO, 0)
    assert_equal(Tri.VERDADEIRO, 1)
    assert_equal(Tri.DESCONHECIDO, 2)


def test_datas_civil_ida_e_volta() raises:
    assert_equal(dias_desde_epoch(1970, 1, 1), 0)
    assert_equal(dias_desde_epoch(1969, 12, 31), -1)
    assert_equal(dias_desde_epoch(2000, 3, 1), 11017)
    var c = civil_de_dias(dias_desde_epoch(2024, 2, 29))
    assert_equal(c.ano, 2024)
    assert_equal(c.mes, 2)
    assert_equal(c.dia, 29)
    assert_equal(data_para_texto(0), "1970-01-01")
    assert_equal(data_para_texto(dias_desde_epoch(2024, 2, 29)), "2024-02-29")


def test_datas_validacao_iso() raises:
    assert_true(eh_data_iso("2024-02-29"))
    assert_false(eh_data_iso("2023-02-29"))  # 2023 nao e bissexto
    assert_false(eh_data_iso("2024-13-01"))
    assert_false(eh_data_iso("2024-01-32"))
    assert_false(eh_data_iso("24-01-01"))
    assert_false(eh_data_iso("abc"))


def test_coluna_data_basica() raises:
    var c = Coluna.de_datas_texto("d", ["2024-01-15", "2023-12-01"])
    assert_equal(c.tipo, Tipo.DATA)
    assert_equal(c.dtype().nome(), "data")
    assert_false(c.dtype().eh_numerico())
    assert_true(c.dtype().eh_temporal())
    assert_equal(c.texto_em(0), "2024-01-15")
    assert_equal(c.dias_em(1), dias_desde_epoch(2023, 12, 1))


def test_csv_infere_data() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    assert_equal(t.linhas(), 5)
    assert_equal(t.pegar("data").tipo, Tipo.DATA)
    assert_equal(t.pegar("valor").tipo, Tipo.REAL)
    assert_equal(t.pegar("cidade").tipo, Tipo.TEXTO)
    assert_equal(t.pegar("data").texto_em(0), "2024-01-15")
    assert_equal(t.schema().dtype_de("data").codigo, DType.data().codigo)


def test_filtro_por_data() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    var out = lazy(t).onde(coluna("data").ge(lit_data("2024-02-01"))).coletar()
    assert_equal(out.linhas(), 3)
    assert_equal(out.pegar("data").texto_em(0), "2024-02-20")


def test_extratores_de_data() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    var fev = lazy(t).onde(mes(coluna("data")).eq(lit_int(2))).coletar()
    assert_equal(fev.linhas(), 2)

    var de_2023 = lazy(t).onde(ano(coluna("data")).eq(lit_int(2023))).coletar()
    assert_equal(de_2023.linhas(), 1)
    assert_equal(de_2023.pegar("cidade").texto_em(0), "BH")

    var dia_15 = lazy(t).onde(dia(coluna("data")).eq(lit_int(15))).coletar()
    assert_equal(dia_15.linhas(), 1)


def test_data_descrever_plano() raises:
    var e = mes(coluna("data")).eq(lit_int(2))
    assert_equal(e.descrever(), "(mes(coluna(data)) == lit(2))")
    var d = coluna("data").ge(lit_data("2024-02-01"))
    assert_equal(d.descrever(), '(coluna(data) >= lit_data("2024-02-01"))')


def test_data_redondo_no_csv() raises:
    var original = ler_csv("tests/fixtures/vendas.csv")
    var saida = "tests/fixtures/_saida_vendas.csv"
    para_csv(original, saida)
    var de_novo = ler_csv(saida)
    assert_equal(de_novo.pegar("data").tipo, Tipo.DATA)
    assert_equal(de_novo.pegar("data").texto_em(3), "2023-12-01")
    assert_equal(de_novo.pegar("valor").contar_ausentes(), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
