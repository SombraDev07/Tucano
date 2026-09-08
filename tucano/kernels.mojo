"""Kernels SIMD sobre slabs contiguos (M4).

Este modulo **nao** importa `tucano.dtype`: o `DType` aqui e o do Mojo, usado
para parametrizar `SIMD`. Manter os kernels isolados evita a colisao de nome com
o `DType` logico do Tucano.

Contrato dos kernels:
- entrada e saida sao `List` contiguas de tamanho `n`;
- o laco principal processa `W` elementos por iteracao e a cauda vai escalar;
- nenhum kernel conhece `Coluna`, `Vetor` ou `Tabela`.

Mascara de ausentes: `UInt8`, 0 = presente, 1 = ausente.

Logica de tres valores, na ordem do reticulado de Kleene:

    FALSO = 0  <  DESCONHECIDO = 1  <  VERDADEIRO = 2

Com essa ordem, `E` e `min`, `OU` e `max` e `NAO` e `2 - x` — cada um vira uma
unica instrucao SIMD.
"""

from std.sys.info import simd_width_of

comptime W_F64 = simd_width_of[DType.float64]()
comptime W_U8 = simd_width_of[DType.uint8]()
comptime W_I32 = simd_width_of[DType.int32]()
comptime W_I64 = simd_width_of[DType.int64]()

comptime K_FALSO = UInt8(0)
comptime K_DESCONHECIDO = UInt8(1)
comptime K_VERDADEIRO = UInt8(2)


def largura_f64() -> Int:
    return W_F64


def largura_u8() -> Int:
    return W_U8


# ------------------------------------------------------------- aritmetica


def add_f64(a: List[Float64], b: List[Float64], mut out: List[Float64], n: Int):
    var pa = a.unsafe_ptr()
    var pb = b.unsafe_ptr()
    var po = out.unsafe_ptr()
    var i = 0
    while i + W_F64 <= n:
        po.unsafe_store(i, pa.unsafe_load[width=W_F64](i) + pb.unsafe_load[width=W_F64](i))
        i += W_F64
    while i < n:
        po.unsafe_store(i, pa.unsafe_load(i) + pb.unsafe_load(i))
        i += 1


def sub_f64(a: List[Float64], b: List[Float64], mut out: List[Float64], n: Int):
    var pa = a.unsafe_ptr()
    var pb = b.unsafe_ptr()
    var po = out.unsafe_ptr()
    var i = 0
    while i + W_F64 <= n:
        po.unsafe_store(i, pa.unsafe_load[width=W_F64](i) - pb.unsafe_load[width=W_F64](i))
        i += W_F64
    while i < n:
        po.unsafe_store(i, pa.unsafe_load(i) - pb.unsafe_load(i))
        i += 1


def mul_f64(a: List[Float64], b: List[Float64], mut out: List[Float64], n: Int):
    var pa = a.unsafe_ptr()
    var pb = b.unsafe_ptr()
    var po = out.unsafe_ptr()
    var i = 0
    while i + W_F64 <= n:
        po.unsafe_store(i, pa.unsafe_load[width=W_F64](i) * pb.unsafe_load[width=W_F64](i))
        i += W_F64
    while i < n:
        po.unsafe_store(i, pa.unsafe_load(i) * pb.unsafe_load(i))
        i += 1


def div_f64(a: List[Float64], b: List[Float64], mut out: List[Float64], n: Int):
    var pa = a.unsafe_ptr()
    var pb = b.unsafe_ptr()
    var po = out.unsafe_ptr()
    var i = 0
    while i + W_F64 <= n:
        po.unsafe_store(i, pa.unsafe_load[width=W_F64](i) / pb.unsafe_load[width=W_F64](i))
        i += W_F64
    while i < n:
        po.unsafe_store(i, pa.unsafe_load(i) / pb.unsafe_load(i))
        i += 1


# ---------------------------------------------------------------- ausentes


def ou_na(a: List[UInt8], b: List[UInt8], mut out: List[UInt8], n: Int):
    """Propaga ausencia: out = a | b."""
    var pa = a.unsafe_ptr()
    var pb = b.unsafe_ptr()
    var po = out.unsafe_ptr()
    var i = 0
    while i + W_U8 <= n:
        po.unsafe_store(i, pa.unsafe_load[width=W_U8](i) | pb.unsafe_load[width=W_U8](i))
        i += W_U8
    while i < n:
        po.unsafe_store(i, pa.unsafe_load(i) | pb.unsafe_load(i))
        i += 1


