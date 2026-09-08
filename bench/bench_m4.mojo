"""Bench M4 — SIMD contra o laco escalar equivalente.

Cada medicao compara o kernel do Tucano com um laco escalar escrito aqui mesmo,
sobre os mesmos dados. O numero e a razao entre os dois, nao uma afirmacao.
"""

from std.time import perf_counter_ns
from tucano import Coluna, Tabela, coluna, lit, lit_texto
from tucano.datas import civil_de_dias
from tucano.kernels import largura_f64, cmp_f64, add_f64, calendario_f64
from tucano.executor import avaliar_tri


def _reais(n: Int) -> List[Float64]:
    var out = List[Float64](capacity=n)
    for i in range(n):
        out.append(Float64(i % 1000) * 0.5)
    return out^


def _zeros_u8(n: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for _ in range(n):
        out.append(UInt8(0))
    return out^


def _cidades(n: Int) -> List[String]:
    var nomes = List[String]()
    nomes.append("SP")
    nomes.append("RJ")
    nomes.append("BH")
    nomes.append("POA")
    nomes.append("CWB")
    var out = List[String](capacity=n)
    for i in range(n):
        out.append(nomes[i % 5])
    return out^


def _razao(escalar: Int, simd: Int) -> Float64:
    if simd == 0:
        return 0.0
    return Float64(escalar) / Float64(simd)


def main() raises:
    var n = 5_000_000
    print("bench_m4 — n =", n, "| largura SIMD f64 =", largura_f64())
    print()

    var dados = _reais(n)
    var na = _zeros_u8(n)

    # ---- reducao: soma
    var t0 = perf_counter_ns()
    var acc = Float64(0)
    for i in range(n):
        if na[i] == 0:
            acc += dados[i]
    var t1 = perf_counter_ns()
    var ns_soma_e = t1 - t0

    var col = Coluna.de_reais("v", dados)
    t0 = perf_counter_ns()
    var soma = col.soma()
    t1 = perf_counter_ns()
    var ns_soma_s = t1 - t0
    print(
        "soma        escalar", ns_soma_e // 1000, "us | simd", ns_soma_s // 1000,
        "us | ganho", _razao(ns_soma_e, ns_soma_s), "| ok", soma == acc,
    )

    # ---- elementwise: a + b
    var b = _reais(n)
    var out = List[Float64](capacity=n)
    for _ in range(n):
        out.append(0.0)

    t0 = perf_counter_ns()
    for i in range(n):
        out[i] = dados[i] + b[i]
    t1 = perf_counter_ns()
    var ns_add_e = t1 - t0

    t0 = perf_counter_ns()
    add_f64(dados, b, out, n)
    t1 = perf_counter_ns()
    var ns_add_s = t1 - t0
    print(
        "soma vetor  escalar", ns_add_e // 1000, "us | simd", ns_add_s // 1000,
        "us | ganho", _razao(ns_add_e, ns_add_s),
    )

    # ---- comparacao -> mascara de tres valores
    var limiar = List[Float64](capacity=n)
    for _ in range(n):
        limiar.append(250.0)
    var mascara = _zeros_u8(n)

    t0 = perf_counter_ns()
    for i in range(n):
        if na[i] != 0:
            mascara[i] = UInt8(1)
        elif dados[i] > limiar[i]:
            mascara[i] = UInt8(2)
        else:
            mascara[i] = UInt8(0)
    t1 = perf_counter_ns()
    var ns_cmp_e = t1 - t0

    t0 = perf_counter_ns()
    cmp_f64(0, dados, limiar, na, mascara, n)
    t1 = perf_counter_ns()
    var ns_cmp_s = t1 - t0
    print(
        "comparacao  escalar", ns_cmp_e // 1000, "us | simd", ns_cmp_s // 1000,
        "us | ganho", _razao(ns_cmp_e, ns_cmp_s),
    )

    # ---- calendario: ano/mes/dia
    var datas = List[Float64](capacity=n)
    for i in range(n):
        datas.append(Float64(19000 + (i % 3650)))
    var cal = List[Float64](capacity=n)
    for _ in range(n):
        cal.append(0.0)

    t0 = perf_counter_ns()
    for i in range(n):
        cal[i] = Float64(civil_de_dias(Int(datas[i])).mes)
    t1 = perf_counter_ns()
    var ns_cal_e = t1 - t0

    t0 = perf_counter_ns()
    calendario_f64(1, datas, cal, n)
    t1 = perf_counter_ns()
    var ns_cal_s = t1 - t0
    print(
        "mes(data)   escalar", ns_cal_e // 1000, "us | simd", ns_cal_s // 1000,
        "us | ganho", _razao(ns_cal_e, ns_cal_s),
    )
    print("  (Int64 nao vetoriza no AVX2: o kernel calcula em Int32)")
    print()

    # ---- dictionary encoding em filtro de texto
    var m = 1_000_000
    var cidades = Coluna.de_textos("cidade", _cidades(m))
    print(
        "cidade: dicionarizada =", cidades.eh_dicionarizada(),
        "| cardinalidade =", cidades.cardinalidade(), "de", m,
    )

    var textos = _cidades(m)
    t0 = perf_counter_ns()
    var casos = 0
    for i in range(m):
        if textos[i] == "SP":
            casos += 1
    t1 = perf_counter_ns()
    var ns_txt_e = t1 - t0

    var cols = List[Coluna]()
    cols.append(cidades.copy())
    var tab = Tabela(cols^)

    # so a avaliacao do predicado, para comparar com o laco escalar equivalente
    t0 = perf_counter_ns()
    var mascara_txt = avaliar_tri(coluna("cidade").eq(lit_texto("SP")), tab.lote())
    t1 = perf_counter_ns()
    var ns_txt_s = t1 - t0

    var casados = 0
    for i in range(m):
        if mascara_txt[i] == UInt8(2):
            casados += 1
    print(
        "texto == SP escalar", ns_txt_e // 1000, "us | dicionario+simd",
        ns_txt_s // 1000, "us | ganho", _razao(ns_txt_e, ns_txt_s),
        "| casou", casados, "esperado", casos,
    )

    t0 = perf_counter_ns()
    var filtrado = tab.onde(coluna("cidade").eq(lit_texto("SP"))).coletar()
    t1 = perf_counter_ns()
    print(
        "  filtro completo (predicado + materializacao):", (t1 - t0) // 1000,
        "us ->", filtrado.linhas(), "linhas",
    )
