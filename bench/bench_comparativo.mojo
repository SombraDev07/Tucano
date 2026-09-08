"""Suite comparativa — o lado do Tucano.

Gera o arquivo, roda o workload e grava os tempos. O lado de referencia le o
mesmo arquivo, roda a mesma consulta e junta os numeros:

    pixi run bench-comparativo
    pixi run -e comparativo referencia

O workload e o mais comum que existe em analise tabular: ler Parquet, filtrar,
agrupar, agregar. Vale mais medir bem um caso real do que mal varios sinteticos.
"""

from std.pathlib import Path
from std.time import perf_counter_ns
from tucano import (
    Coluna,
    Tabela,
    Agregacao,
    varredura_parquet,
    para_parquet,
    coluna,
    lit,
    soma,
    media,
    contar,
)

comptime _SAIDA = "/tmp/tucano_bench_comparativo.txt"


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


def _uma(n: String) -> List[String]:
    var l = List[String]()
    l.append(n)
    return l^


def _medir(caminho: String, repeticoes: Int) raises -> Int:
    """Menor tempo de N repeticoes: menos ruido de agendamento."""
    var melhor = -1
    for _ in range(repeticoes):
        var aggs = List[Agregacao]()
        aggs.append(soma("valor"))
        aggs.append(media("peso"))
        aggs.append(contar())
        var t0 = perf_counter_ns()
        var r = (
            varredura_parquet(caminho)
            .onde(coluna("valor").gt(lit(1000.0)))
            .agrupar(_uma("grupo"))
            .agregar(aggs^)
            .coletar()
        )
        var t1 = perf_counter_ns()
        _ = r.linhas()
        var ns = t1 - t0
        if melhor < 0 or ns < melhor:
            melhor = ns
    return melhor


def _medir_fluxo(caminho: String, repeticoes: Int) raises -> Int:
    var melhor = -1
    for _ in range(repeticoes):
        var aggs = List[Agregacao]()
        aggs.append(soma("valor"))
        aggs.append(media("peso"))
        aggs.append(contar())
        var t0 = perf_counter_ns()
        var r = (
            varredura_parquet(caminho)
            .onde(coluna("valor").gt(lit(1000.0)))
            .agrupar(_uma("grupo"))
            .agregar(aggs^)
            .coletar_em_fluxo()
        )
        var t1 = perf_counter_ns()
        _ = r.linhas()
        var ns = t1 - t0
        if melhor < 0 or ns < melhor:
            melhor = ns
    return melhor


def main() raises:
    var tamanhos = List[Int]()
    tamanhos.append(1_000_000)
    tamanhos.append(5_000_000)

    var relatorio = String("# tucano bench comparativo\n")
    print("bench comparativo — lado do Tucano")
    print("workload: Parquet -> filtro -> agrupar -> 3 agregacoes")
    print()

    for n in tamanhos:
        var caminho = "/tmp/tucano_cmp_" + String(n) + ".parquet"
        _gerar(caminho, n)
        var bytes = len(Path(caminho).read_bytes())

        var ns = _medir(caminho, 3)
        var ns_fluxo = _medir_fluxo(caminho, 3)

        print(
            "n=", n, "| arquivo", bytes // 1048576, "MiB |",
            "tucano", ns // 1000000, "ms |",
            "tucano em fluxo", ns_fluxo // 1000000, "ms",
        )
        relatorio += String(n) + " " + caminho + " " + String(ns) + " "
        relatorio += String(ns_fluxo) + "\n"

    Path(_SAIDA).write_text(relatorio)
    print()
    print("tempos gravados em", _SAIDA)
    print("agora: pixi run -e comparativo referencia")