def contar_marcados(m: List[UInt8], n: Int) -> Int:
    var p = m.unsafe_ptr()
    var acc = SIMD[DType.int32, W_U8](0)
    var i = 0
    while i + W_U8 <= n:
        acc += p.unsafe_load[width=W_U8](i).cast[DType.int32]()
        i += W_U8
    var total = Int(acc.reduce_add())
    while i < n:
        total += Int(p.unsafe_load(i))
        i += 1
    return total


# -------------------------------------------------------------- comparacao
#
# Produzem diretamente a mascara de tres valores:
#   ausente em qualquer lado -> DESCONHECIDO (1)
#   senao                    -> FALSO (0) ou VERDADEIRO (2)
#
# `tri = comparacao * 2 * (1 - na) + na` faz isso sem desvio dentro do laco.


def _cmp_tri_escalar(c: Bool, na: UInt8) -> UInt8:
    if na != 0:
        return K_DESCONHECIDO
    if c:
        return K_VERDADEIRO
    return K_FALSO


def cmp_f64(
    op: Int,
    a: List[Float64],
    b: List[Float64],
    na: List[UInt8],
    mut out: List[UInt8],
    n: Int,
):
    """op: 0 gt, 1 ge, 2 lt, 3 le, 4 eq, 5 ne."""
    var pa = a.unsafe_ptr()
    var pb = b.unsafe_ptr()
    var pn = na.unsafe_ptr()
    var po = out.unsafe_ptr()
    var i = 0

    # o tipo da comparacao e decidido FORA do laco
    if op == 0:
        while i + W_F64 <= n:
            var m = pa.unsafe_load[width=W_F64](i).gt(pb.unsafe_load[width=W_F64](i))
            po.unsafe_store(i, _combinar[W_F64](m, pn.unsafe_load[width=W_F64](i)))
            i += W_F64
    elif op == 1:
        while i + W_F64 <= n:
            var m = pa.unsafe_load[width=W_F64](i).ge(pb.unsafe_load[width=W_F64](i))
            po.unsafe_store(i, _combinar[W_F64](m, pn.unsafe_load[width=W_F64](i)))
            i += W_F64
    elif op == 2:
        while i + W_F64 <= n:
            var m = pa.unsafe_load[width=W_F64](i).lt(pb.unsafe_load[width=W_F64](i))
            po.unsafe_store(i, _combinar[W_F64](m, pn.unsafe_load[width=W_F64](i)))
            i += W_F64
    elif op == 3:
        while i + W_F64 <= n:
            var m = pa.unsafe_load[width=W_F64](i).le(pb.unsafe_load[width=W_F64](i))
            po.unsafe_store(i, _combinar[W_F64](m, pn.unsafe_load[width=W_F64](i)))
            i += W_F64
    elif op == 4:
        while i + W_F64 <= n:
            var m = pa.unsafe_load[width=W_F64](i).eq(pb.unsafe_load[width=W_F64](i))
            po.unsafe_store(i, _combinar[W_F64](m, pn.unsafe_load[width=W_F64](i)))
            i += W_F64
    else:
        while i + W_F64 <= n:
            var m = pa.unsafe_load[width=W_F64](i).ne(pb.unsafe_load[width=W_F64](i))
            po.unsafe_store(i, _combinar[W_F64](m, pn.unsafe_load[width=W_F64](i)))
            i += W_F64

    while i < n:
        var x = pa.unsafe_load(i)
        var y = pb.unsafe_load(i)
        var c: Bool
        if op == 0:
            c = x > y
        elif op == 1:
            c = x >= y
        elif op == 2:
            c = x < y
        elif op == 3:
            c = x <= y
        elif op == 4:
            c = x == y
        else:
            c = x != y
        po.unsafe_store(i, _cmp_tri_escalar(c, pn.unsafe_load(i)))
        i += 1


def _combinar[w: Int](
    m: SIMD[DType.bool, w], na: SIMD[DType.uint8, w]
) -> SIMD[DType.uint8, w]:
    """comparacao + ausencia -> mascara de tres valores, sem desvio."""
    var cmp = m.cast[DType.uint8]()
    return cmp * 2 * (1 - na) + na


