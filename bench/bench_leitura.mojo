"""So a leitura — o lado do Tucano.

Mede materializar o Parquet inteiro e materializar so duas colunas. O segundo
caso e o que acontece de verdade quando alguem consulta: o otimizador ja sabe
quais colunas o plano usa.
"""

from std.pathlib import Path
from std.time import perf_counter_ns
from tucano import Coluna, Tabela, ler_parquet, para_parquet

comptime _SAIDA = "/tmp/tucano_bench_leitura.txt"


def _gerar(caminho: String, n: Int) raises:
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
    para_parquet(Tabela(cols^), caminho, 100_000)


def _medir(caminho: String, colunas: List[String]) raises -> Int:
    var melhor = -1
    for _ in range(3):
        var t0 = perf_counter_ns()
        var t = ler_parquet(caminho, colunas)
        var t1 = perf_counter_ns()
        _ = t.linhas()
        var ns = t1 - t0
        if melhor < 0 or ns < melhor:
            melhor = ns
    return melhor


def main() raises:
    var tamanhos = List[Int]()
    tamanhos.append(1_000_000)
    tamanhos.append(5_000_000)

    var duas = List[String]()
    duas.append("valor")
    duas.append("grupo")

    var relatorio = String("# tucano bench leitura\n")
    print("leitura de Parquet — lado do Tucano")
    print()
    for n in tamanhos:
        var caminho = "/tmp/tucano_leitura_" + String(n) + ".parquet"
        _gerar(caminho, n)
        var tudo = _medir(caminho, List[String]())
        var podado = _medir(caminho, duas)
        print(
            "n=", n, "| tudo (5 col)", tudo // 1000000, "ms |",
            "2 de 5 col", podado // 1000000, "ms",
        )
        relatorio += String(n) + " " + caminho + " " + String(tudo) + " "
        relatorio += String(podado) + "\n"
    Path(_SAIDA).write_text(relatorio)
    print()
    print("agora: pixi run -e comparativo leitura")
