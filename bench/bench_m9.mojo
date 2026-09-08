"""Bench M9 — memoria limitada.

A pergunta nao e "quao rapido", e "cabe". O fluxo troca os dados pelo **estado
dos grupos**, que e proporcional ao numero de grupos e nao ao de linhas, e passa
o arquivo por ele um row group de cada vez.

O numero que importa e o pico: quantos bytes ficam em memoria ao mesmo tempo,
contra o tamanho do arquivo.
"""

from std.pathlib import Path
from std.time import perf_counter_ns
from tucano import (
    Coluna,
    Tabela,
    Agregacao,
    varredura_parquet,
    para_parquet,
    metadados_parquet,
    coluna,
    lit,
    soma,
    media,
    contar,
)


def _tabela(n: Int) raises -> Tabela:
    var ids = List[Int64](capacity=n)
    var valores = List[Float64](capacity=n)
    var pesos = List[Float64](capacity=n)
    var notas = List[String](capacity=n)
    var grupos = List[String](capacity=n)
    for i in range(n):
        ids.append(Int64(i))
        valores.append(Float64(i % 997) * 1.5)
        pesos.append(Float64(i % 41) * 0.5)
        notas.append("observacao de referencia numero " + String(i % 1000))
        grupos.append("grupo-" + String(i % 12))
    var cols = List[Coluna]()
    cols.append(Coluna.de_inteiros("id", ids^))
    cols.append(Coluna.de_reais("valor", valores^))
    cols.append(Coluna.de_reais("peso", pesos^))
    cols.append(Coluna.de_textos("nota", notas^))
    cols.append(Coluna.de_textos("grupo", grupos^))
    return Tabela(cols^)


def _uma(n: String) -> List[String]:
    var l = List[String]()
    l.append(n)
    return l^


def main() raises:
    var n = 1_000_000
    var por_grupo = 25_000
    var caminho = "/tmp/tucano_bench_m9.parquet"

    var t0 = perf_counter_ns()
    para_parquet(_tabela(n), caminho, por_grupo)
    var t1 = perf_counter_ns()

    var m = metadados_parquet(caminho)
    var bytes = len(Path(caminho).read_bytes())

    # maior row group, somando so as colunas que o plano usa
    var maior = 0
    for g in range(len(m.grupos)):
        var soma_g = 0
        for c in range(m.num_colunas()):
            var nome = m.coluna_do_esquema(c).nome
            if nome == "valor" or nome == "grupo":
                soma_g += m.grupos[g].colunas[c].tamanho_comprimido
        if soma_g > maior:
            maior = soma_g

    print("bench_m9 — n =", n, "| 5 colunas")
    print(
        "arquivo:", bytes // 1024, "KiB em", len(m.grupos), "row groups |",
        "escrito em", (t1 - t0) // 1000000, "ms",
    )
    print(
        "maior row group das 2 colunas usadas:", maior // 1024, "KiB",
        "=", (maior * 100) // bytes, "% do arquivo",
    )
    print()

    var chaves = _uma("grupo")
    var aggs = List[Agregacao]()
    aggs.append(soma("valor"))
    aggs.append(media("valor"))
    aggs.append(contar())
    var q = (
        varredura_parquet(caminho)
        .onde(coluna("valor").gt(lit(100.0)))
        .agrupar(chaves)
        .agregar(aggs^)
    )
    print(q.explicar())
    print("flui:", "sim" if q.pode_fluir() == "" else q.pode_fluir())
    print()

    t0 = perf_counter_ns()
    var inteiro = q.coletar()
    t1 = perf_counter_ns()
    var ns_inteiro = t1 - t0

    t0 = perf_counter_ns()
    var fluindo = q.coletar_em_fluxo()
    t1 = perf_counter_ns()
    var ns_fluxo = t1 - t0

    print(
        "de uma vez:", ns_inteiro // 1000000, "ms | pico ~ arquivo inteiro das colunas",
    )
    print(
        "em fluxo:  ", ns_fluxo // 1000000, "ms | pico ~", maior // 1024, "KiB",
        "(um row group)",
    )
    print()
    print("mesmos", fluindo.linhas(), "grupos:", fluindo.linhas() == inteiro.linhas())
    var iguais = True
    for i in range(fluindo.linhas()):
        if (
            fluindo.pegar("grupo").texto_em(i) != inteiro.pegar("grupo").texto_em(i)
            or fluindo.pegar("soma_valor").texto_em(i)
            != inteiro.pegar("soma_valor").texto_em(i)
            or fluindo.pegar("contagem").texto_em(i)
            != inteiro.pegar("contagem").texto_em(i)
        ):
            iguais = False
    print("mesmos valores:", iguais)
    fluindo.mostrar()