def cmp_i32(
    op: Int,
    a: List[Int32],
    valor: Int32,
    na: List[UInt8],
    mut out: List[UInt8],
    n: Int,
):
    """Compara codigos de dicionario contra uma constante.

    E o que transforma `cidade == "SP"` em comparacao de inteiros: o texto vira
    um codigo uma unica vez, e o laco e SIMD puro.
    """
    var pa = a.unsafe_ptr()
    var pn = na.unsafe_ptr()
    var po = out.unsafe_ptr()
    var alvo = SIMD[DType.int32, W_I32](valor)
    var i = 0
    if op == 4:
        while i + W_I32 <= n:
            var m = pa.unsafe_load[width=W_I32](i).eq(alvo)
            po.unsafe_store(i, _combinar[W_I32](m, pn.unsafe_load[width=W_I32](i)))
            i += W_I32
    else:
        while i + W_I32 <= n:
            var m = pa.unsafe_load[width=W_I32](i).ne(alvo)
            po.unsafe_store(i, _combinar[W_I32](m, pn.unsafe_load[width=W_I32](i)))
            i += W_I32
    while i < n:
        var c = pa.unsafe_load(i) == valor
        if op != 4:
            c = not c
        po.unsafe_store(i, _cmp_tri_escalar(c, pn.unsafe_load(i)))
        i += 1


# ------------------------------------------------------ logica de 3 valores


def tri_e(a: List[UInt8], b: List[UInt8], mut out: List[UInt8], n: Int):
    """E de Kleene = min, na ordem FALSO < DESCONHECIDO < VERDADEIRO."""
    var pa = a.unsafe_ptr()
    var pb = b.unsafe_ptr()
    var po = out.unsafe_ptr()
    var i = 0
    while i + W_U8 <= n:
        po.unsafe_store(
            i, min(pa.unsafe_load[width=W_U8](i), pb.unsafe_load[width=W_U8](i))
        )
        i += W_U8
    while i < n:
        po.unsafe_store(i, min(pa.unsafe_load(i), pb.unsafe_load(i)))
        i += 1


def tri_ou(a: List[UInt8], b: List[UInt8], mut out: List[UInt8], n: Int):
    """OU de Kleene = max."""
    var pa = a.unsafe_ptr()
    var pb = b.unsafe_ptr()
    var po = out.unsafe_ptr()
    var i = 0
    while i + W_U8 <= n:
        po.unsafe_store(
            i, max(pa.unsafe_load[width=W_U8](i), pb.unsafe_load[width=W_U8](i))
        )
        i += W_U8
    while i < n:
        po.unsafe_store(i, max(pa.unsafe_load(i), pb.unsafe_load(i)))
        i += 1


def tri_nao(a: List[UInt8], mut out: List[UInt8], n: Int):
    """NAO de Kleene = 2 - x. Desconhecido continua Desconhecido."""
    var pa = a.unsafe_ptr()
    var po = out.unsafe_ptr()
    var dois = SIMD[DType.uint8, W_U8](2)
    var i = 0
    while i + W_U8 <= n:
        po.unsafe_store(i, dois - pa.unsafe_load[width=W_U8](i))
        i += W_U8
    while i < n:
        po.unsafe_store(i, UInt8(2) - pa.unsafe_load(i))
        i += 1


def tri_para_keep(m: List[UInt8], mut keep: List[UInt8], n: Int):
    """Selecao: so VERDADEIRO passa. Desconhecido cai fora."""
    var pm = m.unsafe_ptr()
    var pk = keep.unsafe_ptr()
    var alvo = SIMD[DType.uint8, W_U8](K_VERDADEIRO)
    var i = 0
    while i + W_U8 <= n:
        pk.unsafe_store(i, pm.unsafe_load[width=W_U8](i).eq(alvo).cast[DType.uint8]())
        i += W_U8
    while i < n:
        if pm.unsafe_load(i) == K_VERDADEIRO:
            pk.unsafe_store(i, UInt8(1))
        else:
            pk.unsafe_store(i, UInt8(0))
        i += 1


# ----------------------------------------------------------------- reducoes


def soma_f64(dados: List[Float64], na: List[UInt8], n: Int) -> Float64:
    """Soma ignorando ausentes, sem desvio no laco: zera o que e ausente."""
    var pd = dados.unsafe_ptr()
    var pn = na.unsafe_ptr()
    var acc = SIMD[DType.float64, W_F64](0)
    var i = 0
    while i + W_F64 <= n:
        var presente = (1 - pn.unsafe_load[width=W_F64](i)).cast[DType.float64]()
        acc += pd.unsafe_load[width=W_F64](i) * presente
        i += W_F64
    var total = acc.reduce_add()
    while i < n:
        if pn.unsafe_load(i) == 0:
            total += pd.unsafe_load(i)
        i += 1
    return total


