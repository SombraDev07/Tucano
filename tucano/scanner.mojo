"""Scanner CSV tipado (M5): bytes -> campos -> buffers.

O leitor antigo era `arquivo -> String -> split -> objetos`: alocava uma `String`
por celula antes de saber o tipo dela. Custava 7226 ns/linha.

Aqui o arquivo e lido uma vez como bytes. O scanner marca as **fronteiras** dos
campos — dois inteiros por celula, nenhuma alocacao — e o parser tipado le
direto do buffer para o slab da coluna. Texto so vira `String` no fim, e so em
coluna de texto.

Suporta aspas RFC 4180: delimitador e quebra de linha dentro de campo citado, e
`""` como aspa escapada.
"""

from .dtype import DType
from .coluna import Coluna
from .tabela import Tabela
from .schema import Campo, Schema
from .datas import dias_no_mes, dias_desde_epoch, micros_desde_epoch

comptime _ASPA = UInt8(34)
comptime _CR = UInt8(13)
comptime _LF = UInt8(10)
comptime _ESPACO = UInt8(32)
comptime _TAB = UInt8(9)
comptime _MENOS = UInt8(45)
comptime _MAIS = UInt8(43)
comptime _PONTO = UInt8(46)
comptime _ZERO = UInt8(48)
comptime _NOVE = UInt8(57)
comptime _BARRA = UInt8(47)

comptime _MAX_MANTISSA = Int64(9007199254740992)  # 2^53


struct Campos(Copyable, Movable):
    """Fronteiras dos campos dentro do buffer de bytes.

    `inicio[l * n_cols + c]` e `fim[...]` delimitam a celula. Nenhuma `String` e
    criada durante a varredura.
    """

    var inicio: List[Int]
    var fim: List[Int]
    var citado: List[UInt8]
    var n_linhas: Int
    var n_cols: Int

    def __init__(
        out self,
        var inicio: List[Int],
        var fim: List[Int],
        var citado: List[UInt8],
        n_linhas: Int,
        n_cols: Int,
    ):
        self.inicio = inicio^
        self.fim = fim^
        self.citado = citado^
        self.n_linhas = n_linhas
        self.n_cols = n_cols

    def indice(self, linha: Int, col: Int) -> Int:
        return linha * self.n_cols + col


def _eh_espaco(b: UInt8) -> Bool:
    return b == _ESPACO or b == _TAB or b == _CR


def _minusculo(b: UInt8) -> UInt8:
    if b >= UInt8(65) and b <= UInt8(90):
        return b + UInt8(32)
    return b


def _casa(bytes: List[UInt8], ini: Int, fim: Int, alvo: String) -> Bool:
    """Compara a faixa com um literal ASCII, ignorando caixa."""
    var a = alvo.as_bytes()
    if fim - ini != len(a):
        return False
    for i in range(len(a)):
        if _minusculo(bytes[ini + i]) != _minusculo(a[i]):
            return False
    return True


def _truncar(
    mut inicio: List[Int], mut fim: List[Int], mut citado: List[UInt8], ate: Int
):
    """Desfaz os campos de uma linha descartada."""
    while len(inicio) > ate:
        _ = inicio.pop()
        _ = fim.pop()
        _ = citado.pop()


def _aparar(bytes: List[UInt8], ini_in: Int, fim_in: Int) -> Tuple[Int, Int]:
    """Remove espaco em branco das pontas, sem alocar."""
    var ini = ini_in
    var fim = fim_in
    while ini < fim and _eh_espaco(bytes[ini]):
        ini += 1
    while fim > ini and _eh_espaco(bytes[fim - 1]):
        fim -= 1
    return (ini, fim)


# ------------------------------------------------------------------ varredura


