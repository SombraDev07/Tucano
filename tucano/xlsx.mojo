"""Leitura e escrita de .xlsx (Office Open XML) — M12 e M14.

Uma forma: `ler_xlsx(caminho)` devolve a primeira planilha como `Tabela`.
`planilha="Nome"` escolhe a aba. Primeira linha e cabecalho, como no CSV.

Nao ha escritor, nao ha .xls (BIFF), nao ha formula recalculada: o valor
em cache no XML e o que entra. Data no formato Excel (serial) vira `data`
quando o estilo da celula e data.
"""

from std.pathlib import Path
from .coluna import Coluna
from .tabela import Tabela
from .tipos import Tipo
from .datas import dias_desde_epoch
from .dtype import DType
from .zip import Zip, escrever_zip


def _encontrar(b: List[UInt8], ini: Int, alvo: String) -> Int:
    var a = alvo.as_bytes()
    var n = len(a)
    if n == 0:
        return ini
    var i = ini
    var limite = len(b) - n
    while i <= limite:
        var ok = True
        for j in range(n):
            if b[i + j] != a[j]:
                ok = False
                break
        if ok:
            return i
        i += 1
    return -1


def _faixa(b: List[UInt8], ini: Int, fim: Int) raises -> String:
    if fim <= ini:
        return ""
    return String(from_utf8=Span(b)[ini:fim])


def _minusculo_ascii(s: String) -> String:
    return String(s.lower())


def _attr(b: List[UInt8], ini: Int, fim: Int, nome: String) raises -> String:
    var chave = nome + '="'
    var nchave = chave.byte_length()
    var p = _encontrar(b, ini, chave)
    if p < 0 or p >= fim:
        chave = nome + "='"
        nchave = chave.byte_length()
        p = _encontrar(b, ini, chave)
        if p < 0 or p >= fim:
            return ""
        var q = _encontrar(b, p + nchave, "'")
        if q < 0 or q > fim:
            return ""
        return _faixa(b, p + nchave, q)
    var q = _encontrar(b, p + nchave, '"')
    if q < 0 or q > fim:
        return ""
    return _faixa(b, p + nchave, q)


def _proximo_tag(b: List[UInt8], ini: Int) -> Int:
    return _encontrar(b, ini, "<")


def _fim_tag(b: List[UInt8], ini: Int) -> Int:
    return _encontrar(b, ini, ">")


def _nome_tag(b: List[UInt8], ini: Int) raises -> String:
    """Nome local da tag em `ini` apontando para '<'."""
    var i = ini + 1
    if i < len(b) and b[i] == UInt8(47):
        i += 1
    var comeco = i
    while i < len(b):
        var c = b[i]
        if c == UInt8(58):
            i += 1
            comeco = i
            continue
        if (
            (c >= UInt8(65) and c <= UInt8(90))
            or (c >= UInt8(97) and c <= UInt8(122))
            or (c >= UInt8(48) and c <= UInt8(57))
            or c == UInt8(95)
        ):
            i += 1
            continue
        break
    return _faixa(b, comeco, i)


def _unescape(s: String) raises -> String:
    if "&" not in s:
        return s
    var b = s.as_bytes()
    var out = List[UInt8]()
    var i = 0
    while i < len(b):
        if b[i] != UInt8(38):
            out.append(b[i])
            i += 1
            continue
        if i + 4 < len(b) and b[i + 1] == UInt8(97) and b[i + 2] == UInt8(109) and b[i + 3] == UInt8(112) and b[i + 4] == UInt8(59):
            out.append(UInt8(38))
            i += 5
        elif i + 3 < len(b) and b[i + 1] == UInt8(108) and b[i + 2] == UInt8(116) and b[i + 3] == UInt8(59):
            out.append(UInt8(60))
            i += 4
        elif i + 3 < len(b) and b[i + 1] == UInt8(103) and b[i + 2] == UInt8(116) and b[i + 3] == UInt8(59):
            out.append(UInt8(62))
            i += 4
        elif i + 5 < len(b) and b[i + 1] == UInt8(113) and b[i + 2] == UInt8(117) and b[i + 3] == UInt8(111) and b[i + 4] == UInt8(116) and b[i + 5] == UInt8(59):
            out.append(UInt8(34))
            i += 6
        elif i + 5 < len(b) and b[i + 1] == UInt8(97) and b[i + 2] == UInt8(112) and b[i + 3] == UInt8(111) and b[i + 4] == UInt8(115) and b[i + 5] == UInt8(59):
            out.append(UInt8(39))
            i += 6
        else:
            out.append(b[i])
            i += 1
    return String(from_utf8=Span(out))


