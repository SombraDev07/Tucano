"""Bench M6 — agregacao, juncao e ordenacao.

O ponto principal: uma chave de texto **dicionarizada** dispensa hash. O codigo
Int32 ja e o grupo, entao o groupby vira indexacao direta de array. Este bench
compara os dois caminhos sobre os mesmos dados.
"""

from std.time import perf_counter_ns
from tucano import (
    Coluna,
    Tabela,
    Agregacao,
    soma,
    media,
    contar,
    coluna,
    lit,
)
from tucano.executor import calcular_grupos


def _vendas(n: Int, cardinalidade: Int) raises -> Tabela:
    var cidades = List[String](capacity=n)
    var ids = List[Int64](capacity=n)
    var valores = List[Float64](capacity=n)
    for i in range(n):
        cidades.append("cidade-" + String(i % cardinalidade))
        ids.append(Int64(i % cardinalidade))
        valores.append(Float64(i % 997) * 1.5)
    var cols = List[Coluna]()
    cols.append(Coluna.de_textos("cidade", cidades^))
    cols.append(Coluna.de_inteiros("cidade_id", ids^))
    cols.append(Coluna.de_reais("valor", valores^))
    return Tabela(cols^)


def _dimensao(cardinalidade: Int) raises -> Tabela:
    var nomes = List[String](capacity=cardinalidade)
    var regioes = List[String](capacity=cardinalidade)
    for i in range(cardinalidade):
        nomes.append("cidade-" + String(i))
        regioes.append("regiao-" + String(i % 5))
    var cols = List[Coluna]()
    cols.append(Coluna.de_textos("cidade", nomes^))
    cols.append(Coluna.de_textos("regiao", regioes^))
    return Tabela(cols^)


def _uma(nome: String) -> List[String]:
    var l = List[String]()
    l.append(nome)
    return l^


def main() raises:
    var n = 1_000_000
    var cardinalidade = 50
    var t = _vendas(n, cardinalidade)
    print(
        "bench_m6 — n =", n, "| cardinalidade da chave =", cardinalidade,
    )
    print("cidade dicionarizada:", t.pegar("cidade").eh_dicionarizada())
    print()

    # ---- formacao de grupos: os tres caminhos
    var t0 = perf_counter_ns()
    var g1 = calcular_grupos(t.lote(), _uma("cidade"))
    var t1 = perf_counter_ns()
    print(
        "grupos por texto dicionarizado ", (t1 - t0) // 1000000, "ms |",
        (t1 - t0) // n, "ns/linha |", g1.caminho, "|", g1.n_grupos, "grupos",
    )

    t0 = perf_counter_ns()
    var g2 = calcular_grupos(t.lote(), _uma("cidade_id"))
    t1 = perf_counter_ns()
    var ns_int = t1 - t0
    print(
        "grupos por inteiro             ", ns_int // 1000000, "ms |",
        ns_int // n, "ns/linha |", g2.caminho, "|", g2.n_grupos, "grupos",
    )

    var duas = List[String]()
    duas.append("cidade")
    duas.append("cidade_id")
    t0 = perf_counter_ns()
    var g3 = calcular_grupos(t.lote(), duas)
    t1 = perf_counter_ns()
    var ns_comp = t1 - t0
    print(
        "grupos por chave composta      ", ns_comp // 1000000, "ms |",
        ns_comp // n, "ns/linha |", g3.caminho, "|", g3.n_grupos, "grupos",
    )
    print()

    # ---- agregacao completa
    var aggs = List[Agregacao]()
    aggs.append(soma("valor"))
    aggs.append(media("valor"))
    aggs.append(contar())
    t0 = perf_counter_ns()
    var r = t.agrupar(_uma("cidade")).agregar(aggs^).coletar()
    t1 = perf_counter_ns()
    print(
        "agrupar + 3 agregacoes         ", (t1 - t0) // 1000000, "ms |",
        (t1 - t0) // n, "ns/linha ->", r.linhas(), "grupos",
    )

    # ---- juncao
    var dim = _dimensao(cardinalidade)
    t0 = perf_counter_ns()
    var j = t.unir(dim, _uma("cidade"), "esquerda").coletar()
    t1 = perf_counter_ns()
    print(
        "juncao a esquerda              ", (t1 - t0) // 1000000, "ms |",
        (t1 - t0) // n, "ns/linha ->", j.linhas(), "x", j.colunas(),
    )

    # ---- ordenacao
    t0 = perf_counter_ns()
    var o = t.ordenar(_uma("valor")).coletar()
    t1 = perf_counter_ns()
    print(
        "ordenar (mesclagem estavel)    ", (t1 - t0) // 1000000, "ms |",
        (t1 - t0) // n, "ns/linha ->", o.linhas(), "linhas",
    )