def soma_f64_densa(dados: List[Float64], n: Int) -> Float64:
    """Soma sem mascara — caminho para coluna sem nenhum ausente.

    Vale um kernel proprio: quando nao ha ausente, desempacotar o bitmap para
    bytes custa mais que a propria reducao.
    """
    var p = dados.unsafe_ptr()
    var acc = SIMD[DType.float64, W_F64](0)
    var i = 0
    while i + W_F64 <= n:
        acc += p.unsafe_load[width=W_F64](i)
        i += W_F64
    var total = acc.reduce_add()
    while i < n:
        total += p.unsafe_load(i)
        i += 1
    return total


def soma_i64_densa(dados: List[Int64], n: Int) -> Float64:
    var p = dados.unsafe_ptr()
    var acc = SIMD[DType.int64, W_I64](0)
    var i = 0
    while i + W_I64 <= n:
        acc += p.unsafe_load[width=W_I64](i)
        i += W_I64
    var total = Int(acc.reduce_add())
    while i < n:
        total += Int(p.unsafe_load(i))
        i += 1
    return Float64(total)


def minimo_f64_densa(dados: List[Float64], n: Int) raises -> Float64:
    if n == 0:
        raise Error("sem valores validos")
    var p = dados.unsafe_ptr()
    var acc = SIMD[DType.float64, W_F64](p.unsafe_load(0))
    var i = 0
    while i + W_F64 <= n:
        acc = min(acc, p.unsafe_load[width=W_F64](i))
        i += W_F64
    var menor = acc.reduce_min()
    while i < n:
        var v = p.unsafe_load(i)
        if v < menor:
            menor = v
        i += 1
    return menor


def maximo_f64_densa(dados: List[Float64], n: Int) raises -> Float64:
    if n == 0:
        raise Error("sem valores validos")
    var p = dados.unsafe_ptr()
    var acc = SIMD[DType.float64, W_F64](p.unsafe_load(0))
    var i = 0
    while i + W_F64 <= n:
        acc = max(acc, p.unsafe_load[width=W_F64](i))
        i += W_F64
    var maior = acc.reduce_max()
    while i < n:
        var v = p.unsafe_load(i)
        if v > maior:
            maior = v
        i += 1
    return maior


def soma_i64(dados: List[Int64], na: List[UInt8], n: Int) -> Float64:
    """Soma de slab inteiro, acumulando em Int64 antes de converter."""
    var pd = dados.unsafe_ptr()
    var pn = na.unsafe_ptr()
    var acc = SIMD[DType.int64, W_I64](0)
    var i = 0
    while i + W_I64 <= n:
        var presente = (1 - pn.unsafe_load[width=W_I64](i)).cast[DType.int64]()
        acc += pd.unsafe_load[width=W_I64](i) * presente
        i += W_I64
    var total = Int(acc.reduce_add())
    while i < n:
        if pn.unsafe_load(i) == 0:
            total += Int(pd.unsafe_load(i))
        i += 1
    return Float64(total)


comptime _MUITO_GRANDE = Float64(1.0e308)


def minimo_f64(dados: List[Float64], na: List[UInt8], n: Int) raises -> Float64:
    """Minimo ignorando ausentes: troca ausente por +inf antes de reduzir."""
    var pd = dados.unsafe_ptr()
    var pn = na.unsafe_ptr()
    var acc = SIMD[DType.float64, W_F64](_MUITO_GRANDE)
    var um = SIMD[DType.uint8, W_F64](1)
    var grande = SIMD[DType.float64, W_F64](_MUITO_GRANDE)
    var i = 0
    while i + W_F64 <= n:
        var m = pn.unsafe_load[width=W_F64](i).eq(um)
        acc = min(acc, m.select(grande, pd.unsafe_load[width=W_F64](i)))
        i += W_F64
    var menor = acc.reduce_min()
    var achou = menor < _MUITO_GRANDE
    while i < n:
        if pn.unsafe_load(i) == 0:
            var v = pd.unsafe_load(i)
            if not achou or v < menor:
                menor = v
                achou = True
        i += 1
    if not achou:
        raise Error("sem valores validos")
    return menor