def _texto_entre(b: List[UInt8], ini: Int, abertura: String, fechamento: String) raises -> String:
    var a = _encontrar(b, ini, abertura)
    if a < 0:
        return ""
    var ini_txt = a + abertura.byte_length()
    # pular atributos de <t ...>
    if abertura == "<t":
        var gt = _fim_tag(b, a)
        if gt < 0:
            return ""
        ini_txt = gt + 1
    var f = _encontrar(b, ini_txt, fechamento)
    if f < 0:
        return ""
    return _unescape(_faixa(b, ini_txt, f))


def _col_letra(s: String) raises -> Int:
    var b = s.as_bytes()
    var col = 0
    var i = 0
    while i < len(b):
        var c = b[i]
        if c >= UInt8(65) and c <= UInt8(90):
            col = col * 26 + Int(c) - 64
            i += 1
            continue
        if c >= UInt8(97) and c <= UInt8(122):
            col = col * 26 + Int(c) - 96
            i += 1
            continue
        break
    if col == 0:
        raise Error("xlsx: referencia de coluna invalida '" + s + "'")
    return col - 1


def _linha_ref(s: String) raises -> Int:
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        var c = b[i]
        var letra = (c >= UInt8(65) and c <= UInt8(90)) or (c >= UInt8(97) and c <= UInt8(122))
        if not letra:
            break
        i += 1
    if i >= len(b):
        raise Error("xlsx: referencia sem linha '" + s + "'")
    var n = 0
    while i < len(b):
        var c = b[i]
        if c < UInt8(48) or c > UInt8(57):
            break
        n = n * 10 + Int(c) - 48
        i += 1
    if n <= 0:
        raise Error("xlsx: referencia sem linha '" + s + "'")
    return n - 1


def _eh_fmt_data_id(id: Int) -> Bool:
    if id >= 14 and id <= 22:
        return True
    if id >= 27 and id <= 36:
        return True
    if id >= 45 and id <= 47:
        return True
    if id >= 50 and id <= 58:
        return True
    if id >= 71 and id <= 81:
        return True
    return False


def _fmt_parece_data(fmt: String) -> Bool:
    var b = fmt.as_bytes()
    var i = 0
    var entre_aspas = False
    while i < len(b):
        var c = b[i]
        if c == UInt8(34):
            entre_aspas = not entre_aspas
            i += 1
            continue
        if entre_aspas:
            i += 1
            continue
        if c == UInt8(92):
            i += 2
            continue
        var m = c
        if m >= UInt8(65) and c <= UInt8(90):
            m = c + UInt8(32)
        if m == UInt8(100) or m == UInt8(121) or m == UInt8(104) or m == UInt8(115):
            return True
        i += 1
    return False


def _serial_para_micros(n: Float64) -> Int64:
    """Serial com fracao -> microssegundos desde 1970-01-01.

    A planilha nao tem tipo separado para data e datahora: as duas sao o mesmo
    numero, e a hora e a **fracao do dia**. Quem distingue e a parte
    fracionaria, nao o formato — e por isso a leitura decide por ela, e nao pelo
    `numFmtId`, que cada escritor escolhe como quer.
    """
    var chao = Float64(Int(n))
    if n < chao:
        chao -= 1.0
    var dias = Int64(Int(chao) + dias_desde_epoch(1899, 12, 30))
    var micros_do_dia = Int64((n - chao) * 86400000000.0 + 0.5)
    return dias * Int64(86400000000) + micros_do_dia


def _serial_para_dias(n: Float64) -> Int64:
    """Excel 1900 (com o leap bug) -> dias desde 1970-01-01."""
    var inteiro = Int(n)
    if n < 0:
        inteiro = Int(n) - 1
    return Int64(inteiro + dias_desde_epoch(1899, 12, 30))


# tipos de celula na grade
comptime _VAZIA = 0
comptime _TEXTO = 1
comptime _NUMERO = 2
comptime _LOGICO = 3
comptime _DATA = 4
comptime _DATAHORA = 5