def escanear(
    bytes: List[UInt8], delim: UInt8, pular: Int = 0, limite: Int = -1
) raises -> Campos:
    """Marca as fronteiras dos campos. Uma passada, sem alocar por celula."""
    var n = len(bytes)
    var inicio = List[Int]()
    var fim = List[Int]()
    var citado = List[UInt8]()
    var n_cols = 0
    var n_linhas = 0
    var linhas_puladas = 0

    var i = 0
    while i < n:
        # campos vao direto para as listas de saida; se a linha for descartada,
        # o comprimento volta para a marca. Sem alocacao por linha.
        var marca = len(inicio)

        while True:
            var c_ini = i
            var c_fim: Int
            var c_cit = UInt8(0)

            if i < n and bytes[i] == _ASPA:
                c_cit = UInt8(1)
                i += 1
                c_ini = i
                while i < n:
                    if bytes[i] == _ASPA:
                        if i + 1 < n and bytes[i + 1] == _ASPA:
                            i += 2
                            continue
                        break
                    i += 1
                if i >= n:
                    raise Error("CSV com aspas nao fechadas")
                c_fim = i
                i += 1  # consome a aspa final
                while i < n and bytes[i] != delim and bytes[i] != _LF:
                    i += 1
            else:
                while i < n and bytes[i] != delim and bytes[i] != _LF:
                    i += 1
                c_fim = i

            var par = _aparar(bytes, c_ini, c_fim)
            inicio.append(par[0])
            fim.append(par[1])
            citado.append(c_cit)

            if i < n and bytes[i] == delim:
                i += 1
                continue
            break

        if i < n and bytes[i] == _LF:
            i += 1

        var campos_na_linha = len(inicio) - marca

        # linha em branco: descarta
        if campos_na_linha == 1 and fim[marca] == inicio[marca]:
            _truncar(inicio, fim, citado, marca)
            continue

        if linhas_puladas < pular:
            linhas_puladas += 1
            _truncar(inicio, fim, citado, marca)
            continue

        if n_cols == 0:
            n_cols = campos_na_linha
        elif campos_na_linha != n_cols:
            raise Error(
                "linha "
                + String(n_linhas + 1)
                + " tem "
                + String(campos_na_linha)
                + " campos, esperado "
                + String(n_cols)
            )
        n_linhas += 1

        if limite >= 0 and n_linhas >= limite:
            break

    return Campos(inicio^, fim^, citado^, n_linhas, n_cols)


# --------------------------------------------------------------- parsers


def eh_na(bytes: List[UInt8], ini: Int, fim: Int) -> Bool:
    if ini >= fim:
        return True
    return (
        _casa(bytes, ini, fim, "na")
        or _casa(bytes, ini, fim, "nan")
        or _casa(bytes, ini, fim, "null")
        or _casa(bytes, ini, fim, "none")
        or _casa(bytes, ini, fim, "n/a")
    )


def eh_bool(bytes: List[UInt8], ini: Int, fim: Int) -> Bool:
    return _casa(bytes, ini, fim, "true") or _casa(bytes, ini, fim, "false")


def para_bool(bytes: List[UInt8], ini: Int, fim: Int) -> Bool:
    return _casa(bytes, ini, fim, "true")


def parse_int(bytes: List[UInt8], ini: Int, fim: Int, mut ok: Bool) -> Int64:
    ok = False
    if ini >= fim:
        return Int64(0)
    var i = ini
    var negativo = False
    if bytes[i] == _MENOS:
        negativo = True
        i += 1
    elif bytes[i] == _MAIS:
        i += 1
    if i >= fim:
        return Int64(0)
    var v = Int64(0)
    var digitos = 0
    while i < fim:
        var b = bytes[i]
        if b < _ZERO or b > _NOVE:
            return Int64(0)
        v = v * 10 + Int64(Int(b) - 48)
        digitos += 1
        if digitos > 18:
            return Int64(0)  # nao arrisca overflow: cai para real ou texto
        i += 1
    ok = True
    if negativo:
        return -v
    return v


def _pot10(k: Int) -> Float64:
    """10^k exato para k <= 22 — 10^22 e a maior potencia de 10 exata em Float64.

    Tipicamente k e 1 ou 2 (uma ou duas casas decimais), entao o laco e curto.
    """
    var v = Float64(1)
    for _ in range(k):
        v *= 10.0
    return v


def parse_float(bytes: List[UInt8], ini: Int, fim: Int, mut ok: Bool) raises -> Float64:
    """Decimal simples direto dos bytes; casos raros caem no `atof`.

    Com mantissa <= 2^53 e ate 22 casas, `mantissa / 10^k` em Float64 e
    corretamente arredondado — resultado identico ao de um parser completo.
    """
    ok = False
    if ini >= fim:
        return 0.0

    var i = ini
    var negativo = False
    if bytes[i] == _MENOS:
        negativo = True
        i += 1
    elif bytes[i] == _MAIS:
        i += 1

    var mantissa = Int64(0)
    var casas = 0
    var digitos = 0
    var viu_ponto = False
    var simples = True

    while i < fim:
        var b = bytes[i]
        if b >= _ZERO and b <= _NOVE:
            mantissa = mantissa * 10 + Int64(Int(b) - 48)
            digitos += 1
            if viu_ponto:
                casas += 1
            if mantissa > _MAX_MANTISSA or casas > 22:
                simples = False
                break
        elif b == _PONTO and not viu_ponto:
            viu_ponto = True
        else:
            # expoente, ou lixo: deixa o fallback decidir
            simples = False
            break
        i += 1

    if simples and digitos > 0:
        ok = True
        var v = Float64(mantissa) / _pot10(casas)
        if negativo:
            return -v
        return v

    # fallback: so aqui vira String
    var texto = String(from_utf8=Span(bytes)[ini:fim])
    try:
        var v = atof(texto)
        ok = True
        return v
    except:
        ok = False
        return 0.0


