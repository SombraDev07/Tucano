from std.time import perf_counter_ns
from tucano import Coluna, Tabela


def _tabela_sintetica(n: Int) raises -> Tabela:
    var idades = List[Int64]()
    var valores = List[Float64]()
    for i in range(n):
        idades.append(Int64(i % 80))
        valores.append(Float64(i) * 0.5)
    var cols = List[Coluna]()
    cols.append(Coluna.de_inteiros("idade", idades^))
    cols.append(Coluna.de_reais("valor", valores^))
    return Tabela(cols^)


def main() raises:
    var n = 200_000
    print("bench_m0 n=", n)

    var t0 = perf_counter_ns()
    var tab = _tabela_sintetica(n)
    var t1 = perf_counter_ns()
    print("criar_ns", t1 - t0)

    t0 = perf_counter_ns()
    var media = tab.media("valor")
    t1 = perf_counter_ns()
    print("media_ns", t1 - t0, "resultado", media)

    t0 = perf_counter_ns()
    var sh = tab.shape()
    var sch = tab.schema()
    t1 = perf_counter_ns()
    print("shape_schema_ns", t1 - t0, "shape", sh.linhas, "x", sh.colunas, "campos", sch.tamanho())