struct _Grade(Movable):
    var n_linhas: Int
    var n_cols: Int
    var tipo: List[Int]
    var texto: List[String]
    var numero: List[Float64]
    var dias: List[Int64]
    var micros: List[Int64]

    def __init__(out self, n_linhas: Int, n_cols: Int):
        self.n_linhas = n_linhas
        self.n_cols = n_cols
        var n = n_linhas * n_cols
        self.tipo = List[Int]()
        self.texto = List[String]()
        self.numero = List[Float64]()
        self.dias = List[Int64]()
        self.micros = List[Int64]()
        for _ in range(n):
            self.tipo.append(_VAZIA)
            self.texto.append("")
            self.numero.append(0.0)
            self.dias.append(Int64(0))
            self.micros.append(Int64(0))

    def idx(self, linha: Int, col: Int) -> Int:
        return linha * self.n_cols + col


def _estilos_data(xml: List[UInt8]) raises -> List[Bool]:
    """Indice de xf -> se o formato e data."""
    var custom_id = List[Int]()
    var custom_data = List[Bool]()
    var p = 0
    while True:
        var t = _encontrar(xml, p, "<numFmt")
        if t < 0:
            break
        var fim = _fim_tag(xml, t)
        if fim < 0:
            break
        var id_s = _attr(xml, t, fim, "numFmtId")
        var code = _attr(xml, t, fim, "formatCode")
        if id_s != "":
            var id = atol(id_s)
            custom_id.append(id)
            custom_data.append(_fmt_parece_data(code) or _eh_fmt_data_id(id))
        p = fim + 1

    var xfs = List[Bool]()
    var bloco = _encontrar(xml, 0, "<cellXfs")
    if bloco < 0:
        xfs.append(False)
        return xfs^
    var abre_xf = _fim_tag(xml, bloco)
    if abre_xf < 0:
        xfs.append(False)
        return xfs^
    p = abre_xf + 1
    var fim_bloco = _encontrar(xml, bloco, "</cellXfs>")
    if fim_bloco < 0:
        fim_bloco = len(xml)
    while True:
        var t = _encontrar(xml, p, "<xf")
        if t < 0 or t >= fim_bloco:
            break
        var nome = _nome_tag(xml, t)
        if nome != "xf":
            p = t + 3
            continue
        var fim = _fim_tag(xml, t)
        if fim < 0 or fim > fim_bloco:
            break
        var id_s = _attr(xml, t, fim, "numFmtId")
        var data = False
        if id_s != "":
            var id = atol(id_s)
            data = _eh_fmt_data_id(id)
            if not data:
                for i in range(len(custom_id)):
                    if custom_id[i] == id:
                        data = custom_data[i]
        xfs.append(data)
        p = fim + 1
    if len(xfs) == 0:
        xfs.append(False)
    return xfs^


def _strings_compartilhadas(xml: List[UInt8]) raises -> List[String]:
    var out = List[String]()
    var p = 0
    while True:
        var si = _encontrar(xml, p, "<si")
        if si < 0:
            break
        var nome = _nome_tag(xml, si)
        if nome != "si":
            p = si + 3
            continue
        var fim = _encontrar(xml, si, "</si>")
        if fim < 0:
            break
        var texto = String("")
        var q = si
        while True:
            var t = _encontrar(xml, q, "<t")
            if t < 0 or t >= fim:
                break
            var tn = _nome_tag(xml, t)
            if tn != "t":
                q = t + 2
                continue
            var gt = _fim_tag(xml, t)
            if gt < 0 or gt >= fim:
                break
            var fecha = _encontrar(xml, gt, "</t>")
            if fecha < 0 or fecha > fim:
                break
            texto += _unescape(_faixa(xml, gt + 1, fecha))
            q = fecha + 4
        out.append(texto)
        p = fim + 5
    return out^


def _planilhas(xml: List[UInt8]) raises -> Tuple[List[String], List[String]]:
    var nomes = List[String]()
    var rids = List[String]()
    var p = 0
    while True:
        var t = _encontrar(xml, p, "<sheet")
        if t < 0:
            break
        var nome_t = _nome_tag(xml, t)
        if nome_t != "sheet":
            p = t + 6
            continue
        var fim = _fim_tag(xml, t)
        if fim < 0:
            break
        # o nome da aba e atributo XML: `&` e `<` chegam como entidade, e sem
        # desfazer isso a aba "Vendas & Cia" nunca seria encontrada pelo nome
        var nome = _unescape(_attr(xml, t, fim, "name"))
        var rid = _attr(xml, t, fim, "r:id")
        if rid == "":
            rid = _attr(xml, t, fim, "id")
        nomes.append(nome)
        rids.append(rid)
        p = fim + 1
    return (nomes^, rids^)


