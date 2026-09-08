"""Bench M5 — scanner CSV tipado.

O leitor anterior era `arquivo -> String -> split -> objetos`: alocava uma
`String` por celula antes de saber o tipo dela. Media 7226 ns/linha.

O scanner le o arquivo uma vez como bytes, marca as fronteiras dos campos e o
parser tipado escreve direto no slab da coluna.
"""

from std.pathlib import Path
from std.time import perf_counter_ns
from tucano import ler_csv, ler_csv_tipado, para_csv, LeitorCSV, Campo, Schema, DType

comptime _BASE_ANTIGA_NS_LINHA = 7226


def _gerar(caminho: String, n: Int) raises -> Int:
    var cidades = List[String]()
    cidades.append("SP")
    cidades.append("RJ")
    cidades.append("BH")
    cidades.append("POA")
    cidades.append("CWB")
    var s = String("id,valor,cidade,data,ativo\n")
    for i in range(n):
        s += String(i) + ","
        s += String(Float64(i % 1000) * 0.5) + ","
        s += cidades[i % 5] + ","
        s += "2024-0" + String(1 + (i % 9)) + "-15,"
        if i % 2 == 0:
            s += "true\n"
        else:
            s += "false\n"
    Path(caminho).write_text(s)
    return s.byte_length()


def main() raises:
    var caminho = "/tmp/tucano_bench_m5.csv"
    var n = 200_000
    var bytes = _gerar(caminho, n)
    print("bench_m5 — n =", n, "| arquivo =", bytes // 1024, "KiB")
    print()

    var t0 = perf_counter_ns()
    var t = ler_csv(caminho)
    var t1 = perf_counter_ns()
    var ns = t1 - t0
    var mbs = Float64(bytes) / (Float64(ns) / 1e9) / 1048576.0
    print(
        "ler_csv (infere)  ", ns // 1000000, "ms |", ns // n, "ns/linha |",
        Int(mbs), "MiB/s",
    )
    print(
        "                   baseline anterior", _BASE_ANTIGA_NS_LINHA,
        "ns/linha -> ganho", Float64(_BASE_ANTIGA_NS_LINHA) / Float64(ns // n), "x",
    )

    var campos = List[Campo]()
    campos.append(Campo("id", DType.inteiro()))
    campos.append(Campo("valor", DType.real()))
    campos.append(Campo("cidade", DType.texto()))
    campos.append(Campo("data", DType.data()))
    campos.append(Campo("ativo", DType.logico()))
    t0 = perf_counter_ns()
    var t2 = ler_csv_tipado(caminho, Schema(campos^))
    t1 = perf_counter_ns()
    print(
        "ler_csv_tipado    ", (t1 - t0) // 1000000, "ms |", (t1 - t0) // n,
        "ns/linha | sem inferencia ->", t2.linhas(), "linhas",
    )

    t0 = perf_counter_ns()
    var leitor = LeitorCSV(caminho)
    var fatias = 0
    var linhas = 0
    while not leitor.fim():
        linhas += leitor.proximo(50_000).linhas()
        fatias += 1
    t1 = perf_counter_ns()
    print(
        "LeitorCSV         ", (t1 - t0) // 1000000, "ms |", fatias,
        "fatias de 50k ->", linhas, "linhas",
    )

    t0 = perf_counter_ns()
    para_csv(t, "/tmp/tucano_bench_m5_saida.csv")
    t1 = perf_counter_ns()
    print("para_csv          ", (t1 - t0) // 1000000, "ms |", (t1 - t0) // n, "ns/linha")
    print()
    print("shape:", t.linhas(), "x", t.colunas())
    print(
        "tipos inferidos:", t.dtype_de("id").nome(), t.dtype_de("valor").nome(),
        t.dtype_de("cidade").nome(), t.dtype_de("data").nome(), t.dtype_de("ativo").nome(),
    )
    print("cidade dicionarizada:", t.pegar("cidade").eh_dicionarizada(),
          "| cardinalidade", t.pegar("cidade").cardinalidade())