def maximo_f64(dados: List[Float64], na: List[UInt8], n: Int) raises -> Float64:
    """Maximo ignorando ausentes: troca ausente por -inf antes de reduzir."""
    var pd = dados.unsafe_ptr()
    var pn = na.unsafe_ptr()
    var acc = SIMD[DType.float64, W_F64](-_MUITO_GRANDE)
    var um = SIMD[DType.uint8, W_F64](1)
    var pequeno = SIMD[DType.float64, W_F64](-_MUITO_GRANDE)
    var i = 0
    while i + W_F64 <= n:
        var m = pn.unsafe_load[width=W_F64](i).eq(um)
        acc = max(acc, m.select(pequeno, pd.unsafe_load[width=W_F64](i)))
        i += W_F64
    var maior = acc.reduce_max()
    var achou = maior > -_MUITO_GRANDE
    while i < n:
        if pn.unsafe_load(i) == 0:
            var v = pd.unsafe_load(i)
            if not achou or v > maior:
                maior = v
                achou = True
        i += 1
    if not achou:
        raise Error("sem valores validos")
    return maior


def minimo_i64(dados: List[Int64], na: List[UInt8], n: Int) raises -> Float64:
    var pd = dados.unsafe_ptr()
    var pn = na.unsafe_ptr()
    var achou = False
    var menor = Int64(0)
    for i in range(n):
        if pn.unsafe_load(i) != 0:
            continue
        var v = pd.unsafe_load(i)
        if not achou or v < menor:
            menor = v
            achou = True
    if not achou:
        raise Error("sem valores validos")
    return Float64(menor)


def maximo_i64(dados: List[Int64], na: List[UInt8], n: Int) raises -> Float64:
    var pd = dados.unsafe_ptr()
    var pn = na.unsafe_ptr()
    var achou = False
    var maior = Int64(0)
    for i in range(n):
        if pn.unsafe_load(i) != 0:
            continue
        var v = pd.unsafe_load(i)
        if not achou or v > maior:
            maior = v
            achou = True
    if not achou:
        raise Error("sem valores validos")
    return Float64(maior)


# ------------------------------------------------------------ calendario
#
# `civil_de_dias` divide so por CONSTANTES, e o compilador troca cada divisao por
# multiplicacao e deslocamento. Em **Int64 isso nao vetoriza no AVX2**: falta a
# multiplicacao 64x64->128. Medido: ganho 1.00x.
#
# Em **Int32 vetoriza**, e ainda dobra as pistas (8 contra 4). Todos os
# intermediarios do algoritmo cabem em Int32 com folga: o maior e
# `z = dias + 719468`, na casa das centenas de milhares.
#
# E a mesma razao pela qual o slab de data deve estreitar para Int32.

comptime _COMP_ANO = 0
comptime _COMP_MES = 1
comptime _COMP_DIA = 2


def _civil_simd[
    w: Int
](dias: SIMD[DType.int32, w], comp: Int) -> SIMD[DType.int32, w]:
    var z = dias + 719468
    var era = z // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    if comp == _COMP_DIA:
        return doy - (153 * mp + 2) // 5 + 1
    # m = mp < 10 ? mp + 3 : mp - 9
    var m = mp.lt(SIMD[DType.int32, w](10)).select(mp + 3, mp - 9)
    if comp == _COMP_MES:
        return m
    return y + m.le(SIMD[DType.int32, w](2)).cast[DType.int32]()


def calendario_f64(comp: Int, dias: List[Float64], mut out: List[Float64], n: Int):
    """Extrai ano/mes/dia de um vetor de dias desde a epoch.

    Valido para `dias + 719468 >= 0`, ou seja, datas a partir do ano 1.
    """
    var pd = dias.unsafe_ptr()
    var po = out.unsafe_ptr()
    var i = 0
    while i + W_I32 <= n:
        var d = pd.unsafe_load[width=W_I32](i).cast[DType.int32]()
        po.unsafe_store(i, _civil_simd[W_I32](d, comp).cast[DType.float64]())
        i += W_I32
    while i < n:
        var d = SIMD[DType.int32, 1](Int32(Int(pd.unsafe_load(i))))
        po.unsafe_store(i, Float64(Int(_civil_simd[1](d, comp))))
        i += 1