def _alvos_rels(xml: List[UInt8]) raises -> Tuple[List[String], List[String]]:
    var ids = List[String]()
    var alvos = List[String]()
    var p = 0
    while True:
        var t = _encontrar(xml, p, "<Relationship")
        if t < 0:
            break
        var fim = _fim_tag(xml, t)
        if fim < 0:
            break
        ids.append(_attr(xml, t, fim, "Id"))
        alvos.append(_attr(xml, t, fim, "Target"))
        p = fim + 1
    return (ids^, alvos^)


def _comeca(s: String, pref: String) -> Bool:
    var a = s.as_bytes()
    var p = pref.as_bytes()
    if len(p) > len(a):
        return False
    for i in range(len(p)):
        if a[i] != p[i]:
            return False
    return True


def _membro_de_alvo(alvo: String) raises -> String:
    if alvo == "":
        return ""
    var b = alvo.as_bytes()
    if len(b) > 0 and b[0] == UInt8(47):
        return String(from_utf8=Span(b)[1 : len(b)])
    if _comeca(alvo, "xl/"):
        return alvo
    return "xl/" + alvo


def _preencher_celula(
    mut g: _Grade,
    linha: Int,
    col: Int,
    tipo_xml: String,
    estilo: Int,
    valor: String,
    strings: List[String],
    xf_data: List[Bool],
) raises:
    if linha < 0 or col < 0 or linha >= g.n_linhas or col >= g.n_cols:
        return
    var k = g.idx(linha, col)
    if tipo_xml == "s":
        var idx = atol(valor)
        if idx < 0 or idx >= len(strings):
            raise Error("xlsx: indice de string compartilhada fora da faixa")
        g.tipo[k] = _TEXTO
        g.texto[k] = strings[idx]
        return
    if tipo_xml == "inlineStr" or tipo_xml == "str":
        g.tipo[k] = _TEXTO
        g.texto[k] = valor
        return
    if tipo_xml == "b":
        g.tipo[k] = _LOGICO
        g.texto[k] = valor
        return
    if tipo_xml == "e":
        return
    # numero, possivelmente data
    var data = False
    if estilo >= 0 and estilo < len(xf_data):
        data = xf_data[estilo]
    if data:
        var serial = atof(valor)
        g.numero[k] = serial
        var chao = Float64(Int(serial))
        if serial < chao:
            chao -= 1.0
        if serial != chao:
            g.tipo[k] = _DATAHORA
            g.micros[k] = _serial_para_micros(serial)
        else:
            g.tipo[k] = _DATA
            g.dias[k] = _serial_para_dias(serial)
        return
    g.tipo[k] = _NUMERO
    g.texto[k] = valor
    g.numero[k] = atof(valor)


def _ler_grade(
    xml: List[UInt8], strings: List[String], xf_data: List[Bool]
) raises -> _Grade:
    var max_linha = 0
    var max_col = 0
    var dim = _encontrar(xml, 0, "<dimension")
    if dim >= 0:
        var fim = _fim_tag(xml, dim)
        if fim >= 0:
            var referencia = _attr(xml, dim, fim, "ref")
            if ":" in referencia:
                var rb = referencia.as_bytes()
                var dois = -1
                for i in range(len(rb)):
                    if rb[i] == UInt8(58):
                        dois = i
                        break
                if dois >= 0:
                    var ultima = String(
                        referencia[byte = dois + 1 : referencia.byte_length()]
                    )
                    max_col = _col_letra(ultima) + 1
                    max_linha = _linha_ref(ultima) + 1

    # passa 1: se nao houver dimension, mede
    if max_linha == 0 or max_col == 0:
        var p = 0
        while True:
            var t = _encontrar(xml, p, "<c")
            if t < 0:
                break
            var nome = _nome_tag(xml, t)
            if nome != "c":
                p = t + 2
                continue
            var fim = _fim_tag(xml, t)
            if fim < 0:
                break
            var r = _attr(xml, t, fim, "r")
            if r != "":
                var c = _col_letra(r) + 1
                var l = _linha_ref(r) + 1
                if c > max_col:
                    max_col = c
                if l > max_linha:
                    max_linha = l
            p = fim + 1

    if max_linha == 0 or max_col == 0:
        raise Error("xlsx: planilha vazia")

    var g = _Grade(max_linha, max_col)
    var p = 0
    while True:
        var t = _encontrar(xml, p, "<c")
        if t < 0:
            break
        var nome = _nome_tag(xml, t)
        if nome != "c":
            p = t + 2
            continue
        var fim = _fim_tag(xml, t)
        if fim < 0:
            break
        var r = _attr(xml, t, fim, "r")
        if r == "":
            p = fim + 1
            continue
        var linha = _linha_ref(r)
        var col = _col_letra(r)
        var tipo_xml = _attr(xml, t, fim, "t")
        var s_attr = _attr(xml, t, fim, "s")
        var estilo = 0
        if s_attr != "":
            estilo = atol(s_attr)
        if tipo_xml == "inlineStr":
            var fecha_c = _encontrar(xml, fim, "</c>")
            if fecha_c < 0:
                p = fim + 1
                continue
            var valor_in = _texto_entre(xml, fim, "<t", "</t>")
            _preencher_celula(
                g, linha, col, tipo_xml, estilo, valor_in, strings, xf_data
            )
            p = fecha_c + 4
            continue
        var fecha_c = _encontrar(xml, fim, "</c>")
        var self_close = fim > 0 and xml[fim - 1] == UInt8(47)
        if self_close:
            p = fim + 1
            continue
        if fecha_c < 0:
            p = fim + 1
            continue
        var valor = _texto_entre(xml, fim, "<v>", "</v>")
        p = fecha_c + 4
        if valor == "":
            continue
        _preencher_celula(
            g, linha, col, tipo_xml, estilo, valor, strings, xf_data
        )
    return g^