def _digitos(bytes: List[UInt8], ini: Int, k: Int) -> Int:
    var v = 0
    for i in range(k):
        v = v * 10 + (Int(bytes[ini + i]) - 48)
    return v


def _forma_data(bytes: List[UInt8], ini: Int, fim: Int) -> Bool:
    if fim - ini != 10:
        return False
    for i in range(10):
        var b = bytes[ini + i]
        if i == 4 or i == 7:
            if b != _MENOS:
                return False
        elif b < _ZERO or b > _NOVE:
            return False
    return True


def eh_data(bytes: List[UInt8], ini: Int, fim: Int) -> Bool:
    if not _forma_data(bytes, ini, fim):
        return False
    var m = _digitos(bytes, ini + 5, 2)
    if m < 1 or m > 12:
        return False
    var a = _digitos(bytes, ini, 4)
    var d = _digitos(bytes, ini + 8, 2)
    return d >= 1 and d <= dias_no_mes(a, m)


def parse_data(bytes: List[UInt8], ini: Int, fim: Int) -> Int64:
    return Int64(
        dias_desde_epoch(
            _digitos(bytes, ini, 4), _digitos(bytes, ini + 5, 2), _digitos(bytes, ini + 8, 2)
        )
    )


comptime _T_MAI = UInt8(84)
comptime _T_MIN = UInt8(116)
comptime _Z_MAI = UInt8(90)
comptime _Z_MIN = UInt8(122)
comptime _DOIS_PONTOS = UInt8(58)


def _forma_datahora(bytes: List[UInt8], ini: Int, fim: Int) -> Bool:
    var n = fim - ini
    if n < 19:
        return False
    for i in range(10):
        var b = bytes[ini + i]
        if i == 4 or i == 7:
            if b != _MENOS:
                return False
        elif b < _ZERO or b > _NOVE:
            return False
    var sep = bytes[ini + 10]
    if sep != _T_MAI and sep != _T_MIN and sep != _ESPACO:
        return False
    for i in range(11, 19):
        var b = bytes[ini + i]
        if i == 13 or i == 16:
            if b != _DOIS_PONTOS:
                return False
        elif b < _ZERO or b > _NOVE:
            return False

    var i = ini + 19
    if i < fim and bytes[i] == _PONTO:
        i += 1
        var digitos = 0
        while i < fim and bytes[i] >= _ZERO and bytes[i] <= _NOVE:
            i += 1
            digitos += 1
        if digitos == 0:
            return False
    if i < fim and (bytes[i] == _Z_MAI or bytes[i] == _Z_MIN):
        i += 1
    return i == fim


def eh_datahora(bytes: List[UInt8], ini: Int, fim: Int) -> Bool:
    if not _forma_datahora(bytes, ini, fim):
        return False
    var mes = _digitos(bytes, ini + 5, 2)
    if mes < 1 or mes > 12:
        return False
    var ano = _digitos(bytes, ini, 4)
    var dia = _digitos(bytes, ini + 8, 2)
    if dia < 1 or dia > dias_no_mes(ano, mes):
        return False
    if _digitos(bytes, ini + 11, 2) > 23:
        return False
    if _digitos(bytes, ini + 14, 2) > 59:
        return False
    return _digitos(bytes, ini + 17, 2) <= 60


def parse_datahora(bytes: List[UInt8], ini: Int, fim: Int) -> Int64:
    var micro = 0
    var i = ini + 19
    if i < fim and bytes[i] == _PONTO:
        i += 1
        var casas = 0
        while i < fim and bytes[i] >= _ZERO and bytes[i] <= _NOVE:
            if casas < 6:
                micro = micro * 10 + (Int(bytes[i]) - 48)
                casas += 1
            i += 1
        while casas < 6:
            micro *= 10
            casas += 1
    return Int64(
        micros_desde_epoch(
            _digitos(bytes, ini, 4),
            _digitos(bytes, ini + 5, 2),
            _digitos(bytes, ini + 8, 2),
            _digitos(bytes, ini + 11, 2),
            _digitos(bytes, ini + 14, 2),
            _digitos(bytes, ini + 17, 2),
            micro,
        )
    )


def para_texto(bytes: List[UInt8], ini: Int, fim: Int, citado: Bool) raises -> String:
    """Materializa o texto. Desescapa `""` apenas quando o campo era citado."""
    if ini >= fim:
        return ""
    if not citado:
        return String(from_utf8=Span(bytes)[ini:fim])
    var limpo = List[UInt8](capacity=fim - ini)
    var i = ini
    while i < fim:
        limpo.append(bytes[i])
        if bytes[i] == _ASPA and i + 1 < fim and bytes[i + 1] == _ASPA:
            i += 2
            continue
        i += 1
    return String(from_utf8=Span(limpo))
