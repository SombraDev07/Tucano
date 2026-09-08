"""Datas — conversao civil <-> dias desde 1970-01-01 (M2.5).

Armazenamento: dias desde a epoch, no slab de inteiros da `Coluna`, com
`DType.DATA` como tipo logico. Data e fisicamente um inteiro; o tipo logico e
que decide a semantica (mesma separacao que o Arrow faz com Date32).

Algoritmo civil <-> dias: Howard Hinnant, `days_from_civil` / `civil_from_days`,
valido para o calendario proleptico gregoriano. Divisao no Mojo e piso (como em
Python), entao as correcoes para anos negativos do original em C++ nao sao
necessarias.
"""


@fieldwise_init
struct DataCivil(Copyable, Movable, ImplicitlyCopyable):
    """Ano/mes/dia do calendario."""

    var ano: Int
    var mes: Int
    var dia: Int


def eh_bissexto(ano: Int) -> Bool:
    if ano % 4 != 0:
        return False
    if ano % 100 != 0:
        return True
    return ano % 400 == 0


def dias_no_mes(ano: Int, mes: Int) -> Int:
    if mes == 2:
        if eh_bissexto(ano):
            return 29
        return 28
    if mes == 4 or mes == 6 or mes == 9 or mes == 11:
        return 30
    return 31


def dias_desde_epoch(ano: Int, mes: Int, dia: Int) -> Int:
    """Dias desde 1970-01-01. Negativo antes da epoch."""
    var y = ano
    if mes <= 2:
        y -= 1
    var era = y // 400
    var yoe = y - era * 400
    var mp = mes + 9
    if mes > 2:
        mp = mes - 3
    var doy = (153 * mp + 2) // 5 + dia - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def civil_de_dias(dias: Int) -> DataCivil:
    """Inverso de `dias_desde_epoch`."""
    var z = dias + 719468
    var era = z // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m = mp + 3
    if mp >= 10:
        m = mp - 9
    if m <= 2:
        y += 1
    return DataCivil(y, m, d)


def ano_de_dias(dias: Int) -> Int:
    return civil_de_dias(dias).ano


def mes_de_dias(dias: Int) -> Int:
    return civil_de_dias(dias).mes


def dia_de_dias(dias: Int) -> Int:
    return civil_de_dias(dias).dia


def _digitos(t: String, inicio: Int, fim: Int) -> Int:
    var b = t.as_bytes()
    var v = 0
    for i in range(inicio, fim):
        v = v * 10 + (Int(b[i]) - 48)
    return v


def _forma_iso(t: String) -> Bool:
    """Confere o formato AAAA-MM-DD, sem validar o calendario."""
    if t.byte_length() != 10:
        return False
    var b = t.as_bytes()
    for i in range(10):
        if i == 4 or i == 7:
            if b[i] != UInt8(45):
                return False
        else:
            if b[i] < UInt8(48) or b[i] > UInt8(57):
                return False
    return True


def eh_data_iso(texto: String) -> Bool:
    """True quando o texto e uma data AAAA-MM-DD valida no calendario."""
    var t = String(texto.strip())
    if not _forma_iso(t):
        return False
    var m = _digitos(t, 5, 7)
    if m < 1 or m > 12:
        return False
    var a = _digitos(t, 0, 4)
    var d = _digitos(t, 8, 10)
    return d >= 1 and d <= dias_no_mes(a, m)


def parse_data_iso(texto: String) raises -> Int:
    """AAAA-MM-DD -> dias desde a epoch."""
    var t = String(texto.strip())
    if not _forma_iso(t):
        raise Error("data invalida (esperado AAAA-MM-DD): '" + texto + "'")
    var a = _digitos(t, 0, 4)
    var m = _digitos(t, 5, 7)
    var d = _digitos(t, 8, 10)
    if m < 1 or m > 12:
        raise Error("mes fora do intervalo 1..12: '" + texto + "'")
    if d < 1 or d > dias_no_mes(a, m):
        raise Error("dia fora do intervalo do mes: '" + texto + "'")
    return dias_desde_epoch(a, m, d)


def _pad(valor: Int, largura: Int) -> String:
    var s = String(valor)
    if valor < 0:
        return s
    while s.byte_length() < largura:
        s = "0" + s
    return s


def data_para_texto(dias: Int) -> String:
    """Dias desde a epoch -> AAAA-MM-DD."""
    var c = civil_de_dias(dias)
    return _pad(c.ano, 4) + "-" + _pad(c.mes, 2) + "-" + _pad(c.dia, 2)


# --------------------------------------------------------------- datahora
#
# `DType.DATAHORA` guarda **microssegundos desde 1970-01-01T00:00:00**, em Int64
# — mesma unidade que o Arrow usa por padrao em timestamp. A faixa cobre cerca
# de +/- 292 mil anos.
#
# Fuso horario nao e suportado: um `Z` final e aceito e ignorado, e deslocamentos
# (`+03:00`) sao recusados. Meia implementacao de fuso e pior que nenhuma —
# entra quando houver tipo com fuso de verdade.