def _nome_coluna(g: _Grade, col: Int, tem_cabecalho: Bool) raises -> String:
    if not tem_cabecalho:
        return "col" + String(col)
    var k = g.idx(0, col)
    if g.tipo[k] == _VAZIA:
        return "col" + String(col)
    if g.tipo[k] == _TEXTO:
        if g.texto[k] == "":
            return "col" + String(col)
        return g.texto[k]
    if g.tipo[k] == _NUMERO:
        return g.texto[k]
    if g.tipo[k] == _LOGICO:
        return g.texto[k]
    return "col" + String(col)


def _tipo_coluna(g: _Grade, col: Int, linha_ini: Int) raises -> Int:
    var so_data = True
    var tem_hora = False
    var so_logico = True
    var so_int = True
    var so_num = True
    var tem = False
    for linha in range(linha_ini, g.n_linhas):
        var k = g.idx(linha, col)
        var t = g.tipo[k]
        if t == _VAZIA:
            continue
        tem = True
        if t == _DATAHORA:
            tem_hora = True
        if t != _DATA and t != _DATAHORA:
            so_data = False
        if t != _LOGICO:
            so_logico = False
        if t == _TEXTO:
            so_int = False
            so_num = False
        elif t == _NUMERO:
            so_data = False
            so_logico = False
            if "." in g.texto[k] or "e" in g.texto[k] or "E" in g.texto[k]:
                so_int = False
        elif t == _DATA or t == _DATAHORA or t == _LOGICO:
            so_int = False
            so_num = False
    if not tem:
        return Tipo.TEXTO
    if so_data:
        # data e datahora na mesma coluna: datahora, porque data e datahora a
        # meia-noite, e o contrario perderia a hora
        if tem_hora:
            return Tipo.DATAHORA
        return Tipo.DATA
    if so_logico:
        return Tipo.LOGICO
    if so_num and so_int:
        return Tipo.INTEIRO
    if so_num:
        return Tipo.REAL
    return Tipo.TEXTO


