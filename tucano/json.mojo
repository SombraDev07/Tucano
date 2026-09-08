"""Serializacao para JSON (M7).

O painel troca **resultado agregado**, nunca a tabela de origem. Um grafico de
doze meses recebe doze linhas, mesmo que a fonte tenha milhoes — e por isso o
serializador aqui e pequeno de proposito: ele nunca precisa ser rapido, porque
nunca ve muito dado.
"""

from .coluna import Coluna
from .tabela import Tabela
from .dtype import DType


comptime _HEX = "0123456789abcdef"


def escapar(texto: String) raises -> String:
    """Escapa aspas, contrabarra e os controles que o JSON exige."""
    var out = List[UInt8]()
    out.append(UInt8(34))
    var hex = _HEX.as_bytes()
    for b in texto.as_bytes():
        if b == UInt8(34):
            out.append(UInt8(92))
            out.append(UInt8(34))
        elif b == UInt8(92):
            out.append(UInt8(92))
            out.append(UInt8(92))
        elif b == UInt8(10):
            out.append(UInt8(92))
            out.append(UInt8(110))
        elif b == UInt8(13):
            out.append(UInt8(92))
            out.append(UInt8(114))
        elif b == UInt8(9):
            out.append(UInt8(92))
            out.append(UInt8(116))
        elif b < UInt8(32):
            out.append(UInt8(92))
            out.append(UInt8(117))
            out.append(UInt8(48))
            out.append(UInt8(48))
            out.append(hex[Int(b) >> 4])
            out.append(hex[Int(b) & 0xF])
        else:
            out.append(b)
    out.append(UInt8(34))
    return String(from_utf8=Span(out))


def _celula_json(col: Coluna, i: Int) raises -> String:
    """Ausente vira `null` — nao vira zero nem string vazia."""
    if col.eh_ausente(i):
        return "null"
    if col.tipo == DType.TEXTO:
        return escapar(col.texto_bruto(i))
    if col.tipo == DType.DATA or col.tipo == DType.DATAHORA:
        return escapar(col.texto_em(i))
    if col.tipo == DType.LOGICO:
        if Int(col.logics[i]) != 0:
            return "true"
        return "false"
    if col.tipo == DType.REAL:
        return String(col.reals[i])
    return String(col.ints[i])


def tabela_para_json(t: Tabela) raises -> String:
    """Lista de objetos, um por linha."""
    var nomes = t.nomes()
    var cols = t.lote()
    var out = String("[")
    for linha in range(t.linhas()):
        if linha > 0:
            out += ","
        out += "{"
        for c in range(len(cols)):
            if c > 0:
                out += ","
            out += escapar(nomes[c]) + ":" + _celula_json(cols[c], linha)
        out += "}"
    return out + "]"


def coluna_para_json(col: Coluna) raises -> String:
    """Lista de valores da coluna."""
    var out = String("[")
    for i in range(col.tamanho()):
        if i > 0:
            out += ","
        out += _celula_json(col, i)
    return out + "]"


def lista_para_json(valores: List[String]) raises -> String:
    var out = String("[")
    for i in range(len(valores)):
        if i > 0:
            out += ","
        out += escapar(valores[i])
    return out + "]"