comptime MICROS_POR_SEGUNDO = 1_000_000
comptime SEGUNDOS_POR_DIA = 86400
comptime MICROS_POR_DIA = MICROS_POR_SEGUNDO * SEGUNDOS_POR_DIA


@fieldwise_init
struct DataHoraCivil(Copyable, Movable, ImplicitlyCopyable):
    """Ano/mes/dia/hora/minuto/segundo/microssegundo."""

    var ano: Int
    var mes: Int
    var dia: Int
    var hora: Int
    var minuto: Int
    var segundo: Int
    var micro: Int


def micros_desde_epoch(
    ano: Int, mes: Int, dia: Int, hora: Int, minuto: Int, segundo: Int, micro: Int = 0
) -> Int:
    var dias = dias_desde_epoch(ano, mes, dia)
    var seg = dias * SEGUNDOS_POR_DIA + hora * 3600 + minuto * 60 + segundo
    return seg * MICROS_POR_SEGUNDO + micro


def dias_de_micros(micros: Int) -> Int:
    """Dia do calendario, com divisao de piso (correta antes da epoch)."""
    return micros // MICROS_POR_DIA


def civil_de_micros(micros: Int) -> DataHoraCivil:
    var dias = dias_de_micros(micros)
    var resto = micros - dias * MICROS_POR_DIA
    var c = civil_de_dias(dias)
    var seg = resto // MICROS_POR_SEGUNDO
    return DataHoraCivil(
        c.ano,
        c.mes,
        c.dia,
        seg // 3600,
        (seg // 60) % 60,
        seg % 60,
        resto - seg * MICROS_POR_SEGUNDO,
    )


def _forma_datahora(t: String) -> Bool:
    """AAAA-MM-DDTHH:MM:SS, com `.f+` opcional e `Z` opcional. `T` ou espaco."""
    var n = t.byte_length()
    if n < 19:
        return False
    var b = t.as_bytes()
    for i in range(10):
        if i == 4 or i == 7:
            if b[i] != UInt8(45):
                return False
        elif b[i] < UInt8(48) or b[i] > UInt8(57):
            return False
    if b[10] != UInt8(84) and b[10] != UInt8(116) and b[10] != UInt8(32):
        return False
    for i in range(11, 19):
        if i == 13 or i == 16:
            if b[i] != UInt8(58):
                return False
        elif b[i] < UInt8(48) or b[i] > UInt8(57):
            return False

    var i = 19
    if i < n and b[i] == UInt8(46):
        i += 1
        var digitos = 0
        while i < n and b[i] >= UInt8(48) and b[i] <= UInt8(57):
            i += 1
            digitos += 1
        if digitos == 0:
            return False
    if i < n and (b[i] == UInt8(90) or b[i] == UInt8(122)):
        i += 1
    return i == n


def eh_datahora_iso(texto: String) -> Bool:
    var t = String(texto.strip())
    if not _forma_datahora(t):
        return False
    var mes = _digitos(t, 5, 7)
    if mes < 1 or mes > 12:
        return False
    var ano = _digitos(t, 0, 4)
    var dia = _digitos(t, 8, 10)
    if dia < 1 or dia > dias_no_mes(ano, mes):
        return False
    if _digitos(t, 11, 13) > 23:
        return False
    if _digitos(t, 14, 16) > 59:
        return False
    return _digitos(t, 17, 19) <= 60


def parse_datahora_iso(texto: String) raises -> Int:
    """AAAA-MM-DDTHH:MM:SS[.f+][Z] -> microssegundos desde a epoch."""
    var t = String(texto.strip())
    if not eh_datahora_iso(t):
        raise Error(
            "datahora invalida (esperado AAAA-MM-DDTHH:MM:SS[.f][Z]): '" + texto + "'"
        )
    var micro = 0
    if t.byte_length() > 19:
        var b = t.as_bytes()
        if b[19] == UInt8(46):
            var i = 20
            var casas = 0
            while i < t.byte_length() and b[i] >= UInt8(48) and b[i] <= UInt8(57):
                if casas < 6:
                    micro = micro * 10 + (Int(b[i]) - 48)
                    casas += 1
                i += 1
            while casas < 6:
                micro *= 10
                casas += 1
    return micros_desde_epoch(
        _digitos(t, 0, 4),
        _digitos(t, 5, 7),
        _digitos(t, 8, 10),
        _digitos(t, 11, 13),
        _digitos(t, 14, 16),
        _digitos(t, 17, 19),
        micro,
    )


def datahora_para_texto(micros: Int) -> String:
    """Microssegundos -> AAAA-MM-DDTHH:MM:SS, com fracao so quando existir."""
    var c = civil_de_micros(micros)
    var s = (
        _pad(c.ano, 4) + "-" + _pad(c.mes, 2) + "-" + _pad(c.dia, 2)
        + "T" + _pad(c.hora, 2) + ":" + _pad(c.minuto, 2) + ":" + _pad(c.segundo, 2)
    )
    if c.micro != 0:
        s += "." + _pad(c.micro, 6)
    return s