def _coluna_da_grade(
    g: _Grade, col: Int, linha_ini: Int, nome: String, tipo: Int
) raises -> Coluna:
    var ausentes = List[Bool]()
    if tipo == Tipo.DATAHORA:
        var vals = List[Int64]()
        for linha in range(linha_ini, g.n_linhas):
            var k = g.idx(linha, col)
            if g.tipo[k] == _VAZIA:
                vals.append(Int64(0))
                ausentes.append(True)
            elif g.tipo[k] == _DATA:
                vals.append(g.dias[k] * Int64(86400000000))
                ausentes.append(False)
            else:
                vals.append(g.micros[k])
                ausentes.append(False)
        return Coluna.de_datahoras(nome, vals^, ausentes^)
    if tipo == Tipo.DATA:
        var vals = List[Int64]()
        for linha in range(linha_ini, g.n_linhas):
            var k = g.idx(linha, col)
            if g.tipo[k] == _VAZIA:
                vals.append(Int64(0))
                ausentes.append(True)
            else:
                vals.append(g.dias[k])
                ausentes.append(False)
        return Coluna.de_datas(nome, vals^, ausentes^)
    if tipo == Tipo.INTEIRO:
        var vals = List[Int64]()
        for linha in range(linha_ini, g.n_linhas):
            var k = g.idx(linha, col)
            if g.tipo[k] == _VAZIA:
                vals.append(Int64(0))
                ausentes.append(True)
            else:
                ausentes.append(False)
                vals.append(Int64(g.numero[k]))
        return Coluna.de_inteiros(nome, vals^, ausentes^)
    if tipo == Tipo.REAL:
        var vals = List[Float64]()
        for linha in range(linha_ini, g.n_linhas):
            var k = g.idx(linha, col)
            if g.tipo[k] == _VAZIA:
                vals.append(0.0)
                ausentes.append(True)
            else:
                vals.append(g.numero[k])
                ausentes.append(False)
        return Coluna.de_reais(nome, vals^, ausentes^)
    if tipo == Tipo.LOGICO:
        var vals = List[Bool]()
        for linha in range(linha_ini, g.n_linhas):
            var k = g.idx(linha, col)
            if g.tipo[k] == _VAZIA:
                vals.append(False)
                ausentes.append(True)
            else:
                ausentes.append(False)
                vals.append(g.texto[k] == "1" or _minusculo_ascii(g.texto[k]) == "true")
        return Coluna.de_logicos(nome, vals^, ausentes^)
    var textos = List[String]()
    for linha in range(linha_ini, g.n_linhas):
        var k = g.idx(linha, col)
        if g.tipo[k] == _VAZIA:
            textos.append("")
            ausentes.append(True)
        else:
            ausentes.append(False)
            if g.tipo[k] == _TEXTO:
                textos.append(g.texto[k])
            elif g.tipo[k] == _NUMERO:
                textos.append(g.texto[k])
            else:
                textos.append(g.texto[k])
    return Coluna.de_textos(nome, textos^, ausentes^)


def _eh_ole(b: List[UInt8]) -> Bool:
    if len(b) < 8:
        return False
    return (
        b[0] == UInt8(0xD0)
        and b[1] == UInt8(0xCF)
        and b[2] == UInt8(0x11)
        and b[3] == UInt8(0xE0)
    )


def _eh_zip(b: List[UInt8]) -> Bool:
    if len(b) < 4:
        return False
    return b[0] == UInt8(0x50) and b[1] == UInt8(0x4B)


def _caminho_planilha(
    ref z: Zip, quer: String
) raises -> String:
    var wb = z.obter("xl/workbook.xml")
    var pares = _planilhas(wb)
    var nomes = pares[0].copy()
    var rids = pares[1].copy()
    if len(nomes) == 0:
        raise Error("xlsx: workbook sem planilha")

    var rels = z.obter("xl/_rels/workbook.xml.rels")
    var pares_r = _alvos_rels(rels)
    var ids = pares_r[0].copy()
    var alvos = pares_r[1].copy()

    var idx = 0
    if quer != "":
        var achou = False
        var q = _minusculo_ascii(quer)
        for i in range(len(nomes)):
            if nomes[i] == quer or _minusculo_ascii(nomes[i]) == q:
                idx = i
                achou = True
                break
        if not achou:
            var lista = String("")
            for i in range(len(nomes)):
                if i > 0:
                    lista += ", "
                lista += nomes[i]
            raise Error(
                "xlsx: planilha '" + quer + "' nao existe. Disponiveis: " + lista
            )

    var rid = rids[idx]
    var alvo = String("")
    for i in range(len(ids)):
        if ids[i] == rid:
            alvo = alvos[i]
            break
    if alvo == "":
        raise Error("xlsx: relacionamento '" + rid + "' nao encontrado")
    return _membro_de_alvo(alvo)


