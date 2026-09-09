"""So a escrita — o lado do Tucano.

O M27 mediu a escrita com um script solto, e o numero (1,29 s para 5M x 5) ficou
so no texto. Aqui ele vira coisa que se roda de novo.

Duas formas do mesmo arquivo: o padrao, que sao row groups de 500 mil linhas, e
tudo num grupo so, que era o padrao antigo. As duas importam porque a
codificacao roda **por coluna dentro do row group** — com um grupo so, o
paralelismo tem cinco tarefas grandes e nada mais; com dez grupos, tem dez vezes
cinco, e as ondas enchem os nucleos.
"""

from std.pathlib import Path
from std.time import perf_counter_ns
from tucano import Coluna, Tabela, para_parquet
from tucano.parquet import LINHAS_POR_GRUPO_PADRAO

comptime _SAIDA = "/tmp/tucano_bench_escrita.txt"


def _tabela(n: Int) raises -> Tabela:
    var ids = List[Int64](capacity=n)
    var valores = List[Float64](capacity=n)
    var pesos = List[Float64](capacity=n)
    var grupos = List[String](capacity=n)
    var notas = List[String](capacity=n)
    for i in range(n):
        ids.append(Int64(i))
        valores.append(Float64(i % 9973) * 1.5)
        pesos.append(Float64(i % 41) * 0.25)
        grupos.append("grupo-" + String(i % 24))
        notas.append("registro " + String(i % 500))
    var cols = List[Coluna]()
    cols.append(Coluna.de_inteiros("id", ids^))
    cols.append(Coluna.de_reais("valor", valores^))
    cols.append(Coluna.de_reais("peso", pesos^))
    cols.append(Coluna.de_textos("grupo", grupos^))
    cols.append(Coluna.de_textos("nota", notas^))
    return Tabela(cols^)


def _medir(t: Tabela, caminho: String, por_grupo: Int) raises -> Int:
    var melhor = -1
    for _ in range(3):
        var t0 = perf_counter_ns()
        para_parquet(t, caminho, por_grupo)
        var t1 = perf_counter_ns()
        var ns = Int(t1 - t0)
        if melhor < 0 or ns < melhor:
            melhor = ns
    return melhor


def main() raises:
    var n = 5_000_000
    var caminho = String("/tmp/tucano_bench_escrita.parquet")
    print("escrita de Parquet — lado do Tucano")
    print()
    var t = _tabela(n)
    print("n =", n, "| 5 colunas")

    var padrao = _medir(t, caminho, LINHAS_POR_GRUPO_PADRAO)
    var bytes_padrao = len(Path(caminho).read_bytes())
    print(
        "  padrao (500k)     ", padrao // 1000000, "ms |",
        bytes_padrao // (1024 * 1024), "MiB",
    )

    var um = _medir(t, caminho, 0)
    var bytes_um = len(Path(caminho).read_bytes())
    print(
        "  tudo num grupo    ", um // 1000000, "ms |",
        bytes_um // (1024 * 1024), "MiB",
    )

    var relatorio = String("# tucano bench escrita\n")
    relatorio += String(n) + " " + String(padrao) + " " + String(bytes_padrao)
    relatorio += " " + String(um) + " " + String(bytes_um) + "\n"
    Path(_SAIDA).write_text(relatorio)
    print()
    print("agora: pixi run -e comparativo escrita")
