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
    ler_csv_tipado,
    LeitorCSV,
    lit_datahora,
    hora,
    minuto,
    segundo,
    parse_datahora_iso,
    datahora_para_texto,
    eh_datahora_iso,
    civil_de_micros,
    micros_desde_epoch,
    ler_parquet,
    para_parquet,
    soma,
    media,
    contar,
    contar_de,
    minimo,
    maximo,
    primeiro,
    distintos,
    Agregacao,
    Painel,
    varredura_parquet,
    TipoWidget,
    esquema_parquet,
    metadados_parquet,
    consultar_sql,
    para_arrow,
    ler_arrow,
    consultar_sql_em,
    plano_do_sql,
    Catalogo,
    tokenizar,
    analisar,
    Vetor,
    Etapa,
    TipoEtapa,
    Consulta,
)
from tucano.codecs import (
    decodificar_rle,
    decodificar_rle_i32,
    codificar_rle_i32,
    descomprimir_snappy,
    largura_de_bits,
)
from tucano.thrift import LeitorThrift
from tucano.arquivo import LeitorArquivo
from tucano.flatbuf import ConstrutorFlat, raiz_flat, campo_flat, ler_i32, texto_flat
from tucano.fluxo import plano_flui, EstadoAgregacao
from tucano.parquet import VarreduraParquet, grupo_impossivel, n_grupos_possiveis
from tucano.otimizador import (
    dobrar_constantes,
    mesclar_filtros,
    empurrar_filtros,
    colunas_do_plano,
    colunas_da_expr,
    otimizar,
)
from tucano.plano import Etapa, TipoEtapa
from tucano.json import escapar, tabela_para_json, lista_para_json
from tucano.http import decodificar_url, parametros
from tucano.painel_web import pagina
from tucano.scanner import escanear, parse_float, parse_int, para_texto, eh_datahora
from tucano.kernels import (
    add_f64,
    mul_f64,
    cmp_f64,
    tri_e,
    tri_ou,
    tri_nao,
    soma_f64,
    calendario_f64,
    contar_marcados,
    largura_f64,
)
from tucano.executor import (
    calcular_grupos,
    TipoJuncao,
    extrair_coluna,
    avaliar,
    avaliar_tri,
    tipo_resultado,
    esquema_do_lote,
    esquema_apos,
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
    """Ordem do reticulado de Kleene: E vira min, OU vira max, NAO vira 2-x."""
    assert_equal(Tri.FALSO, 0)
    assert_equal(Tri.DESCONHECIDO, 1)
    assert_equal(Tri.VERDADEIRO, 2)


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


# ------------------------------------------------------------------ M3


def test_m3_extrai_coluna_uma_vez() raises:
    """O executor le a coluna para um Vetor contiguo, nao por linha."""
    var t = ler_csv("tests/fixtures/pessoas.csv")
    var v = extrair_coluna(t.lote(), "salario")
    assert_equal(v.tamanho(), 4)
    assert_false(v.eh_texto)
    assert_equal(v.reais[0], 2000.0)
    assert_true(v.eh_na(1))
    assert_false(v.eh_na(0))
    assert_equal(v.contar_ausentes(), 1)

    var texto = extrair_coluna(t.lote(), "cidade")
    assert_true(texto.eh_texto)
    assert_equal(texto.textos[0], "SP")


def test_m3_avaliar_expressao_vetorizada() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    var v = avaliar(coluna("valor").vezes(lit(2.0)), t.lote())
    assert_equal(v.tamanho(), 5)
    assert_equal(v.reais[0], 2400.0)
    assert_true(v.eh_na(3))  # valor NA propaga


def test_m3_mascara_tri_vetorizada() raises:
    var t = ler_csv("tests/fixtures/pessoas.csv")
    var m = avaliar_tri(coluna("salario").gt(lit(1000.0)), t.lote())
    assert_equal(len(m), 4)
    assert_equal(m[0], Tri.VERDADEIRO)
    assert_equal(m[1], Tri.DESCONHECIDO)
    assert_equal(m[2], Tri.VERDADEIRO)


def test_m3_tabela_onde_devolve_consulta_lazy() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    var q = t.onde(coluna("valor").gt(lit(1000.0)))
    assert_equal(q.etapas_do_plano(), 1)
    # materializacao automatica
    assert_equal(q.linhas(), 3)
    assert_equal(q.pegar("cidade").texto_em(0), "SP")


def test_m3_com_coluna_derivada() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    var out = t.com_coluna("dobro", coluna("valor").vezes(lit(2.0))).coletar()
    assert_equal(out.colunas(), 4)
    assert_equal(out.pegar("dobro").texto_em(0), "2400.0")
    assert_true(out.pegar("dobro").eh_ausente(3))
    assert_equal(t.colunas(), 3)  # a original nao muda


def test_m3_com_coluna_substitui() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    var out = t.com_coluna("valor", coluna("valor").mais(lit(1.0))).coletar()
    assert_equal(out.colunas(), 3)
    assert_equal(out.pegar("valor").texto_em(0), "1201.0")


def test_m3_tipo_derivado_sem_coercao() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    var esq = esquema_do_lote(t.lote())
    # o no 0 da arena e o filho: coluna("data") continua sendo data
    var extrai = mes(coluna("data"))
    assert_equal(tipo_resultado(extrai, 0, esq), DType.DATA)
    assert_equal(tipo_resultado(extrai, extrai.root, esq), DType.INTEIRO)
    # inteiro + inteiro = inteiro; qualquer real = real; divisao sempre real
    var soma_i = mes(coluna("data")).mais(lit_int(1))
    assert_equal(tipo_resultado(soma_i, soma_i.root, esq), DType.INTEIRO)
    var prod_r = coluna("valor").vezes(lit(2.0))
    assert_equal(tipo_resultado(prod_r, prod_r.root, esq), DType.REAL)
    var div = mes(coluna("data")).sobre(lit_int(2))
    assert_equal(tipo_resultado(div, div.root, esq), DType.REAL)


def test_m3_esquema_previsto_sem_executar() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    var q = (
        t.com_coluna("dobro", coluna("valor").vezes(lit(2.0)))
        .com_coluna("m", mes(coluna("data")))
        .selecionar(["cidade", "dobro", "m"])
    )
    var esq = q.esquema_previsto()
    assert_equal(esq.tamanho(), 3)
    assert_equal(esq.dtype_de("cidade").codigo, DType.TEXTO)
    assert_equal(esq.dtype_de("dobro").codigo, DType.REAL)
    assert_equal(esq.dtype_de("m").codigo, DType.INTEIRO)
    # e bate com o que a execucao produz
    assert_equal(q.schema().nomes(), esq.nomes())


def test_m3_plano_com_todas_as_etapas() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    var q = (
        t.com_coluna("m", mes(coluna("data")))
        .onde(coluna("m").eq(lit_int(2)))
        .selecionar(["cidade", "m"])
    )
    var logico = q.descrever()
    assert_true("WITH_COLUMN m = mes(coluna(data))" in logico)
    assert_true("FILTER (coluna(m) == lit(2))" in logico)
    assert_true("PROJECT [cidade, m]" in logico)

    var fisico = q.descrever_fisico()
    assert_true("ScanExec" in fisico)
    assert_true("ExpressionExec" in fisico)
    assert_true("FilterExec" in fisico)
    assert_true("ProjectionExec" in fisico)

    # filtro sobre coluna criada em etapa anterior
    assert_equal(q.linhas(), 2)


def test_m3_avisos_de_caminho_escalar() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    # M4: extrator de data virou kernel SIMD em Int32
    var com_data = t.onde(mes(coluna("data")).eq(lit_int(2)))
    assert_equal(len(com_data.avisos()), 0)

    # texto de alta cardinalidade nao dicionariza: continua escalar e avisa
    var unicos = List[String]()
    for i in range(4):
        unicos.append("id-" + String(i))
    var cols = List[Coluna]()
    cols.append(Coluna.de_textos("chave", unicos^))
    var alta = Tabela(cols^)
    var notas = alta.onde(coluna("chave").eq(lit_texto("id-1"))).avisos()
    assert_true(len(notas) > 0)
    assert_true("escalar" in notas[0])

    # M4: cidade e dicionarizada, entao a comparacao e SIMD sobre Int32
    var com_texto = t.onde(coluna("cidade").eq(lit_texto("SP")))
    assert_equal(len(com_texto.avisos()), 0)

    var so_numero = t.onde(coluna("valor").gt(lit(1000.0)))
    assert_equal(len(so_numero.avisos()), 0)


def test_m3_sem_coercao_entre_texto_e_numero() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    var pegou = False
    try:
        _ = t.onde(coluna("cidade").eq(lit(1.0))).coletar()
    except e:
        pegou = True
        assert_true("texto e numero" in String(e))
    assert_true(pegou)


def test_m3_ordem_lexicografica_em_texto() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    var out = t.onde(coluna("cidade").ge(lit_texto("RJ"))).coletar()
    assert_equal(out.linhas(), 4)  # SP, RJ, SP, SP


def test_m3_esquema_apos_propaga() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    var etapas = List[Etapa]()
    etapas.append(Etapa.com_coluna("m", mes(coluna("data"))))
    etapas.append(Etapa.projecao(["cidade", "m"]))
    var esq = esquema_apos(esquema_do_lote(t.lote()), etapas)
    assert_equal(len(esq), 2)
    assert_equal(esq[1].nome, "m")
    assert_equal(esq[1].dtype.codigo, DType.INTEIRO)


def test_m3_vetor_constante() raises:
    var v = Vetor.constante_numerica(3, 7.0)
    assert_equal(v.tamanho(), 3)
    assert_equal(v.reais[2], 7.0)
    assert_equal(v.contar_ausentes(), 0)
    var s = Vetor.constante_textual(2, "x")
    assert_true(s.eh_texto)
    assert_equal(s.textos[1], "x")


def test_m3_lazy_continua_funcionando() raises:
    """Compatibilidade: lazy() e o caminho antigo seguem validos."""
    var t = ler_csv("tests/fixtures/pessoas.csv")
    var q = lazy(t).onde(coluna("idade").gt(lit(25.0))).selecionar(["cidade"])
    assert_equal(q.coletar().linhas(), 2)
    assert_equal(q.etapas_do_plano(), 2)


# ------------------------------------------------------------------ M4


def _u8(n: Int, v: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for _ in range(n):
        out.append(UInt8(v))
    return out^


def _f64(valores: List[Float64]) -> List[Float64]:
    var out = List[Float64](capacity=len(valores))
    for v in valores:
        out.append(v)
    return out^


def test_m4_largura_simd_valida() raises:
    assert_true(largura_f64() >= 1)


def test_m4_kernel_aritmetica_cobre_cauda() raises:
    """Tamanho nao multiplo da largura SIMD: a cauda escalar precisa fechar."""
    var n = largura_f64() * 3 + 1
    var a = List[Float64](capacity=n)
    var b = List[Float64](capacity=n)
    var out = List[Float64](capacity=n)
    for i in range(n):
        a.append(Float64(i))
        b.append(2.0)
        out.append(0.0)
    add_f64(a, b, out, n)
    for i in range(n):
        assert_equal(out[i], Float64(i) + 2.0)
    mul_f64(a, b, out, n)
    assert_equal(out[n - 1], Float64(n - 1) * 2.0)


def test_m4_kernel_comparacao_tres_valores() raises:
    var n = 5
    var a = _f64([1.0, 5.0, 3.0, 9.0, 3.0])
    var b = _f64([3.0, 3.0, 3.0, 3.0, 3.0])
    var na = _u8(n, 0)
    na[4] = UInt8(1)
    var out = _u8(n, 0)
    cmp_f64(0, a, b, na, out, n)  # gt
    assert_equal(Int(out[0]), Tri.FALSO)
    assert_equal(Int(out[1]), Tri.VERDADEIRO)
    assert_equal(Int(out[2]), Tri.FALSO)
    assert_equal(Int(out[3]), Tri.VERDADEIRO)
    assert_equal(Int(out[4]), Tri.DESCONHECIDO)


def test_m4_kernels_kleene() raises:
    # todas as 9 combinacoes de E e OU
    var n = 9
    var a = _u8(n, 0)
    var b = _u8(n, 0)
    var esperado_e = _u8(n, 0)
    var esperado_ou = _u8(n, 0)
    var vals = List[Int]()
    vals.append(Tri.FALSO)
    vals.append(Tri.DESCONHECIDO)
    vals.append(Tri.VERDADEIRO)
    var k = 0
    for i in range(3):
        for j in range(3):
            a[k] = UInt8(vals[i])
            b[k] = UInt8(vals[j])
            esperado_e[k] = UInt8(min(vals[i], vals[j]))
            esperado_ou[k] = UInt8(max(vals[i], vals[j]))
            k += 1
    var out = _u8(n, 0)
    tri_e(a, b, out, n)
    for i in range(n):
        assert_equal(out[i], esperado_e[i])
    tri_ou(a, b, out, n)
    for i in range(n):
        assert_equal(out[i], esperado_ou[i])
    # NAO: F->V, D->D, V->F
    var tres = _u8(3, 0)
    tres[0] = UInt8(Tri.FALSO)
    tres[1] = UInt8(Tri.DESCONHECIDO)
    tres[2] = UInt8(Tri.VERDADEIRO)
    var neg = _u8(3, 0)
    tri_nao(tres, neg, 3)
    assert_equal(Int(neg[0]), Tri.VERDADEIRO)
    assert_equal(Int(neg[1]), Tri.DESCONHECIDO)
    assert_equal(Int(neg[2]), Tri.FALSO)


def test_m4_kernel_soma_ignora_ausentes() raises:
    var n = 10
    var d = List[Float64](capacity=n)
    var na = _u8(n, 0)
    for i in range(n):
        d.append(Float64(i))
    na[3] = UInt8(1)
    na[7] = UInt8(1)
    assert_equal(soma_f64(d, na, n), 45.0 - 3.0 - 7.0)
    assert_equal(contar_marcados(na, n), 2)


def test_m4_kernel_calendario_bate_com_escalar() raises:
    """SIMD em Int32 tem de dar exatamente o mesmo que o algoritmo escalar."""
    var n = 1000
    var dias = List[Float64](capacity=n)
    for i in range(n):
        dias.append(Float64(i * 37 - 10_000))
    var out = List[Float64](capacity=n)
    for _ in range(n):
        out.append(0.0)

    calendario_f64(0, dias, out, n)
    for i in range(n):
        assert_equal(Int(out[i]), civil_de_dias(Int(dias[i])).ano)
    calendario_f64(1, dias, out, n)
    for i in range(n):
        assert_equal(Int(out[i]), civil_de_dias(Int(dias[i])).mes)
    calendario_f64(2, dias, out, n)
    for i in range(n):
        assert_equal(Int(out[i]), civil_de_dias(Int(dias[i])).dia)


def test_m4_dicionario_quando_ha_repeticao() raises:
    var repetida = Coluna.de_textos("cidade", ["SP", "RJ", "SP", "BH", "SP"])
    assert_true(repetida.eh_dicionarizada())
    assert_equal(repetida.cardinalidade(), 3)
    assert_equal(repetida.texto_em(0), "SP")
    assert_equal(repetida.texto_em(3), "BH")
    assert_equal(Int(repetida.codigo_de("RJ")), 1)
    assert_equal(Int(repetida.codigo_de("XX")), -1)

    # tudo distinto: nao compensa dicionarizar
    var distinta = Coluna.de_textos("id", ["a", "b", "c"])
    assert_false(distinta.eh_dicionarizada())
    assert_equal(distinta.texto_em(2), "c")


def test_m4_dicionario_preserva_na() raises:
    var c = Coluna.de_textos(
        "cidade", ["SP", "", "SP", "RJ"], [False, True, False, False]
    )
    assert_true(c.eh_dicionarizada())
    assert_equal(c.texto_em(1), "NA")
    assert_equal(c.contar_ausentes(), 1)


def test_m4_filtro_por_dicionario_bate_com_escalar() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    assert_true(t.pegar("cidade").eh_dicionarizada())
    var sp = t.onde(coluna("cidade").eq(lit_texto("SP"))).coletar()
    assert_equal(sp.linhas(), 3)
    var nao_sp = t.onde(coluna("cidade").ne(lit_texto("SP"))).coletar()
    assert_equal(nao_sp.linhas(), 2)
    # literal fora do dicionario: nenhuma linha casa
    var nenhuma = t.onde(coluna("cidade").eq(lit_texto("XYZ"))).coletar()
    assert_equal(nenhuma.linhas(), 0)


def test_m4_validity_conta_em_tempo_constante() raises:
    var v = Validity.de_lista([False, True, False, True])
    assert_equal(v.contar_ausentes(), 2)
    assert_true(v.tem_ausentes())
    var vazia = Validity.todos_presentes(100)
    assert_equal(vazia.contar_ausentes(), 0)
    assert_false(vazia.tem_ausentes())
    var bytes = vazia.para_bytes()
    assert_equal(len(bytes), 100)
    assert_equal(bytes[99], UInt8(0))


def test_m4_validity_para_bytes_desempacota() raises:
    var v = Validity.de_lista([False, True, False, True, False, False, False, False, True])
    var b = v.para_bytes()
    assert_equal(len(b), 9)
    assert_equal(b[1], UInt8(1))
    assert_equal(b[3], UInt8(1))
    assert_equal(b[8], UInt8(1))
    assert_equal(b[0], UInt8(0))


def test_m4_reducoes_batem_com_escalar() raises:
    var n = largura_f64() * 5 + 3
    var vals = List[Float64](capacity=n)
    var aus = List[Bool](capacity=n)
    var esperado = Float64(0)
    for i in range(n):
        var v = Float64((i * 7) % 23) - 5.0
        vals.append(v)
        var ausente = i % 11 == 0
        aus.append(ausente)
        if not ausente:
            esperado += v
    var c = Coluna.de_reais("x", vals^, aus^)
    assert_equal(c.soma(), esperado)
    assert_equal(c.media(), esperado / Float64(c.contar_validos()))


# ------------------------------------------------------------------ M5


def _bytes(t: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in t.as_bytes():
        out.append(b)
    return out^


def test_m5_scanner_marca_campos_sem_alocar() raises:
    var b = _bytes("a,b,c\n1,2,3\n")
    var c = escanear(b, UInt8(44))
    assert_equal(c.n_linhas, 2)
    assert_equal(c.n_cols, 3)
    assert_equal(para_texto(b, c.inicio[c.indice(1, 2)], c.fim[c.indice(1, 2)], False), "3")


def test_m5_scanner_aspas_rfc4180() raises:
    var t = ler_csv("tests/fixtures/citado.csv")
    assert_equal(t.linhas(), 3)
    assert_equal(t.colunas(), 3)
    # delimitador dentro do campo citado
    assert_equal(t.pegar("nome").texto_em(0), "Silva, João")
    # aspas escapadas
    assert_equal(t.pegar("obs").texto_em(0), 'diz "oi"')
    # quebra de linha dentro do campo
    assert_equal(t.pegar("obs").texto_em(1), "linha um\nlinha dois")
    # campo citado vazio conta como ausente
    assert_true(t.pegar("nome").eh_ausente(2))
    assert_equal(t.pegar("valor").texto_em(1), "20.25")


def test_m5_scanner_aspas_nao_fechadas_erra() raises:
    var b = _bytes('a\n"sem fim\n')
    var pegou = False
    try:
        _ = escanear(b, UInt8(44))
    except e:
        pegou = True
        assert_true("aspas" in String(e))
    assert_true(pegou)


def test_m5_parse_numerico_exato() raises:
    var ok = False
    var b = _bytes("1800.5")
    assert_equal(parse_float(b, 0, 6, ok), 1800.5)
    assert_true(ok)

    var neg = _bytes("-42")
    ok = False
    assert_equal(Int(parse_int(neg, 0, 3, ok)), -42)
    assert_true(ok)

    # nao inteiro
    var f = _bytes("3.5")
    ok = False
    _ = parse_int(f, 0, 3, ok)
    assert_false(ok)

    # notacao cientifica cai no fallback e ainda funciona
    var e = _bytes("1.5e3")
    ok = False
    assert_equal(parse_float(e, 0, 5, ok), 1500.0)
    assert_true(ok)


def test_m5_csv_valores_batem_exatamente() raises:
    """O parser rapido tem de dar o mesmo que o caminho de referencia."""
    var t = ler_csv("tests/fixtures/pessoas.csv")
    assert_equal(t.pegar("salario").texto_em(0), "2000.0")
    assert_equal(t.pegar("salario").texto_em(3), "1800.5")
    assert_equal(t.soma("salario"), 8800.5)


def test_m5_schema_explicito() raises:
    var campos = List[Campo]()
    campos.append(Campo("idade", DType.real()))
    campos.append(Campo("salario", DType.real()))
    campos.append(Campo("cidade", DType.texto()))
    campos.append(Campo("ativo", DType.logico()))
    var t = ler_csv_tipado("tests/fixtures/pessoas.csv", Schema(campos^))
    # idade seria inferida como inteiro; o schema manda
    assert_equal(t.dtype_de("idade").codigo, DType.REAL)
    assert_equal(t.pegar("idade").texto_em(0), "25.0")


def test_m5_schema_com_tamanho_errado_erra() raises:
    var campos = List[Campo]()
    campos.append(Campo("idade", DType.inteiro()))
    var pegou = False
    try:
        _ = ler_csv_tipado("tests/fixtures/pessoas.csv", Schema(campos^))
    except e:
        pegou = True
        assert_true("schema tem" in String(e))
    assert_true(pegou)


def test_m5_leitor_em_fatias() raises:
    var leitor = LeitorCSV("tests/fixtures/vendas.csv")
    assert_equal(leitor.total_linhas(), 5)
    assert_equal(leitor.schema().tamanho(), 3)
    assert_false(leitor.fim())

    var a = leitor.proximo(2)
    assert_equal(a.linhas(), 2)
    assert_equal(a.pegar("cidade").texto_em(0), "SP")
    assert_equal(leitor.restantes(), 3)

    var b = leitor.proximo(2)
    assert_equal(b.linhas(), 2)
    var c = leitor.proximo(10)  # pede mais do que sobra
    assert_equal(c.linhas(), 1)
    assert_true(leitor.fim())

    var pegou = False
    try:
        _ = leitor.proximo(1)
    except:
        pegou = True
    assert_true(pegou)


def test_m5_nrows_e_pular() raises:
    var duas = ler_csv("tests/fixtures/vendas.csv", nrows=2)
    assert_equal(duas.linhas(), 2)
    assert_equal(duas.pegar("cidade").texto_em(1), "RJ")

    # pular descarta linhas fisicas antes do cabecalho contar
    var sem_cabecalho = ler_csv(
        "tests/fixtures/vendas.csv", tem_cabecalho=False, pular=1
    )
    assert_equal(sem_cabecalho.linhas(), 5)
    assert_equal(sem_cabecalho.dtype_de("col0").codigo, DType.DATA)


def test_m5_datahora_parse_e_render() raises:
    var m = parse_datahora_iso("2024-01-15T10:30:00")
    assert_equal(datahora_para_texto(m), "2024-01-15T10:30:00")
    var c = civil_de_micros(m)
    assert_equal(c.ano, 2024)
    assert_equal(c.hora, 10)
    assert_equal(c.minuto, 30)

    # fracao de segundo e Z final
    var f = parse_datahora_iso("2024-02-29T23:59:59.500000Z")
    assert_equal(datahora_para_texto(f), "2024-02-29T23:59:59.500000")

    # antes da epoch: divisao de piso tem de estar certa
    var antes = parse_datahora_iso("1969-12-31T23:59:59")
    assert_equal(antes, -1_000_000)
    assert_equal(datahora_para_texto(antes), "1969-12-31T23:59:59")

    assert_equal(micros_desde_epoch(1970, 1, 1, 0, 0, 0), 0)
    assert_false(eh_datahora_iso("2024-01-15"))
    assert_false(eh_datahora_iso("2024-01-15T25:00:00"))


def test_m5_csv_infere_datahora() raises:
    var t = ler_csv("tests/fixtures/eventos.csv")
    assert_equal(t.dtype_de("quando").codigo, DType.DATAHORA)
    assert_equal(t.dtype_de("quando").nome(), "datahora")
    assert_true(t.dtype_de("quando").eh_temporal())
    assert_false(t.dtype_de("quando").eh_numerico())
    assert_equal(t.pegar("quando").texto_em(0), "2024-01-15T08:30:00")
    assert_equal(t.pegar("quando").micros_em(0), parse_datahora_iso("2024-01-15T08:30:00"))


def test_m5_extratores_de_hora() raises:
    var t = ler_csv("tests/fixtures/eventos.csv")
    var h = t.com_coluna("h", hora(coluna("quando"))).coletar()
    assert_equal(h.pegar("h").texto_em(0), "8")
    assert_equal(h.pegar("h").texto_em(1), "14")
    var m = t.com_coluna("m", minuto(coluna("quando"))).coletar()
    assert_equal(m.pegar("m").texto_em(1), "5")
    var s = t.com_coluna("s", segundo(coluna("quando"))).coletar()
    assert_equal(s.pegar("s").texto_em(1), "30")


def test_m5_ano_mes_funcionam_em_datahora() raises:
    """A unidade viaja no Vetor: `mes()` serve para data e para datahora."""
    var t = ler_csv("tests/fixtures/eventos.csv")
    var out = t.com_coluna("m", mes(coluna("quando"))).coletar()
    assert_equal(out.pegar("m").texto_em(0), "1")
    assert_equal(out.pegar("m").texto_em(2), "2")
    assert_equal(out.dtype_de("m").codigo, DType.INTEIRO)


def test_m5_hora_em_coluna_data_erra() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    var pegou = False
    try:
        _ = t.com_coluna("h", hora(coluna("data"))).coletar()
    except e:
        pegou = True
        assert_true("datahora" in String(e))
    assert_true(pegou)


def test_m5_filtro_por_datahora() raises:
    var t = ler_csv("tests/fixtures/eventos.csv")
    var out = t.onde(coluna("quando").ge(lit_datahora("2024-02-01T00:00:00"))).coletar()
    assert_equal(out.linhas(), 2)
    assert_equal(out.pegar("id").texto_em(0), "3")


def test_m5_datahora_no_plano() raises:
    var e = coluna("quando").ge(lit_datahora("2024-02-01T00:00:00"))
    assert_equal(
        e.descrever(), '(coluna(quando) >= lit_datahora("2024-02-01T00:00:00"))'
    )


def test_m5_para_csv_cita_quando_precisa() raises:
    var original = ler_csv("tests/fixtures/citado.csv")
    var saida = "tests/fixtures/_saida_citado.csv"
    para_csv(original, saida)
    var de_novo = ler_csv(saida)
    assert_equal(de_novo.linhas(), original.linhas())
    assert_equal(de_novo.pegar("nome").texto_em(0), "Silva, João")
    assert_equal(de_novo.pegar("obs").texto_em(0), 'diz "oi"')
    assert_equal(de_novo.pegar("obs").texto_em(1), "linha um\nlinha dois")


def test_m5_datahora_redondo_no_csv() raises:
    var original = ler_csv("tests/fixtures/eventos.csv")
    var saida = "tests/fixtures/_saida_eventos.csv"
    para_csv(original, saida)
    var de_novo = ler_csv(saida)
    assert_equal(de_novo.dtype_de("quando").codigo, DType.DATAHORA)
    assert_equal(de_novo.pegar("quando").texto_em(2), "2024-02-20T23:59:59.500000")
    assert_equal(de_novo.pegar("valor").contar_ausentes(), 1)


# ------------------------------------------------------- M5: Parquet


def test_pq_thrift_varint_e_zigzag() raises:
    var b = List[UInt8]()
    for v in [UInt8(0xAC), UInt8(0x02), UInt8(0x01), UInt8(0x02), UInt8(0x03)]:
        b.append(v)
    var l = LeitorThrift()
    assert_equal(l.varint(b), 300)
    assert_equal(l.zigzag(b), -1)
    assert_equal(l.zigzag(b), 1)
    assert_equal(l.zigzag(b), -2)


def test_pq_rle_trecho_repetido() raises:
    # cabecalho 0x08 = (4 << 1) -> 4 repeticoes de um valor de 1 bit
    var b = List[UInt8]()
    b.append(UInt8(0x08))
    b.append(UInt8(0x01))
    var r = decodificar_rle(b, 0, len(b), 1, 4)
    assert_equal(len(r), 4)
    for v in r:
        assert_equal(v, 1)


def test_pq_rle_trecho_empacotado() raises:
    # cabecalho 0x03 = (1 << 1) | 1 -> um grupo de 8, largura 1
    # 0b10110101 lido do bit menos significativo: 1,0,1,0,1,1,0,1
    var b = List[UInt8]()
    b.append(UInt8(0x03))
    b.append(UInt8(0b10110101))
    var r = decodificar_rle(b, 0, len(b), 1, 8)
    var esperado = List[Int]()
    for v in [1, 0, 1, 0, 1, 1, 0, 1]:
        esperado.append(v)
    assert_equal(len(r), 8)
    for i in range(8):
        assert_equal(r[i], esperado[i])


def test_pq_rle_i32_ida_e_volta() raises:
    """Encoder hibrido (RLE + bit-packing) bate com o decoder de indices."""
    var vals = List[Int32]()
    for i in range(100):
        vals.append(Int32(i % 24))
    var largura = largura_de_bits(23)
    var enc = codificar_rle_i32(vals, largura)
    var dec = decodificar_rle_i32(enc, 0, len(enc), largura, 100)
    assert_equal(len(dec), 100)
    for i in range(100):
        assert_equal(Int(dec[i]), Int(vals[i]))

    # trecho repetido longo: tem de sair como RLE, nao 8-a-8
    var iguais = List[Int32]()
    for _ in range(40):
        iguais.append(Int32(3))
    var enc2 = codificar_rle_i32(iguais, 3)
    var dec2 = decodificar_rle_i32(enc2, 0, len(enc2), 3, 40)
    assert_equal(len(dec2), 40)
    for v in dec2:
        assert_equal(Int(v), 3)


def test_pq_largura_de_bits() raises:
    assert_equal(largura_de_bits(0), 0)
    assert_equal(largura_de_bits(1), 1)
    assert_equal(largura_de_bits(3), 2)
    assert_equal(largura_de_bits(4), 3)
    assert_equal(largura_de_bits(255), 8)


def test_pq_metadados_sem_ler_dados() raises:
    var m = metadados_parquet("tests/fixtures/simples.parquet")
    assert_equal(m.num_linhas, 5)
    assert_equal(m.num_colunas(), 4)
    assert_equal(len(m.grupos), 1)
    assert_equal(m.coluna_do_esquema(0).nome, "id")
    assert_equal(m.coluna_do_esquema(3).nome, "cidade")
    assert_true(m.versao >= 1)


def test_pq_esquema_do_rodape() raises:
    var e = esquema_parquet("tests/fixtures/simples.parquet")
    assert_equal(e.tamanho(), 4)
    assert_equal(e.dtype_de("id").codigo, DType.INTEIRO)
    assert_equal(e.dtype_de("valor").codigo, DType.REAL)
    assert_equal(e.dtype_de("ativo").codigo, DType.LOGICO)
    assert_equal(e.dtype_de("cidade").codigo, DType.TEXTO)


def test_pq_plain_sem_compressao() raises:
    var t = ler_parquet("tests/fixtures/simples.parquet")
    assert_equal(t.linhas(), 5)
    assert_equal(t.colunas(), 4)
    assert_equal(t.pegar("id").texto_em(0), "1")
    assert_equal(t.pegar("id").texto_em(4), "5")
    assert_equal(t.pegar("valor").texto_em(4), "50.125")
    assert_equal(t.pegar("ativo").texto_em(1), "False")
    assert_equal(t.pegar("cidade").texto_em(3), "BH")
    assert_equal(t.soma("id"), 15.0)


def test_pq_ausentes_por_niveis_de_definicao() raises:
    var t = ler_parquet("tests/fixtures/com_na.parquet")
    assert_equal(t.linhas(), 5)
    assert_equal(t.pegar("id").contar_ausentes(), 2)
    assert_true(t.pegar("id").eh_ausente(1))
    assert_false(t.pegar("id").eh_ausente(2))
    assert_equal(t.pegar("valor").contar_ausentes(), 2)
    assert_true(t.pegar("valor").eh_ausente(4))
    assert_equal(t.pegar("cidade").contar_ausentes(), 2)
    assert_equal(t.pegar("cidade").texto_em(3), "BH")
    # soma ignora ausentes, como em qualquer outra fonte
    assert_equal(t.soma("id"), 9.0)


def test_pq_dicionario_rle() raises:
    var t = ler_parquet("tests/fixtures/dicionario.parquet")
    assert_equal(t.linhas(), 140)
    # padrao SP,RJ,SP,BH,SP,RJ,SP repetido
    assert_equal(t.pegar("cidade").texto_em(0), "SP")
    assert_equal(t.pegar("cidade").texto_em(1), "RJ")
    assert_equal(t.pegar("cidade").texto_em(3), "BH")
    assert_equal(t.pegar("cidade").texto_em(7), "SP")
    assert_equal(t.pegar("n").texto_em(139), "139")
    # e ja chega dicionarizada do lado do Tucano
    assert_true(t.pegar("cidade").eh_dicionarizada())
    assert_equal(t.pegar("cidade").cardinalidade(), 3)


def test_pq_temporais() raises:
    var t = ler_parquet("tests/fixtures/temporal.parquet")
    assert_equal(t.dtype_de("quando").codigo, DType.DATA)
    assert_equal(t.dtype_de("carimbo").codigo, DType.DATAHORA)
    assert_equal(t.pegar("quando").texto_em(0), "2024-01-15")
    assert_equal(t.pegar("quando").texto_em(1), "2024-02-29")
    assert_equal(t.pegar("carimbo").texto_em(0), "2024-01-15T08:30:00")
    assert_equal(t.pegar("carimbo").texto_em(1), "2024-02-29T23:59:59.500000")
    # anterior a epoca: o sinal tem de sobreviver a viagem
    assert_equal(t.pegar("carimbo").texto_em(2), "1969-12-31T23:59:59")


def test_pq_snappy() raises:
    var t = ler_parquet("tests/fixtures/snappy.parquet")
    var sem = ler_parquet("tests/fixtures/simples.parquet")
    assert_equal(t.linhas(), sem.linhas())
    for i in range(t.linhas()):
        assert_equal(t.pegar("id").texto_em(i), sem.pegar("id").texto_em(i))
        assert_equal(t.pegar("valor").texto_em(i), sem.pegar("valor").texto_em(i))
        assert_equal(t.pegar("cidade").texto_em(i), sem.pegar("cidade").texto_em(i))


def test_pq_multiplos_row_groups() raises:
    var m = metadados_parquet("tests/fixtures/grupos.parquet")
    assert_equal(len(m.grupos), 3)
    var t = ler_parquet("tests/fixtures/grupos.parquet")
    assert_equal(t.linhas(), 3000)
    # as fronteiras entre grupos sao onde a montagem costuma errar
    assert_equal(t.pegar("id").texto_em(999), "999")
    assert_equal(t.pegar("id").texto_em(1000), "1000")
    assert_equal(t.pegar("id").texto_em(2999), "2999")
    assert_equal(t.pegar("grupo").texto_em(0), "a")
    assert_equal(t.pegar("grupo").texto_em(1000), "b")
    assert_equal(t.pegar("valor").texto_em(2), "1.0")


def test_pq_column_pruning() raises:
    var so_id = List[String]()
    so_id.append("valor")
    so_id.append("id")
    var t = ler_parquet("tests/fixtures/simples.parquet", so_id)
    assert_equal(t.colunas(), 2)
    # a ordem pedida e respeitada
    assert_equal(t.nomes()[0], "valor")
    assert_equal(t.nomes()[1], "id")
    assert_equal(t.linhas(), 5)
    assert_equal(t.soma("id"), 15.0)


def test_pq_coluna_inexistente_sugere() raises:
    var nomes = List[String]()
    nomes.append("cidadee")
    var pegou = False
    try:
        _ = ler_parquet("tests/fixtures/simples.parquet", nomes)
    except e:
        pegou = True
        assert_true("Voce quis dizer 'cidade'" in String(e))
    assert_true(pegou)


def test_pq_arquivo_invalido_erra() raises:
    var pegou = False
    try:
        _ = ler_parquet("tests/fixtures/pessoas.csv")
    except e:
        pegou = True
        assert_true("PAR1" in String(e))
    assert_true(pegou)


def test_pq_alimenta_o_executor() raises:
    """Parquet e so mais uma fonte: o plano nao sabe de onde vieram os dados."""
    var t = ler_parquet("tests/fixtures/grupos.parquet")
    var q = (
        t.com_coluna("dobro", coluna("valor").vezes(lit(2.0)))
        .onde(coluna("grupo").eq(lit_texto("a")))
        .selecionar(["id", "grupo", "dobro"])
    )
    assert_equal(q.linhas(), 1000)
    assert_equal(q.esquema_previsto().dtype_de("dobro").codigo, DType.REAL)


def test_pq_escrita_ida_e_volta() raises:
    var original = ler_parquet("tests/fixtures/simples.parquet")
    var saida = "tests/fixtures/_saida_simples.parquet"
    para_parquet(original, saida)
    var volta = ler_parquet(saida)
    assert_equal(volta.linhas(), 5)
    assert_equal(volta.colunas(), 4)
    assert_equal(volta.nomes(), original.nomes())
    for i in range(5):
        assert_equal(volta.pegar("id").texto_em(i), original.pegar("id").texto_em(i))
        assert_equal(
            volta.pegar("valor").texto_em(i), original.pegar("valor").texto_em(i)
        )
        assert_equal(
            volta.pegar("ativo").texto_em(i), original.pegar("ativo").texto_em(i)
        )
        assert_equal(
            volta.pegar("cidade").texto_em(i), original.pegar("cidade").texto_em(i)
        )


def test_pq_escrita_preserva_ausentes() raises:
    var original = ler_parquet("tests/fixtures/com_na.parquet")
    var saida = "tests/fixtures/_saida_com_na.parquet"
    para_parquet(original, saida)
    var volta = ler_parquet(saida)
    assert_equal(volta.pegar("id").contar_ausentes(), 2)
    assert_true(volta.pegar("id").eh_ausente(1))
    assert_true(volta.pegar("id").eh_ausente(3))
    assert_equal(volta.pegar("cidade").texto_em(0), "SP")
    assert_true(volta.pegar("cidade").eh_ausente(4))
    assert_equal(volta.soma("id"), 9.0)


def test_pq_escrita_preserva_temporais() raises:
    var original = ler_parquet("tests/fixtures/temporal.parquet")
    var saida = "tests/fixtures/_saida_temporal.parquet"
    para_parquet(original, saida)
    var volta = ler_parquet(saida)
    assert_equal(volta.dtype_de("quando").codigo, DType.DATA)
    assert_equal(volta.dtype_de("carimbo").codigo, DType.DATAHORA)
    assert_equal(volta.pegar("quando").texto_em(1), "2024-02-29")
    assert_equal(volta.pegar("carimbo").texto_em(1), "2024-02-29T23:59:59.500000")
    assert_equal(volta.pegar("carimbo").texto_em(2), "1969-12-31T23:59:59")


def test_pq_escrita_de_tabela_csv() raises:
    """CSV entra, Parquet sai: o formato e detalhe do operador de leitura."""
    var t = ler_csv("tests/fixtures/eventos.csv")
    var saida = "tests/fixtures/_saida_eventos.parquet"
    para_parquet(t, saida)
    var volta = ler_parquet(saida)
    assert_equal(volta.linhas(), 4)
    assert_equal(volta.dtype_de("quando").codigo, DType.DATAHORA)
    assert_equal(volta.pegar("quando").texto_em(0), "2024-01-15T08:30:00")
    assert_equal(volta.pegar("tipo").texto_em(1), "compra")
    assert_equal(volta.pegar("valor").contar_ausentes(), 1)


def test_pq_escrita_volume() raises:
    var original = ler_parquet("tests/fixtures/grupos.parquet")
    var saida = "tests/fixtures/_saida_grupos.parquet"
    para_parquet(original, saida)
    var volta = ler_parquet(saida)
    assert_equal(volta.linhas(), 3000)
    assert_equal(volta.pegar("id").texto_em(2999), "2999")
    assert_equal(volta.pegar("grupo").texto_em(1000), "b")
    assert_equal(volta.soma("id"), original.soma("id"))


def test_pq_escrita_emite_dicionario() raises:
    """Texto repetido sai em RLE_DICTIONARY, nao 3 mil copias PLAIN."""
    var original = ler_parquet("tests/fixtures/grupos.parquet")
    var saida = "tests/fixtures/_saida_dic.parquet"
    para_parquet(original, saida)
    var m = metadados_parquet(saida)
    var achou_grupo = False
    var achou_id = False
    for c in range(m.num_colunas()):
        var nome = m.coluna_do_esquema(c).nome
        if nome == "grupo":
            assert_true(m.grupos[0].colunas[c].tem_dicionario())
            achou_grupo = True
        if nome == "id":
            assert_false(m.grupos[0].colunas[c].tem_dicionario())
            achou_id = True
    assert_true(achou_grupo)
    assert_true(achou_id)
    var volta = ler_parquet(saida)
    assert_true(volta.pegar("grupo").eh_dicionarizada())
    assert_equal(volta.pegar("grupo").texto_em(0), original.pegar("grupo").texto_em(0))
    assert_equal(volta.pegar("grupo").texto_em(1000), original.pegar("grupo").texto_em(1000))
    assert_equal(volta.pegar("id").texto_em(2999), "2999")


def test_pq_escrita_emite_min_max() raises:
    """Cada row group numerico sai com min/max no rodape."""
    var ids = List[Int64](capacity=300)
    var vals = List[Float64](capacity=300)
    for i in range(300):
        ids.append(Int64(i))
        vals.append(Float64(i))
    var cols = List[Coluna]()
    cols.append(Coluna.de_inteiros("id", ids^))
    cols.append(Coluna.de_reais("valor", vals^))
    var t = Tabela(cols^)
    var saida = "tests/fixtures/_saida_stats.parquet"
    para_parquet(t, saida, 100)

    var m = metadados_parquet(saida)
    assert_equal(len(m.grupos), 3)
    var c_id = 0
    var c_valor = 1
    for g in range(3):
        assert_true(m.grupos[g].colunas[c_id].tem_min_max)
        assert_true(m.grupos[g].colunas[c_valor].tem_min_max)
        var base = g * 100
        assert_equal(m.grupos[g].colunas[c_id].min_int(), base)
        assert_equal(m.grupos[g].colunas[c_id].max_int(), base + 99)
        assert_equal(m.grupos[g].colunas[c_valor].min_f64(), Float64(base))
        assert_equal(m.grupos[g].colunas[c_valor].max_f64(), Float64(base + 99))


def test_pq_escrita_emite_distinct_count() raises:
    """Texto dicionarizado grava o NDV do row group, nao o do dicionario herdado."""
    var grupos = List[String](capacity=300)
    var ids = List[Int64](capacity=300)
    for i in range(300):
        if i < 100:
            grupos.append("a")
        elif i < 200:
            grupos.append("b")
        else:
            grupos.append("c")
        ids.append(Int64(i))
    var cols = List[Coluna]()
    cols.append(Coluna.de_textos("grupo", grupos^))
    cols.append(Coluna.de_inteiros("id", ids^))
    var t = Tabela(cols^)
    assert_true(t.pegar("grupo").eh_dicionarizada())
    assert_equal(t.pegar("grupo").cardinalidade(), 3)
    var saida = "tests/fixtures/_saida_ndv.parquet"
    para_parquet(t, saida, 100)

    var m = metadados_parquet(saida)
    assert_equal(len(m.grupos), 3)
    var c_grupo = 0
    var c_id = 1
    for g in range(3):
        assert_true(m.grupos[g].colunas[c_grupo].tem_distintos())
        assert_equal(m.grupos[g].colunas[c_grupo].n_distintos, 1)
        assert_false(m.grupos[g].colunas[c_id].tem_distintos())
        assert_equal(m.grupos[g].colunas[c_id].n_distintos, -1)

    var um = "tests/fixtures/_saida_ndv_um.parquet"
    para_parquet(t, um)
    var m1 = metadados_parquet(um)
    assert_equal(len(m1.grupos), 1)
    assert_equal(m1.grupos[0].colunas[c_grupo].n_distintos, 3)


def test_pq_predicate_pushdown_pula_grupo() raises:
    """Filtro que nenhum valor do grupo pode satisfazer nao le o grupo."""
    var ids = List[Int64](capacity=300)
    var vals = List[Float64](capacity=300)
    for i in range(300):
        ids.append(Int64(i))
        vals.append(Float64(i))
    var cols = List[Coluna]()
    cols.append(Coluna.de_inteiros("id", ids^))
    cols.append(Coluna.de_reais("valor", vals^))
    var t = Tabela(cols^)
    var saida = "tests/fixtures/_saida_pushdown.parquet"
    para_parquet(t, saida, 100)
    var m = metadados_parquet(saida)

    # grupo 0: 0-99, grupo 1: 100-199, grupo 2: 200-299
    assert_equal(n_grupos_possiveis(m, coluna("valor").gt(lit(150.0))), 2)
    assert_equal(n_grupos_possiveis(m, coluna("valor").gt(lit(99.0))), 2)
    assert_equal(n_grupos_possiveis(m, coluna("id").gt(lit_int(99))), 2)
    assert_equal(n_grupos_possiveis(m, coluna("valor").eq(lit(150.0))), 1)
    assert_equal(
        n_grupos_possiveis(
            m, coluna("valor").lt(lit(10.0)).ou(coluna("valor").gt(lit(250.0)))
        ),
        2,
    )
    # o do meio: min=100 max=199 — nenhum dos dois lados do OU
    assert_true(
        grupo_impossivel(
            m.grupos[1],
            coluna("valor").lt(lit(10.0)).ou(coluna("valor").gt(lit(250.0))),
        )
    )
    # sem estatistica util (texto) ou predicado complexo: nao pula
    assert_equal(n_grupos_possiveis(m, coluna("valor").vezes(lit(2.0)).gt(lit(10.0))), 3)

    var q = varredura_parquet(saida).onde(coluna("valor").gt(lit(150.0)))
    var r = q.coletar()
    assert_equal(r.linhas(), 149)  # 151..299
    assert_equal(r.pegar("id").texto_em(0), "151")
    assert_equal(r.pegar("id").texto_em(148), "299")

    var vazio = (
        varredura_parquet(saida).onde(coluna("valor").gt(lit(1000.0))).coletar()
    )
    assert_equal(vazio.linhas(), 0)

    var aggs = List[Agregacao]()
    aggs.append(soma("valor"))
    var fluindo = (
        varredura_parquet(saida)
        .onde(coluna("valor").gt(lit(150.0)))
        .agregar_total(aggs^)
        .coletar_em_fluxo()
    )
    # 151+...+299 = (149 * (151+299)) / 2
    assert_equal(fluindo.linhas(), 1)
    assert_equal(fluindo.soma("soma_valor"), 33525.0)


# ------------------------------------------------------------------ M6


def _tabela_cidades() raises -> Tabela:
    var cols = List[Coluna]()
    cols.append(Coluna.de_textos("cidade", ["SP", "RJ", "POA"]))
    cols.append(Coluna.de_textos("estado", ["SP", "RJ", "RS"]))
    cols.append(Coluna.de_inteiros("populacao", [Int64(12), Int64(6), Int64(1)]))
    return Tabela(cols^)


def test_m6_grupos_por_dicionario_sem_hash() raises:
    """Chave de texto dicionarizada vira indexacao direta — o retorno do M4."""
    var t = ler_csv("tests/fixtures/vendas.csv")
    var chaves = List[String]()
    chaves.append("cidade")
    var g = calcular_grupos(t.lote(), chaves)
    assert_equal(g.caminho, "indexacao direta")
    assert_equal(g.n_grupos, 3)
    assert_equal(len(g.ids), 5)
    assert_equal(g.ids[0], g.ids[2])  # SP e SP
    assert_true(g.ids[0] != g.ids[1])


def test_m6_grupos_por_inteiro() raises:
    var cols = List[Coluna]()
    cols.append(Coluna.de_inteiros("k", [Int64(1), Int64(2), Int64(1), Int64(3)]))
    var t = Tabela(cols^)
    var chaves = List[String]()
    chaves.append("k")
    var g = calcular_grupos(t.lote(), chaves)
    assert_equal(g.caminho, "hash de inteiros")
    assert_equal(g.n_grupos, 3)
    assert_equal(g.ids[0], g.ids[2])


def test_m6_grupos_por_chave_composta() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    var chaves = List[String]()
    chaves.append("cidade")
    chaves.append("data")
    var g = calcular_grupos(t.lote(), chaves)
    assert_equal(g.caminho, "hash de chave composta")
    assert_equal(g.n_grupos, 5)


def test_m6_agrupar_soma_media_contagem() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    var aggs = List[Agregacao]()
    aggs.append(soma("valor"))
    aggs.append(media("valor"))
    aggs.append(contar())
    var chaves = List[String]()
    chaves.append("cidade")
    var r = t.agrupar(chaves).agregar(aggs^).coletar()

    assert_equal(r.linhas(), 3)
    assert_equal(r.colunas(), 4)
    assert_equal(r.nomes()[1], "soma_valor")
    assert_equal(r.pegar("cidade").texto_em(0), "SP")
    assert_equal(r.pegar("soma_valor").texto_em(0), "4700.0")
    assert_equal(r.pegar("contagem").texto_em(0), "3")
    assert_equal(r.pegar("soma_valor").texto_em(1), "800.0")


def test_m6_grupo_sem_valor_valido_e_ausente() raises:
    """Somar nada nao da zero: da desconhecido."""
    var t = ler_csv("tests/fixtures/vendas.csv")
    var aggs = List[Agregacao]()
    aggs.append(soma("valor"))
    aggs.append(media("valor"))
    aggs.append(contar())
    aggs.append(contar_de("valor"))
    var chaves = List[String]()
    chaves.append("cidade")
    var r = t.agrupar(chaves).agregar(aggs^).coletar()
    # BH so tem a linha com valor ausente
    assert_equal(r.pegar("cidade").texto_em(2), "BH")
    assert_true(r.pegar("soma_valor").eh_ausente(2))
    assert_true(r.pegar("media_valor").eh_ausente(2))
    assert_equal(r.pegar("contagem").texto_em(2), "1")  # linhas
    assert_equal(r.pegar("contagem_valor").texto_em(2), "0")  # valores presentes


def test_m6_coluna_sem_valores_validos_erra_na_soma() raises:
    var c = Coluna.de_reais("x", [1.0, 2.0], [True, True])
    var pegou = False
    try:
        _ = c.soma()
    except e:
        pegou = True
        assert_true("sem valores validos" in String(e))
    assert_true(pegou)


def test_m6_agregacoes_preservam_tipo() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    var aggs = List[Agregacao]()
    aggs.append(maximo("data"))
    aggs.append(minimo("data"))
    aggs.append(primeiro("cidade"))
    aggs.append(distintos("cidade"))
    var chaves = List[String]()
    chaves.append("cidade")
    var q = t.agrupar(chaves).agregar(aggs^)
    var esperado = q.esquema_previsto()
    assert_equal(esperado.dtype_de("maximo_data").codigo, DType.DATA)
    assert_equal(esperado.dtype_de("primeiro_cidade").codigo, DType.TEXTO)
    assert_equal(esperado.dtype_de("distintos_cidade").codigo, DType.INTEIRO)

    var r = q.coletar()
    assert_equal(r.dtype_de("maximo_data").codigo, DType.DATA)
    assert_equal(r.pegar("maximo_data").texto_em(0), "2024-03-10")
    assert_equal(r.pegar("minimo_data").texto_em(0), "2024-01-15")
    assert_equal(r.pegar("distintos_cidade").texto_em(0), "1")


def test_m6_agregacao_renomeada() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    var aggs = List[Agregacao]()
    aggs.append(soma("valor").como("faturamento"))
    var chaves = List[String]()
    chaves.append("cidade")
    var r = t.agrupar(chaves).agregar(aggs^).coletar()
    assert_true(r.schema().contem("faturamento"))
    assert_equal(r.pegar("faturamento").texto_em(0), "4700.0")


def test_m6_agrupar_sem_agregar_erra() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    var chaves = List[String]()
    chaves.append("cidade")
    var pegou = False
    try:
        _ = t.agrupar(chaves).coletar()
    except e:
        pegou = True
        assert_true("agrupar sem agregar" in String(e))
    assert_true(pegou)


def test_m6_juncao_interna() raises:
    var v = ler_csv("tests/fixtures/vendas.csv")
    var c = _tabela_cidades()
    var por = List[String]()
    por.append("cidade")
    var r = v.unir(c, por).coletar()
    # BH nao existe na direita e sai; POA nao existe na esquerda e nao entra
    assert_equal(r.linhas(), 4)
    assert_equal(r.colunas(), 5)
    assert_equal(r.pegar("estado").texto_em(0), "SP")
    assert_equal(r.pegar("populacao").texto_em(1), "6")


def test_m6_juncao_a_esquerda() raises:
    var v = ler_csv("tests/fixtures/vendas.csv")
    var c = _tabela_cidades()
    var por = List[String]()
    por.append("cidade")
    var r = v.unir(c, por, "esquerda").coletar()
    assert_equal(r.linhas(), 5)
    assert_equal(r.pegar("cidade").texto_em(3), "BH")
    assert_true(r.pegar("estado").eh_ausente(3))
    assert_true(r.pegar("populacao").eh_ausente(3))


def test_m8_juncao_interna_hasheia_o_menor() raises:
    """Interna hasheia o lado mais barato; o conjunto do resultado nao muda."""
    var esq_k = List[String]()
    var esq_x = List[Int64]()
    esq_k.append("a")
    esq_k.append("b")
    esq_x.append(Int64(1))
    esq_x.append(Int64(2))
    var cols_e = List[Coluna]()
    cols_e.append(Coluna.de_textos("k", esq_k^))
    cols_e.append(Coluna.de_inteiros("x", esq_x^))
    var pequena = Tabela(cols_e^)

    var dir_k = List[String]()
    var dir_y = List[Int64]()
    for i in range(20):
        if i % 3 == 0:
            dir_k.append("a")
        elif i % 3 == 1:
            dir_k.append("b")
        else:
            dir_k.append("c")
        dir_y.append(Int64(i))
    var cols_d = List[Coluna]()
    cols_d.append(Coluna.de_textos("k", dir_k^))
    cols_d.append(Coluna.de_inteiros("y", dir_y^))
    var grande = Tabela(cols_d^)

    var por = List[String]()
    por.append("k")
    var ord_ky = List[String]()
    ord_ky.append("k")
    ord_ky.append("y")
    var r1 = pequena.unir(grande, por).ordenar(ord_ky).coletar()
    var r2 = grande.unir(pequena, por).ordenar(ord_ky).coletar()
    assert_equal(r1.linhas(), 14)
    assert_equal(r2.linhas(), 14)
    assert_equal(r1.pegar("k").texto_em(0), "a")
    assert_equal(r1.pegar("x").texto_em(0), "1")
    assert_equal(r1.pegar("y").texto_em(0), "0")
    for i in range(r1.linhas()):
        assert_equal(r1.pegar("k").texto_em(i), r2.pegar("k").texto_em(i))
        assert_equal(r1.pegar("x").texto_em(i), r2.pegar("x").texto_em(i))
        assert_equal(r1.pegar("y").texto_em(i), r2.pegar("y").texto_em(i))

    # muitas linhas, pouca cardinalidade: o custo e o NDV, nao o n
    var fat_k = List[String](capacity=80)
    var fat_x = List[Int64](capacity=80)
    for i in range(80):
        if i % 2 == 0:
            fat_k.append("SP")
        else:
            fat_k.append("RJ")
        fat_x.append(Int64(i))
    var cols_f = List[Coluna]()
    cols_f.append(Coluna.de_textos("k", fat_k^))
    cols_f.append(Coluna.de_inteiros("x", fat_x^))
    var fatia = Tabela(cols_f^)
    assert_true(fatia.pegar("k").eh_dicionarizada())
    assert_equal(fatia.pegar("k").cardinalidade(), 2)

    var dim_k = List[String]()
    var dim_y = List[Int64]()
    dim_k.append("SP")
    dim_k.append("RJ")
    dim_k.append("BH")
    dim_y.append(Int64(10))
    dim_y.append(Int64(20))
    dim_y.append(Int64(30))
    var cols_dim = List[Coluna]()
    cols_dim.append(Coluna.de_textos("k", dim_k^))
    cols_dim.append(Coluna.de_inteiros("y", dim_y^))
    var dim = Tabela(cols_dim^)
    var r3 = fatia.unir(dim, por).coletar()
    assert_equal(r3.linhas(), 80)


def test_m8_juncao_esquerda_nao_inverte() raises:
    """Juncao a esquerda sonda a esquerda: linha sem par sobrevive."""
    var esq_k = List[String]()
    var esq_x = List[Int64]()
    esq_k.append("a")
    esq_k.append("z")
    esq_x.append(Int64(1))
    esq_x.append(Int64(2))
    var cols_e = List[Coluna]()
    cols_e.append(Coluna.de_textos("k", esq_k^))
    cols_e.append(Coluna.de_inteiros("x", esq_x^))
    var pequena = Tabela(cols_e^)

    var dir_k = List[String]()
    var dir_y = List[Int64]()
    for i in range(12):
        dir_k.append("a")
        dir_y.append(Int64(i))
    var cols_d = List[Coluna]()
    cols_d.append(Coluna.de_textos("k", dir_k^))
    cols_d.append(Coluna.de_inteiros("y", dir_y^))
    var grande = Tabela(cols_d^)

    var por = List[String]()
    por.append("k")
    var r = pequena.unir(grande, por, "esquerda").coletar()
    assert_equal(r.linhas(), 13)
    var viu_z = False
    var ausentes = 0
    for i in range(r.linhas()):
        if r.pegar("k").texto_em(i) == "z":
            viu_z = True
            assert_true(r.pegar("y").eh_ausente(i))
            assert_equal(r.pegar("x").texto_em(i), "2")
            ausentes += 1
    assert_true(viu_z)
    assert_equal(ausentes, 1)


def test_m6_juncao_chave_ausente_nao_casa() raises:
    """Ausente nao e um valor: nao casa nem com outro ausente."""
    var esq = List[Coluna]()
    esq.append(Coluna.de_textos("k", ["a", ""], [False, True]))
    esq.append(Coluna.de_inteiros("x", [Int64(1), Int64(2)]))
    var dir = List[Coluna]()
    dir.append(Coluna.de_textos("k", ["a", ""], [False, True]))
    dir.append(Coluna.de_inteiros("y", [Int64(10), Int64(20)]))
    var por = List[String]()
    por.append("k")
    var r = Tabela(esq^).unir(Tabela(dir^), por).coletar()
    assert_equal(r.linhas(), 1)
    assert_equal(r.pegar("k").texto_em(0), "a")


def test_m6_juncao_nome_repetido_erra() raises:
    var v = ler_csv("tests/fixtures/vendas.csv")
    var cols = List[Coluna]()
    cols.append(Coluna.de_textos("cidade", ["SP"]))
    cols.append(Coluna.de_reais("valor", [1.0]))
    var por = List[String]()
    por.append("cidade")
    var pegou = False
    try:
        _ = v.unir(Tabela(cols^), por).coletar()
    except e:
        pegou = True
        assert_true("existe nos dois lados" in String(e))
    assert_true(pegou)


def test_m6_tipo_de_juncao_invalido_erra() raises:
    var pegou = False
    try:
        _ = TipoJuncao.de_texto("cruzada")
    except e:
        pegou = True
        assert_true("interno" in String(e))
    assert_true(pegou)


def test_m6_ordenar() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    var por = List[String]()
    por.append("valor")
    var asc = t.ordenar(por).coletar()
    assert_equal(asc.pegar("valor").texto_em(0), "800.0")
    # ausente vai para o fim nas duas direcoes
    assert_true(asc.pegar("valor").eh_ausente(4))
    var desc = t.ordenar(por, True).coletar()
    assert_equal(desc.pegar("valor").texto_em(0), "2000.0")
    assert_true(desc.pegar("valor").eh_ausente(4))


def test_m6_ordenacao_estavel_permite_direcoes_mistas() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    var por_valor = List[String]()
    por_valor.append("valor")
    var por_cidade = List[String]()
    por_cidade.append("cidade")
    var r = t.ordenar(por_valor, True).ordenar(por_cidade).coletar()
    assert_equal(r.pegar("cidade").texto_em(0), "BH")
    assert_equal(r.pegar("cidade").texto_em(2), "SP")
    # dentro de SP, valor decrescente
    assert_equal(r.pegar("valor").texto_em(2), "2000.0")
    assert_equal(r.pegar("valor").texto_em(3), "1500.0")
    assert_equal(r.pegar("valor").texto_em(4), "1200.0")


def test_m6_concatenar() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    var r = t.concatenar(t).coletar()
    assert_equal(r.linhas(), 10)
    assert_equal(r.pegar("cidade").texto_em(5), "SP")
    assert_equal(r.pegar("valor").contar_ausentes(), 2)


def test_m6_concatenar_esquema_diferente_erra() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    var outro = ler_csv("tests/fixtures/pessoas.csv")
    var pegou = False
    try:
        _ = t.concatenar(outro).coletar()
    except e:
        pegou = True
        assert_true("concatenar" in String(e))
    assert_true(pegou)


def test_m6_remover_na() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    assert_equal(t.remover_na().linhas(), 4)
    var so_cidade = List[String]()
    so_cidade.append("cidade")
    assert_equal(t.remover_na(so_cidade).linhas(), 5)


def test_m6_preencher_na() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    var r = t.preencher_na("valor", lit(0.0)).coletar()
    assert_equal(r.pegar("valor").contar_ausentes(), 0)
    assert_equal(r.pegar("valor").texto_em(3), "0.0")
    assert_equal(r.soma("valor"), 5500.0)


def test_m6_preencher_na_sem_conversao_implicita() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    var pegou = False
    try:
        _ = t.preencher_na("valor", lit_texto("zero")).coletar()
    except e:
        pegou = True
        assert_true("texto" in String(e))
    assert_true(pegou)


def test_m6_contar_valores() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    var r = t.contar_valores("cidade")
    assert_equal(r.linhas(), 3)
    assert_equal(r.colunas(), 2)
    assert_equal(r.pegar("cidade").texto_em(0), "SP")
    assert_equal(r.pegar("contagem").texto_em(0), "3")


def test_m6_unicos() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    var r = t.unicos("cidade")
    assert_equal(r.linhas(), 3)
    assert_equal(r.colunas(), 1)
    assert_equal(r.pegar("cidade").texto_em(0), "SP")


def test_m6_resumo() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    var r = t.resumo()
    assert_equal(r.linhas(), 3)
    assert_equal(r.pegar("coluna").texto_em(2), "valor")
    assert_equal(r.pegar("tipo").texto_em(2), "real")
    assert_equal(r.pegar("validos").texto_em(2), "4")
    assert_equal(r.pegar("ausentes").texto_em(2), "1")
    assert_equal(r.pegar("media").texto_em(2), "1375.0")
    # colunas nao numericas nao ganham estatistica inventada
    assert_true(r.pegar("media").eh_ausente(0))
    assert_true(r.pegar("maximo").eh_ausente(1))


def test_m6_plano_completo() raises:
    var v = ler_csv("tests/fixtures/vendas.csv")
    var c = _tabela_cidades()
    var por = List[String]()
    por.append("cidade")
    var chaves = List[String]()
    chaves.append("estado")
    var aggs = List[Agregacao]()
    aggs.append(soma("valor"))
    var ordem = List[String]()
    ordem.append("soma_valor")

    var q = (
        v.unir(c, por, "esquerda")
        .remover_na(por)
        .agrupar(chaves)
        .agregar(aggs^)
        .ordenar(ordem, True)
    )
    var plano = q.descrever()
    assert_true("JOIN esquerda por [cidade]" in plano)
    assert_true("DROP NULLS" in plano)
    assert_true("AGGREGATE [estado]" in plano)
    assert_true("SORT [soma_valor desc]" in plano)

    var fisico = q.descrever_fisico()
    assert_true("HashJoinExec" in fisico)
    assert_true("HashAggregateExec" in fisico)
    assert_true("SortExec" in fisico)

    var r = q.coletar()
    assert_equal(r.pegar("estado").texto_em(0), "SP")
    assert_equal(r.pegar("soma_valor").texto_em(0), "4700.0")


# ------------------------------------------------------------------ M7


def _painel_de_vendas() raises -> Painel:
    var v = (
        ler_csv("tests/fixtures/vendas.csv")
        .com_coluna("mes", mes(coluna("data")))
        .coletar()
    )
    var p = Painel("Vendas", v)
    p.kpi("Faturamento", soma("valor"))
    p.kpi("Pedidos", contar())
    p.grafico("Por cidade", "cidade", soma("valor"), "barra")
    var cols = List[String]()
    cols.append("data")
    cols.append("cidade")
    cols.append("valor")
    p.tabela("Detalhe", cols, 3)
    p.filtro("cidade")
    return p^


def test_m7_json_escapa_corretamente() raises:
    assert_equal(escapar("simples"), '"simples"')
    assert_equal(escapar('diz "oi"'), '"diz \\"oi\\""')
    assert_equal(escapar("a\nb"), '"a\\nb"')
    assert_equal(escapar("a\\b"), '"a\\\\b"')
    # acentos passam intactos: JSON e UTF-8
    assert_equal(escapar("São Paulo"), '"São Paulo"')


def test_m7_json_ausente_vira_null() raises:
    """Ausente nao pode virar zero nem string vazia na serializacao."""
    var t = ler_csv("tests/fixtures/vendas.csv")
    var j = tabela_para_json(t)
    assert_true('"valor":null' in j)
    assert_true('"cidade":"BH"' in j)
    assert_false('"valor":0.0,"cidade":"BH"' in j)


def test_m7_json_lista() raises:
    var l = List[String]()
    l.append("a")
    l.append('b"c')
    assert_equal(lista_para_json(l), '["a","b\\"c"]')


def test_m7_url_decodificada() raises:
    assert_equal(decodificar_url("S%C3%A3o+Paulo"), "São Paulo")
    assert_equal(decodificar_url("sem-escape"), "sem-escape")
    assert_equal(decodificar_url("a%2Bb"), "a+b")


def test_m7_parametros_de_consulta() raises:
    var ps = parametros("cidade=SP&ano=2024")
    assert_equal(len(ps), 4)
    assert_equal(ps[0], "cidade")
    assert_equal(ps[1], "SP")
    assert_equal(ps[2], "ano")
    assert_equal(ps[3], "2024")
    assert_equal(len(parametros("")), 0)
    var vazio = parametros("cidade=")
    assert_equal(vazio[1], "")


def test_m7_pagina_embutida() raises:
    var html = pagina("Meu Painel")
    assert_true("<title>Meu Painel</title>" in html)
    assert_true("<h1>Meu Painel</h1>" in html)
    # sem CDN: o painel roda sem rede
    assert_false("http://" in html)
    assert_false("https://" in html)
    assert_true("svgBarras" in html)


def test_m7_descricao_do_painel() raises:
    var p = _painel_de_vendas()
    var j = p.json_painel()
    assert_true('"titulo":"Vendas"' in j)
    assert_true('"coluna":"cidade"' in j)
    # as opcoes do filtro saem dos dados, nao de configuracao
    assert_true('"SP"' in j)
    assert_true('"BH"' in j)


def test_m7_dados_sem_filtro() raises:
    var p = _painel_de_vendas()
    var j = p.json_dados("")
    assert_true('"titulo":"Faturamento","tipo":"kpi","valor":5500.0' in j)
    assert_true('"titulo":"Pedidos","tipo":"kpi","valor":5' in j)
    assert_true('"linhas_fonte":5' in j)
    assert_true('"linhas_filtradas":5' in j)


def test_m7_filtro_muda_o_plano_e_o_resultado() raises:
    """O widget guarda uma consulta: o filtro reexecuta, nao recorta no cliente."""
    var p = _painel_de_vendas()
    var j = p.json_dados("cidade=SP")
    assert_true('"tipo":"kpi","valor":4700.0' in j)
    assert_true('"titulo":"Pedidos","tipo":"kpi","valor":3' in j)
    assert_true('"linhas_fonte":5' in j)
    assert_true('"linhas_filtradas":3' in j)
    # o grafico so tem SP
    assert_true('"pontos":[{"x":"SP","y":4700.0}]' in j)


def test_m7_so_o_agregado_atravessa() raises:
    """A resposta e proporcional ao agregado, nao ao tamanho da fonte."""
    var v = ler_parquet("tests/fixtures/grupos.parquet")
    var p = Painel("Grande", v)
    p.kpi("Total", soma("valor"))
    p.grafico("Por grupo", "grupo", soma("valor"), "barra")
    var j = p.json_dados("")
    assert_true('"linhas_fonte":3000' in j)
    # 3000 linhas na fonte, resposta na casa das centenas de bytes
    assert_true(j.byte_length() < 400)


def test_m7_tabela_respeita_o_limite() raises:
    var p = _painel_de_vendas()
    var j = p.json_dados("")
    # limite 3 na fixture de 5 linhas
    assert_true('"2024-02-28"' in j)
    assert_false('"2024-03-10","cidade"' in j)


def test_m7_filtro_em_coluna_inexistente_erra() raises:
    var v = ler_csv("tests/fixtures/vendas.csv")
    var p = Painel("X", v)
    var pegou = False
    try:
        p.filtro("cidadee")
    except e:
        pegou = True
        assert_true("Voce quis dizer 'cidade'" in String(e))
    assert_true(pegou)


def test_m7_filtro_desconhecido_e_ignorado() raises:
    """Parametro que nao corresponde a um filtro declarado nao vira predicado."""
    var p = _painel_de_vendas()
    var j = p.json_dados("qualquer=coisa")
    assert_true('"linhas_filtradas":5' in j)


# ------------------------------------------------------------------ M8


def test_m8_dobra_de_constantes() raises:
    var e = coluna("v").vezes(lit(2.0).vezes(lit(3.0)))
    var d = dobrar_constantes(e)
    assert_equal(d.descrever(), "(coluna(v) * lit(6.0))")

    # inteiro com inteiro continua inteiro
    var i = lit_int(2).mais(lit_int(5))
    assert_equal(dobrar_constantes(i).descrever(), "lit(7)")

    # comparacao entre literais vira booleano
    var c = lit(3.0).gt(lit(1.0))
    assert_equal(dobrar_constantes(c).descrever(), "lit(True)")

    # com coluna dentro, nao dobra
    var m = coluna("a").mais(coluna("b"))
    assert_equal(dobrar_constantes(m).descrever(), "(coluna(a) + coluna(b))")


def test_m8_dobra_nao_divide_por_zero() raises:
    var e = lit(1.0).sobre(lit(0.0))
    # deixa como esta em vez de produzir infinito em tempo de plano
    assert_equal(dobrar_constantes(e).descrever(), "(lit(1.0) / lit(0.0))")


def test_m8_colunas_da_expr() raises:
    var e = coluna("a").gt(lit(1.0)).e(coluna("b").eq(coluna("a")))
    var out = List[String]()
    colunas_da_expr(e, e.root, out)
    assert_equal(len(out), 2)
    assert_equal(out[0], "a")
    assert_equal(out[1], "b")


def test_m8_fusao_de_filtros() raises:
    var etapas = List[Etapa]()
    etapas.append(Etapa.filtro(coluna("a").gt(lit(1.0))))
    etapas.append(Etapa.filtro(coluna("b").gt(lit(2.0))))
    var nomes = List[String]()
    nomes.append("a")
    etapas.append(Etapa.projecao(nomes^))
    var out = mesclar_filtros(etapas)
    assert_equal(len(out), 2)
    assert_equal(out[0].tipo, TipoEtapa.FILTRO)
    assert_true("&" in out[0].expr.descrever())


def test_m8_empurrao_de_filtro() raises:
    var ordem = List[String]()
    ordem.append("v")
    var etapas = List[Etapa]()
    etapas.append(Etapa.ordenacao(ordem^, List[Bool]()))
    etapas.append(Etapa.filtro(coluna("v").gt(lit(1.0))))
    var out = empurrar_filtros(etapas)
    assert_equal(out[0].tipo, TipoEtapa.FILTRO)
    assert_equal(out[1].tipo, TipoEtapa.ORDENACAO)


def test_m8_filtro_nao_ultrapassa_a_coluna_que_usa() raises:
    """Empurrar um filtro para antes da coluna que ele le seria defeito."""
    var etapas = List[Etapa]()
    etapas.append(Etapa.com_coluna("dobro", coluna("v").vezes(lit(2.0))))
    etapas.append(Etapa.filtro(coluna("dobro").gt(lit(1.0))))
    var out = empurrar_filtros(etapas)
    assert_equal(out[0].tipo, TipoEtapa.COM_COLUNA)
    assert_equal(out[1].tipo, TipoEtapa.FILTRO)


def test_m8_filtro_nao_ultrapassa_agregacao() raises:
    """Filtrar antes de agregar e outra pergunta, nao a mesma mais rapida."""
    var chaves = List[String]()
    chaves.append("g")
    var aggs = List[Agregacao]()
    aggs.append(soma("v"))
    var etapas = List[Etapa]()
    etapas.append(Etapa.agregacao(chaves^, aggs^))
    etapas.append(Etapa.filtro(coluna("soma_v").gt(lit(1.0))))
    var out = empurrar_filtros(etapas)
    assert_equal(out[0].tipo, TipoEtapa.AGREGACAO)
    assert_equal(out[1].tipo, TipoEtapa.FILTRO)


def test_m8_poda_de_colunas() raises:
    var todas = List[String]()
    todas.append("id")
    todas.append("valor")
    todas.append("grupo")
    todas.append("nota")

    var chaves = List[String]()
    chaves.append("grupo")
    var aggs = List[Agregacao]()
    aggs.append(soma("valor"))
    var etapas = List[Etapa]()
    etapas.append(Etapa.agregacao(chaves^, aggs^))

    var usadas = colunas_do_plano(etapas, todas)
    assert_equal(len(usadas), 2)
    assert_equal(usadas[0], "valor")
    assert_equal(usadas[1], "grupo")


def test_m8_sem_projecao_final_nao_poda() raises:
    """Se a saida e 'todas as colunas', nao ha o que podar."""
    var todas = List[String]()
    todas.append("a")
    todas.append("b")
    var etapas = List[Etapa]()
    etapas.append(Etapa.filtro(coluna("a").gt(lit(1.0))))
    assert_equal(len(colunas_do_plano(etapas, todas)), 0)


def test_m8_juncao_bloqueia_a_poda() raises:
    var todas = List[String]()
    todas.append("a")
    todas.append("b")
    var chaves = List[String]()
    chaves.append("a")
    var etapas = List[Etapa]()
    etapas.append(Etapa.juncao(List[Coluna](), chaves^, 0))
    var nomes = List[String]()
    nomes.append("a")
    etapas.append(Etapa.projecao(nomes^))
    assert_equal(len(colunas_do_plano(etapas, todas)), 0)


def test_m8_explicar_mostra_antes_e_depois() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    var ordem = List[String]()
    ordem.append("valor")
    var q = (
        t.ordenar(ordem)
        .onde(coluna("valor").gt(lit(100.0)))
        .onde(coluna("cidade").eq(lit_texto("SP")))
    )
    var texto = q.explicar()
    assert_true("LOGICO" in texto)
    assert_true("OTIMIZADO" in texto)
    assert_true("fusao de filtros" in texto)
    assert_true("empurrao de filtro" in texto)
    # no plano otimizado o filtro vem antes da ordenacao
    var otimizado = q.descrever_otimizado()
    assert_true(otimizado.find("FILTER") < otimizado.find("SORT"))


def test_m8_otimizar_nao_muda_o_resultado() raises:
    """A prova que autoriza otimizar: mesma resposta, nos dois caminhos."""
    var t = ler_csv("tests/fixtures/vendas.csv")
    var ordem = List[String]()
    ordem.append("valor")
    var q = (
        t.ordenar(ordem, True)
        .com_coluna("dobro", coluna("valor").vezes(lit(2.0).vezes(lit(1.0))))
        .onde(coluna("cidade").eq(lit_texto("SP")))
    )
    var com = q.coletar()
    var sem = q.coletar_sem_otimizar()
    assert_equal(com.linhas(), sem.linhas())
    assert_equal(com.colunas(), sem.colunas())
    for i in range(com.linhas()):
        assert_equal(com.pegar("valor").texto_em(i), sem.pegar("valor").texto_em(i))
        assert_equal(com.pegar("dobro").texto_em(i), sem.pegar("dobro").texto_em(i))


def test_m8_varredura_parquet_le_so_o_necessario() raises:
    var chaves = List[String]()
    chaves.append("grupo")
    var aggs = List[Agregacao]()
    aggs.append(soma("valor"))
    var q = (
        varredura_parquet("tests/fixtures/grupos.parquet")
        .agrupar(chaves)
        .agregar(aggs^)
    )
    var plano = q.plano_otimizado()
    assert_equal(len(plano.colunas_lidas), 2)
    assert_true("poda de colunas (3 -> 2)" in plano.regras[0])

    var r = q.coletar()
    assert_equal(r.linhas(), 3)
    assert_equal(r.colunas(), 2)
    # e o resultado bate com a leitura completa
    var sem = q.coletar_sem_otimizar()
    assert_equal(r.soma("soma_valor"), sem.soma("soma_valor"))


def test_m8_varredura_le_dicionarizado() raises:
    """Regressao: `tem_dicionario` usava `offset > 0` como sentinela.

    Quando a pagina de dicionario abre o pedaco de coluna, torna-la relativa ao
    buffer local a leva para o offset zero — e a coluna passava a ser lida como
    se nao tivesse dicionario nenhum. So aparece em arquivo dicionarizado lido
    por faixa, que era exatamente o caso que nenhum teste cobria.
    """
    var t = varredura_parquet("tests/fixtures/dicionario.parquet").coletar()
    assert_equal(t.linhas(), 140)
    assert_equal(t.pegar("cidade").texto_em(0), "SP")
    assert_equal(t.pegar("cidade").texto_em(3), "BH")
    assert_true(t.pegar("cidade").eh_dicionarizada())
    assert_equal(t.pegar("cidade").cardinalidade(), 3)


def test_m8_varredura_parquet_alimenta_o_plano() raises:
    var q = varredura_parquet("tests/fixtures/grupos.parquet").onde(
        coluna("valor").gt(lit(1000.0))
    )
    assert_equal(q.linhas(), 999)
    assert_true("parquet" in q.explicar())


# ------------------------------------------------------------------ M9


def _uma_lista(nome: String) -> List[String]:
    var l = List[String]()
    l.append(nome)
    return l^


def test_m9_leitor_por_faixa() raises:
    """Ler faixa e o que permite arquivo maior que a RAM."""
    var l = LeitorArquivo("tests/fixtures/simples.parquet")
    assert_true(l.tamanho > 12)
    var inicio = l.ler(0, 4)
    assert_equal(inicio[0], UInt8(80))  # P
    assert_equal(inicio[1], UInt8(65))  # A
    assert_equal(inicio[2], UInt8(82))  # R
    assert_equal(inicio[3], UInt8(49))  # 1
    var fim = l.ler(l.tamanho - 4, 4)
    assert_equal(fim[0], UInt8(80))
    assert_equal(len(l.ler(10, 20)), 20)
    l.fechar()


def test_m9_leitor_recusa_faixa_invalida() raises:
    var l = LeitorArquivo("tests/fixtures/simples.parquet")
    var pegou = False
    try:
        _ = l.ler(l.tamanho - 2, 100)
    except e:
        pegou = True
        assert_true("fora de" in String(e))
    l.fechar()
    assert_true(pegou)


def test_m9_varredura_por_row_group() raises:
    var so = List[String]()
    so.append("grupo")
    so.append("valor")
    var v = VarreduraParquet("tests/fixtures/grupos.parquet", so)
    assert_equal(v.n_grupos(), 3)
    assert_equal(v.n_linhas(), 3000)

    var total = 0
    for g in range(v.n_grupos()):
        var lote = v.ler_grupo(g)
        assert_equal(len(lote), 2)  # so as colunas pedidas saem do disco
        total += lote[0].tamanho()
    v.fechar()
    assert_equal(total, 3000)


def test_m9_plano_flui_ou_explica() raises:
    var chaves = _uma_lista("g")
    var aggs = List[Agregacao]()
    aggs.append(soma("v"))

    var bom = List[Etapa]()
    bom.append(Etapa.filtro(coluna("v").gt(lit(1.0))))
    bom.append(Etapa.agregacao(chaves.copy(), aggs.copy()))
    assert_equal(plano_flui(bom), "")

    var com_ordem = List[Etapa]()
    com_ordem.append(Etapa.ordenacao(_uma_lista("v"), List[Bool]()))
    com_ordem.append(Etapa.agregacao(chaves.copy(), aggs.copy()))
    assert_true("ordenacao" in plano_flui(com_ordem))

    var com_juncao = List[Etapa]()
    com_juncao.append(Etapa.juncao(List[Coluna](), _uma_lista("g"), 0))
    com_juncao.append(Etapa.agregacao(chaves.copy(), aggs.copy()))
    assert_true("juncao" in plano_flui(com_juncao))

    var sem_agregacao = List[Etapa]()
    sem_agregacao.append(Etapa.filtro(coluna("v").gt(lit(1.0))))
    assert_true("terminar em uma agregacao" in plano_flui(sem_agregacao))

    # a agregacao tem de ser a ultima
    var fora_de_ordem = List[Etapa]()
    fora_de_ordem.append(Etapa.agregacao(chaves.copy(), aggs.copy()))
    fora_de_ordem.append(Etapa.filtro(coluna("soma_v").gt(lit(1.0))))
    assert_true("ultima etapa" in plano_flui(fora_de_ordem))


def test_m9_distintos_nao_flui() raises:
    """Nao combina entre fatias sem guardar tudo — e recusado, nao fingido."""
    var chaves = _uma_lista("g")
    var aggs = List[Agregacao]()
    aggs.append(distintos("v"))
    var etapas = List[Etapa]()
    etapas.append(Etapa.agregacao(chaves^, aggs^))
    assert_true("nao combina entre fatias" in plano_flui(etapas))


def test_m9_fluxo_bate_com_execucao_inteira() raises:
    var chaves = _uma_lista("grupo")
    var aggs = List[Agregacao]()
    aggs.append(soma("valor"))
    aggs.append(media("valor"))
    aggs.append(contar())
    aggs.append(minimo("valor"))
    aggs.append(maximo("valor"))
    var q = (
        varredura_parquet("tests/fixtures/grupos.parquet")
        .onde(coluna("valor").gt(lit(100.0)))
        .agrupar(chaves)
        .agregar(aggs^)
    )
    assert_equal(q.pode_fluir(), "")

    var inteiro = q.coletar()
    var fluindo = q.coletar_em_fluxo()
    assert_equal(fluindo.linhas(), inteiro.linhas())
    assert_equal(fluindo.colunas(), inteiro.colunas())
    for i in range(inteiro.linhas()):
        assert_equal(
            fluindo.pegar("grupo").texto_em(i), inteiro.pegar("grupo").texto_em(i)
        )
        assert_equal(
            fluindo.pegar("soma_valor").texto_em(i),
            inteiro.pegar("soma_valor").texto_em(i),
        )
        assert_equal(
            fluindo.pegar("media_valor").texto_em(i),
            inteiro.pegar("media_valor").texto_em(i),
        )
        assert_equal(
            fluindo.pegar("minimo_valor").texto_em(i),
            inteiro.pegar("minimo_valor").texto_em(i),
        )
        assert_equal(
            fluindo.pegar("maximo_valor").texto_em(i),
            inteiro.pegar("maximo_valor").texto_em(i),
        )


def test_m9_fluxo_em_memoria_com_fatias_pequenas() raises:
    """Fatia pequena nao muda a resposta — so o pico de memoria."""
    var t = ler_parquet("tests/fixtures/grupos.parquet")
    var chaves = _uma_lista("grupo")
    var aggs = List[Agregacao]()
    aggs.append(soma("valor"))
    aggs.append(contar())
    var q = t.agrupar(chaves).agregar(aggs^)

    var inteiro = q.coletar()
    var em_7 = q.coletar_em_fluxo(7)
    assert_equal(em_7.linhas(), inteiro.linhas())
    for i in range(inteiro.linhas()):
        assert_equal(
            em_7.pegar("soma_valor").texto_em(i),
            inteiro.pegar("soma_valor").texto_em(i),
        )
        assert_equal(
            em_7.pegar("contagem").texto_em(i), inteiro.pegar("contagem").texto_em(i)
        )


def test_m9_fluxo_preserva_ausentes() raises:
    """Grupo sem valor valido continua ausente, tambem no fluxo."""
    var t = ler_csv("tests/fixtures/vendas.csv")
    var chaves = _uma_lista("cidade")
    var aggs = List[Agregacao]()
    aggs.append(soma("valor"))
    aggs.append(contar())
    var r = t.agrupar(chaves).agregar(aggs^).coletar_em_fluxo(2)
    assert_equal(r.linhas(), 3)
    for i in range(r.linhas()):
        if r.pegar("cidade").texto_em(i) == "BH":
            assert_true(r.pegar("soma_valor").eh_ausente(i))
            assert_equal(r.pegar("contagem").texto_em(i), "1")


def test_m9_fluxo_com_ordenacao_erra_com_explicacao() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    var chaves = _uma_lista("cidade")
    var aggs = List[Agregacao]()
    aggs.append(soma("valor"))
    var ordem = _uma_lista("valor")
    var pegou = False
    try:
        _ = t.ordenar(ordem).agrupar(chaves).agregar(aggs^).coletar_em_fluxo()
    except e:
        pegou = True
        assert_true("ordenacao precisa do conjunto inteiro" in String(e))
        assert_true("use coletar()" in String(e))
    assert_true(pegou)


def test_m9_escrita_em_varios_row_groups() raises:
    var t = ler_parquet("tests/fixtures/grupos.parquet")
    var saida = "tests/fixtures/_saida_grupos_rg.parquet"
    para_parquet(t, saida, 250)
    var m = metadados_parquet(saida)
    assert_equal(len(m.grupos), 12)
    assert_equal(m.num_linhas, 3000)
    for g in range(len(m.grupos)):
        assert_equal(m.grupos[g].num_linhas, 250)

    var volta = ler_parquet(saida)
    assert_equal(volta.linhas(), 3000)
    assert_equal(volta.soma("id"), t.soma("id"))
    assert_equal(volta.pegar("grupo").texto_em(1000), "b")


def test_m9_fluxo_sobre_muitos_row_groups() raises:
    var t = ler_parquet("tests/fixtures/grupos.parquet")
    var saida = "tests/fixtures/_saida_fluxo.parquet"
    para_parquet(t, saida, 100)  # 30 row groups

    var chaves = _uma_lista("grupo")
    var aggs = List[Agregacao]()
    aggs.append(soma("valor"))
    aggs.append(contar())
    var q = varredura_parquet(saida).agrupar(chaves).agregar(aggs^)

    var fluindo = q.coletar_em_fluxo()
    var inteiro = q.coletar()
    assert_equal(fluindo.linhas(), 3)
    for i in range(3):
        assert_equal(
            fluindo.pegar("soma_valor").texto_em(i),
            inteiro.pegar("soma_valor").texto_em(i),
        )


# ------------------------------------------------------------------ M10 SQL


def test_sql_tokenizador() raises:
    var t = tokenizar("SELECT a, 1.5 FROM 'x.csv' WHERE b >= 'oi'")
    assert_equal(t[0].texto, "SELECT")
    assert_equal(t[1].texto, "a")
    assert_equal(t[2].texto, ",")
    assert_equal(t[3].texto, "1.5")
    assert_equal(t[5].texto, "x.csv")
    assert_equal(t[7].texto, "b")
    assert_equal(t[8].texto, ">=")
    assert_equal(t[9].texto, "oi")


def test_sql_analise_basica() raises:
    var c = analisar(
        "SELECT cidade, SUM(valor) AS total FROM 'v.parquet'"
        " WHERE valor > 100 GROUP BY cidade ORDER BY total DESC LIMIT 5"
    )
    assert_false(c.tudo)
    assert_equal(len(c.itens), 2)
    assert_false(c.itens[0].eh_agregacao)
    assert_true(c.itens[1].eh_agregacao)
    assert_equal(c.itens[1].apelido, "total")
    assert_equal(c.fonte, "v.parquet")
    assert_true(c.tem_onde)
    assert_equal(len(c.agrupar), 1)
    assert_equal(c.agrupar[0], "cidade")
    assert_true(c.descendente)
    assert_equal(c.limite, 5)


def test_sql_erro_aponta_a_posicao() raises:
    var pegou = False
    try:
        _ = analisar("SELECT a FROM")
    except e:
        pegou = True
        assert_true("posicao" in String(e))
    assert_true(pegou)

    pegou = False
    try:
        _ = analisar("SELEC a FROM x")
    except e:
        pegou = True
        assert_true("'SELECT'" in String(e))
    assert_true(pegou)


def test_sql_funcao_desconhecida_erra() raises:
    var pegou = False
    try:
        _ = analisar("SELECT MEDIANA(v) FROM x")
    except e:
        pegou = True
        assert_true("nao suportada" in String(e))
        assert_true("SUM" in String(e))
    assert_true(pegou)


def test_sql_vira_o_mesmo_plano() raises:
    """SQL nao tem motor proprio: vira as mesmas etapas da API fluente."""
    var q = plano_do_sql(
        "SELECT grupo, SUM(valor) AS total FROM 'tests/fixtures/grupos.parquet'"
        " WHERE valor > 100 GROUP BY grupo ORDER BY total DESC",
        Catalogo(),
    )
    var plano = q.descrever()
    assert_true("FILTER" in plano)
    assert_true("AGGREGATE [grupo]" in plano)
    assert_true("PROJECT [grupo, total]" in plano)
    assert_true("SORT [total desc]" in plano)
    # e passa pelo mesmo otimizador
    assert_true("poda de colunas (3 -> 2)" in q.explicar())


def test_sql_agregacao_sobre_parquet() raises:
    var r = consultar_sql(
        "SELECT grupo, SUM(valor) AS total, COUNT(*) AS n"
        " FROM 'tests/fixtures/grupos.parquet'"
        " WHERE valor > 100 GROUP BY grupo ORDER BY total DESC"
    )
    assert_equal(r.linhas(), 3)
    assert_equal(r.colunas(), 3)
    assert_equal(r.pegar("grupo").texto_em(0), "c")
    assert_equal(r.pegar("n").texto_em(0), "933")


def test_sql_catalogo_e_limite() raises:
    var cat = Catalogo()
    cat.registrar("vendas", ler_csv("tests/fixtures/vendas.csv"))
    var r = consultar_sql_em(
        "SELECT cidade, valor FROM vendas WHERE valor > 1000"
        " ORDER BY valor DESC LIMIT 2",
        cat,
    )
    assert_equal(r.linhas(), 2)
    assert_equal(r.pegar("valor").texto_em(0), "2000.0")
    assert_equal(r.pegar("valor").texto_em(1), "1500.0")


def test_sql_estrela_e_texto() raises:
    var cat = Catalogo()
    cat.registrar("vendas", ler_csv("tests/fixtures/vendas.csv"))
    var r = consultar_sql_em("SELECT * FROM vendas WHERE cidade = 'SP'", cat)
    assert_equal(r.linhas(), 3)
    assert_equal(r.colunas(), 3)


def test_sql_agregacao_total() raises:
    var cat = Catalogo()
    cat.registrar("vendas", ler_csv("tests/fixtures/vendas.csv"))
    var r = consultar_sql_em(
        "SELECT AVG(valor) AS media, MAX(valor) AS pico, MIN(valor) AS piso"
        " FROM vendas",
        cat,
    )
    assert_equal(r.linhas(), 1)
    assert_equal(r.pegar("media").texto_em(0), "1375.0")
    assert_equal(r.pegar("pico").texto_em(0), "2000.0")
    assert_equal(r.pegar("piso").texto_em(0), "800.0")


def test_sql_and_or_e_parenteses() raises:
    var cat = Catalogo()
    cat.registrar("v", ler_csv("tests/fixtures/vendas.csv"))
    var r = consultar_sql_em(
        "SELECT cidade FROM v WHERE (cidade = 'SP' AND valor > 1300)"
        " OR cidade = 'RJ'",
        cat,
    )
    assert_equal(r.linhas(), 3)


def test_sql_coluna_fora_do_group_by_erra() raises:
    var cat = Catalogo()
    cat.registrar("v", ler_csv("tests/fixtures/vendas.csv"))
    var pegou = False
    try:
        _ = consultar_sql_em("SELECT data, SUM(valor) FROM v GROUP BY cidade", cat)
    except e:
        pegou = True
        assert_true("nao no GROUP BY" in String(e))
    assert_true(pegou)


def test_sql_fonte_desconhecida_erra() raises:
    var pegou = False
    try:
        _ = consultar_sql("SELECT * FROM tabela_que_nao_existe")
    except e:
        pegou = True
        assert_true("nao e tabela registrada" in String(e))
    assert_true(pegou)


def test_sql_ordena_por_coluna_nao_selecionada() raises:
    """ORDER BY por coluna fora do SELECT: a ordenacao vai antes da projecao."""
    var cat = Catalogo()
    cat.registrar("v", ler_csv("tests/fixtures/vendas.csv"))
    var r = consultar_sql_em("SELECT cidade FROM v ORDER BY valor DESC", cat)
    assert_equal(r.colunas(), 1)
    assert_equal(r.pegar("cidade").texto_em(0), "SP")
    assert_equal(r.pegar("cidade").texto_em(1), "SP")


def test_sql_limite_como_operador() raises:
    var t = ler_csv("tests/fixtures/vendas.csv")
    var r = t.limite(2).coletar()
    assert_equal(r.linhas(), 2)
    assert_true("LIMIT 2" in t.limite(2).descrever())


# ----------------------------------------------------------- M10 Arrow


def test_arrow_flatbuf_ida_e_volta() raises:
    """Uma tabela escrita e lida de volta pelo proprio construtor."""
    var b = ConstrutorFlat()
    var nome = b.texto("tucano")
    b.iniciar_tabela()
    b.campo_referencia(0, nome)
    b.campo_i32(1, 42, 0)
    b.campo_bool(2, True, False)
    var raiz = b.terminar_tabela()
    var bytes = b.finalizar(raiz)

    var t = raiz_flat(bytes, 0)
    assert_equal(texto_flat(bytes, campo_flat(bytes, t, 0)), "tucano")
    assert_equal(ler_i32(bytes, campo_flat(bytes, t, 1)), 42)
    # campo com valor padrao nao ocupa espaco: some da vtable
    b = ConstrutorFlat()
    b.iniciar_tabela()
    b.campo_i32(1, 0, 0)
    var vazia = b.terminar_tabela()
    var bytes2 = b.finalizar(vazia)
    assert_equal(campo_flat(bytes2, raiz_flat(bytes2, 0), 1), -1)


def test_arrow_le_arquivo_de_outra_implementacao() raises:
    """A fixture foi escrita por outra implementacao — ler a propria nao prova."""
    var t = ler_arrow("tests/fixtures/simples.arrow")
    assert_equal(t.linhas(), 5)
    assert_equal(t.colunas(), 4)
    assert_equal(t.dtype_de("id").codigo, DType.INTEIRO)
    assert_equal(t.dtype_de("valor").codigo, DType.REAL)
    assert_equal(t.dtype_de("ativo").codigo, DType.LOGICO)
    assert_equal(t.dtype_de("cidade").codigo, DType.TEXTO)
    assert_equal(t.pegar("id").texto_em(4), "5")
    assert_equal(t.pegar("valor").texto_em(4), "50.125")
    assert_equal(t.pegar("ativo").texto_em(1), "False")
    assert_equal(t.pegar("cidade").texto_em(3), "BH")


def test_arrow_le_ausentes() raises:
    """A validade do Arrow e invertida: bit 1 significa presente."""
    var t = ler_arrow("tests/fixtures/com_na.arrow")
    assert_equal(t.linhas(), 5)
    assert_equal(t.pegar("id").contar_ausentes(), 2)
    assert_true(t.pegar("id").eh_ausente(1))
    assert_false(t.pegar("id").eh_ausente(0))
    assert_equal(t.pegar("valor").contar_ausentes(), 2)
    assert_equal(t.pegar("cidade").texto_em(3), "BH")
    assert_true(t.pegar("cidade").eh_ausente(4))


def test_arrow_le_temporais() raises:
    var t = ler_arrow("tests/fixtures/temporal.arrow")
    assert_equal(t.dtype_de("quando").codigo, DType.DATA)
    assert_equal(t.dtype_de("carimbo").codigo, DType.DATAHORA)
    assert_equal(t.pegar("quando").texto_em(1), "2024-02-29")
    assert_equal(t.pegar("carimbo").texto_em(1), "2024-02-29T23:59:59.500000")
    assert_equal(t.pegar("carimbo").texto_em(2), "1969-12-31T23:59:59")


def test_arrow_ida_e_volta_pelo_tucano() raises:
    var original = ler_parquet("tests/fixtures/grupos.parquet")
    var saida = "tests/fixtures/_saida_grupos.arrow"
    para_arrow(original, saida)
    var volta = ler_arrow(saida)
    assert_equal(volta.linhas(), 3000)
    assert_equal(volta.colunas(), 3)
    assert_equal(volta.soma("id"), original.soma("id"))
    assert_equal(volta.pegar("grupo").texto_em(1000), "b")
    assert_equal(volta.pegar("valor").texto_em(2), "1.0")


def test_arrow_ida_e_volta_com_ausentes_e_datas() raises:
    var original = ler_csv("tests/fixtures/eventos.csv")
    var saida = "tests/fixtures/_saida_eventos.arrow"
    para_arrow(original, saida)
    var volta = ler_arrow(saida)
    assert_equal(volta.linhas(), 4)
    assert_equal(volta.dtype_de("quando").codigo, DType.DATAHORA)
    assert_equal(volta.pegar("quando").texto_em(0), "2024-01-15T08:30:00")
    assert_equal(volta.pegar("valor").contar_ausentes(), 1)
    assert_true(volta.pegar("valor").eh_ausente(2))
    assert_equal(volta.pegar("tipo").texto_em(1), "compra")


def test_arrow_arquivo_invalido_erra() raises:
    var pegou = False
    try:
        _ = ler_arrow("tests/fixtures/pessoas.csv")
    except e:
        pegou = True
        assert_true("ARROW1" in String(e))
    assert_true(pegou)


def test_arrow_alimenta_o_executor() raises:
    """Arrow e so mais uma fonte: o plano nao sabe de onde os dados vieram."""
    var t = ler_arrow("tests/fixtures/simples.arrow")
    var chaves = List[String]()
    chaves.append("cidade")
    var aggs = List[Agregacao]()
    aggs.append(soma("valor"))
    var r = t.agrupar(chaves).agregar(aggs^).coletar()
    assert_equal(r.linhas(), 3)
    assert_equal(r.pegar("cidade").texto_em(0), "SP")
    assert_equal(r.pegar("soma_valor").texto_em(0), "90.625")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