def ler_xlsx(
    caminho: String, planilha: String = "", tem_cabecalho: Bool = True
) raises -> Tabela:
    """Le a planilha como `Tabela`. Sem `planilha`, usa a primeira aba."""
    var bruto = Path(caminho).read_bytes()
    if not _eh_zip(bruto):
        if _eh_ole(bruto):
            raise Error(
                "xlsx: '" + caminho + "' e .xls antigo (BIFF). Salve como .xlsx"
            )
        raise Error(
            "xlsx: '" + caminho + "' nao e uma planilha Office Open XML"
        )

    var z = Zip(bruto^)
    var membro = _caminho_planilha(z, planilha)

    var strings = List[String]()
    if z.tem("xl/sharedStrings.xml"):
        strings = _strings_compartilhadas(z.obter("xl/sharedStrings.xml"))

    var xf_data = List[Bool]()
    xf_data.append(False)
    if z.tem("xl/styles.xml"):
        xf_data = _estilos_data(z.obter("xl/styles.xml"))

    var grade = _ler_grade(z.obter(membro), strings, xf_data)
    var linha_ini = 0
    if tem_cabecalho:
        linha_ini = 1
    if grade.n_linhas <= linha_ini:
        raise Error("xlsx: sem linhas de dados em '" + caminho + "'")

    var colunas = List[Coluna]()
    for c in range(grade.n_cols):
        var nome = _nome_coluna(grade, c, tem_cabecalho)
        var tipo = _tipo_coluna(grade, c, linha_ini)
        colunas.append(_coluna_da_grade(grade, c, linha_ini, nome, tipo))
    return Tabela(colunas^)


# ------------------------------------------------------------------ escrita
#
# Uma tabela, um arquivo, uma aba. Sem formula, sem estilo alem do minimo que
# faz o Excel mostrar data como data — sem ele, a celula apareceria como o
# numero de serie cru, e o `ler_xlsx` tambem nao saberia que aquilo e data.
#
# Os membros vao armazenados, sem DEFLATE. Comprimir XML de planilha economiza
# bytes que o Excel abre igual, e um compressor e um modulo inteiro para manter.

comptime _ESTILO_COMUM = 0
comptime _ESTILO_DATA = 1
comptime _ESTILO_DATAHORA = 2

# 1970-01-01 no calendario de serie do Excel. Vem da mesma conta que a leitura
# usa ao contrario, para os dois nao poderem discordar.
comptime _SERIAL_DA_EPOCH = 25569


def _escapar_xml(valor: String) raises -> String:
    """Escapa em bytes, nao em `String`.

    Concatenar `String` por caractere alocaria uma por byte de nome de coluna;
    e o UTF-8 passa intacto, porque so os tres caracteres da sintaxe do XML
    precisam virar entidade.
    """
    var out = List[UInt8]()
    for b in valor.as_bytes():
        if b == UInt8(38):  # &
            for c in String("&amp;").as_bytes():
                out.append(c)
        elif b == UInt8(60):  # <
            for c in String("&lt;").as_bytes():
                out.append(c)
        elif b == UInt8(62):  # >
            for c in String("&gt;").as_bytes():
                out.append(c)
        elif b < UInt8(32) and b != UInt8(9) and b != UInt8(10) and b != UInt8(13):
            # controle que o XML nao aceita: some, em vez de gerar um arquivo
            # que nenhum leitor abre
            continue
        else:
            out.append(b)
    if len(out) == 0:
        return String("")
    return String(from_utf8=Span(out)[0 : len(out)])


def _letra_da_coluna(indice: Int) -> String:
    """0 -> A, 25 -> Z, 26 -> AA."""
    var s = String("")
    var n = indice
    while True:
        var r = n % 26
        s = String(chr(65 + r)) + s
        n = n // 26 - 1
        if n < 0:
            break
    return s^


def _bytes_de(texto: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in texto.as_bytes():
        out.append(b)
    return out^


def _parte_content_types() -> String:
    return String(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
        "</Types>"
    )


def _parte_rels_raiz() -> String:
    return String(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1"'
        ' Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"'
        ' Target="xl/workbook.xml"/>'
        "</Relationships>"
    )


def _parte_workbook(planilha: String) raises -> String:
    return String(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
        ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        "<sheets><sheet name=\""
    ) + _escapar_xml(planilha) + String(
        '" sheetId="1" r:id="rId1"/></sheets></workbook>'
    )


def _parte_rels_workbook() -> String:
    return String(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1"'
        ' Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"'
        ' Target="worksheets/sheet1.xml"/>'
        '<Relationship Id="rId2"'
        ' Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles"'
        ' Target="styles.xml"/>'
        "</Relationships>"
    )


def _parte_styles() -> String:
    """Tres formatos: o comum, data e datahora.

    `numFmtId` 14 e 22 sao embutidos do proprio formato — nao precisam de
    `numFmt` declarado — e estao na faixa que o `ler_xlsx` reconhece como data.
    """
    return String(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>'
        '<fills count="1"><fill><patternFill patternType="none"/></fill></fills>'
        "<borders count=\"1\"><border/></borders>"
        '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
        '<cellXfs count="3">'
        '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
        '<xf numFmtId="14" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
        '<xf numFmtId="22" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
        "</cellXfs>"
        '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
        "</styleSheet>"
    )


def _celula(
    endereco: String, tipo_xml: String, estilo: Int, valor: String
) -> String:
    var s = String("<c r=\"") + endereco + "\""
    if estilo != _ESTILO_COMUM:
        s += " s=\"" + String(estilo) + "\""
    if tipo_xml == "inlineStr":
        s += " t=\"inlineStr\"><is><t xml:space=\"preserve\">" + valor + "</t></is></c>"
        return s^
    if tipo_xml == "b":
        s += " t=\"b\"><v>" + valor + "</v></c>"
        return s^
    s += "><v>" + valor + "</v></c>"
    return s^


def _parte_planilha(tabela: Tabela) raises -> String:
    var cols = tabela.lote()
    var nomes = tabela.nomes()
    var linhas = tabela.linhas()
    var s = String(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        "<sheetData>"
    )

    s += "<row r=\"1\">"
    for c in range(len(nomes)):
        s += _celula(
            _letra_da_coluna(c) + "1", "inlineStr", _ESTILO_COMUM,
            _escapar_xml(nomes[c]),
        )
    s += "</row>"

    for i in range(linhas):
        var r = i + 2
        s += "<row r=\"" + String(r) + "\">"
        for c in range(len(cols)):
            var endereco = _letra_da_coluna(c) + String(r)
            ref coluna = cols[c]
            # ausente nao vira celula: celula que falta e como o Excel guarda
            # vazio, e e assim que o `ler_xlsx` a le de volta
            if coluna.eh_ausente(i):
                continue
            if coluna.tipo == DType.TEXTO:
                s += _celula(
                    endereco, "inlineStr", _ESTILO_COMUM,
                    _escapar_xml(coluna.texto_bruto(i)),
                )
            elif coluna.tipo == DType.LOGICO:
                var v = String("0")
                if Int(coluna.logics[i]) != 0:
                    v = "1"
                s += _celula(endereco, "b", _ESTILO_COMUM, v)
            elif coluna.tipo == DType.DATA:
                var serial = Int(coluna.dias_em(i)) + _SERIAL_DA_EPOCH
                s += _celula(endereco, "n", _ESTILO_DATA, String(serial))
            elif coluna.tipo == DType.DATAHORA:
                var micros = Int(coluna.micros_em(i))
                var dia = micros // 86_400_000_000
                if micros < 0 and micros % 86_400_000_000 != 0:
                    dia -= 1
                var resto = micros - dia * 86_400_000_000
                var fracao = Float64(resto) / 86_400_000_000.0
                s += _celula(
                    endereco, "n", _ESTILO_DATAHORA,
                    String(Float64(dia + _SERIAL_DA_EPOCH) + fracao),
                )
            elif coluna.tipo == DType.REAL:
                var x = coluna.reals[i]
                if x != x or x > 1.0e308 or x < -1.0e308:
                    # NaN e infinito nao existem na planilha; celula vazia diz a
                    # verdade melhor que um numero inventado
                    continue
                s += _celula(endereco, "n", _ESTILO_COMUM, String(x))
            else:
                s += _celula(endereco, "n", _ESTILO_COMUM, String(coluna.ints[i]))
        s += "</row>"

    s += "</sheetData></worksheet>"
    return s^


def para_xlsx(
    tabela: Tabela, caminho: String, planilha: String = "Planilha1"
) raises:
    """Grava a tabela como planilha, numa aba.

    Uma forma: uma tabela, um arquivo, uma aba. Sem formula e sem varias abas —
    isso e compatibilidade com o Excel, nao o motor.
    """
    var nomes = List[String]()
    var conteudos = List[List[UInt8]]()

    nomes.append("[Content_Types].xml")
    conteudos.append(_bytes_de(_parte_content_types()))
    nomes.append("_rels/.rels")
    conteudos.append(_bytes_de(_parte_rels_raiz()))
    nomes.append("xl/workbook.xml")
    conteudos.append(_bytes_de(_parte_workbook(planilha)))
    nomes.append("xl/_rels/workbook.xml.rels")
    conteudos.append(_bytes_de(_parte_rels_workbook()))
    nomes.append("xl/styles.xml")
    conteudos.append(_bytes_de(_parte_styles()))
    nomes.append("xl/worksheets/sheet1.xml")
    conteudos.append(_bytes_de(_parte_planilha(tabela)))

    Path(caminho).write_bytes(escrever_zip(nomes, conteudos))
