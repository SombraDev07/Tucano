"""Padronizacao de texto — o que se faz antes de agrupar ou juntar.

Planilha de gente tem "São Paulo", "SAO PAULO", " São  Paulo " e "sao paulo"
querendo dizer a mesma coisa, e um `agrupar` honesto devolve quatro grupos. Aqui
ficam as funcoes que transformam o texto; quem as usa como expressao esta em
`expr.mojo`.

Tudo opera sobre **bytes UTF-8**, decodificando so onde precisa (acento). Um
acento e uma sequencia de dois bytes que so aparece inteira, entao percorrer
byte a byte e seguro para as outras operacoes.
"""


def _minuscula_ascii(b: UInt8) -> UInt8:
    if b >= UInt8(65) and b <= UInt8(90):
        return b + UInt8(32)
    return b


def _maiuscula_ascii(b: UInt8) -> UInt8:
    if b >= UInt8(97) and b <= UInt8(122):
        return b - UInt8(32)
    return b


def _eh_espaco(b: UInt8) -> Bool:
    # espaco, tabulacao, quebra de linha, retorno de carro
    return b == UInt8(32) or b == UInt8(9) or b == UInt8(10) or b == UInt8(13)


def minusculas(texto: String) raises -> String:
    """Tudo em minuscula, inclusive as vogais acentuadas.

    `Á` e `á` sao duas sequencias UTF-8 de dois bytes que diferem no segundo, e
    a diferenca e a mesma do ASCII: 32. Vale para todo o bloco Latin-1
    suplementar, que e onde vivem os acentos do portugues.
    """
    var b = texto.as_bytes()
    var out = List[UInt8](capacity=len(b))
    var i = 0
    while i < len(b):
        var x = b[i]
        if x < UInt8(0x80):
            out.append(_minuscula_ascii(x))
            i += 1
        elif (x == UInt8(0xC3)) and i + 1 < len(b):
            var y = b[i + 1]
            # 0xC380..0xC39E sao as maiusculas acentuadas; +0x20 da a minuscula
            if y >= UInt8(0x80) and y <= UInt8(0x9E) and y != UInt8(0x97):
                out.append(x)
                out.append(y + UInt8(0x20))
            else:
                out.append(x)
                out.append(y)
            i += 2
        else:
            out.append(x)
            i += 1
    return String(from_utf8=Span(out))


def maiusculas(texto: String) raises -> String:
    """Tudo em maiuscula, inclusive as vogais acentuadas."""
    var b = texto.as_bytes()
    var out = List[UInt8](capacity=len(b))
    var i = 0
    while i < len(b):
        var x = b[i]
        if x < UInt8(0x80):
            out.append(_maiuscula_ascii(x))
            i += 1
        elif (x == UInt8(0xC3)) and i + 1 < len(b):
            var y = b[i + 1]
            if y >= UInt8(0xA0) and y <= UInt8(0xBE) and y != UInt8(0xB7):
                out.append(x)
                out.append(y - UInt8(0x20))
            else:
                out.append(x)
                out.append(y)
            i += 2
        else:
            out.append(x)
            i += 1
    return String(from_utf8=Span(out))


def aparar(texto: String) raises -> String:
    """Tira espaco das pontas **e** junta os do meio.

    As duas coisas de uma vez porque e assim que o problema aparece: `" São
    Paulo "` e `"São  Paulo"` vem da mesma celula mal digitada, e separar as
    duas operacoes so faria quem limpa dado chamar as duas sempre.
    """
    var b = texto.as_bytes()
    var out = List[UInt8](capacity=len(b))
    var i = 0
    var pendente = False
    while i < len(b):
        var x = b[i]
        if _eh_espaco(x):
            if len(out) > 0:
                pendente = True
            i += 1
            continue
        if pendente:
            out.append(UInt8(32))
            pendente = False
        out.append(x)
        i += 1
    return String(from_utf8=Span(out))


def sem_espacos(texto: String) raises -> String:
    """Tira **todo** espaco, inclusive o que separa palavras.

    Nao serve para mostrar — serve como **chave de comparacao**. Espaco enfiado
    no meio da palavra (`"S  AO PAULO"`) e espaco duplo entre palavras
    (`"São  Paulo"`) sao problemas diferentes, e nenhuma regra conserta os dois:

        entrada             juntar em um    tirar so os duplos   tirar todos
        "S  AO P  AULO"     "S AO P AULO"   "SAO PAULO"          "SAOPAULO"
        "São  Paulo"        "São Paulo"     "SãoPaulo"           "SãoPaulo"
        "Rio de  Janeiro"   "Rio de Janeiro" "Rio deJaneiro"     "RiodeJaneiro"

    Tirar so os duplos conserta o primeiro caso e estraga os outros dois. Tirar
    todos deixa o texto ilegivel — e faz as quatro grafias coincidirem, que e o
    que um agrupamento precisa. Por isso esta funcao existe separada de
    `aparar`: uma e para ler, a outra e para casar.
    """
    var b = texto.as_bytes()
    var out = List[UInt8](capacity=len(b))
    for x in b:
        if not _eh_espaco(x):
            out.append(x)
    return String(from_utf8=Span(out))


def _sem_acento_par(alto: UInt8, baixo: UInt8) -> String:
    """A letra sem acento de uma sequencia de dois bytes, ou vazio se nao houver.

    So o bloco Latin-1 suplementar (0xC3) e as consoantes do 0xC5 que aparecem
    em portugues e espanhol. Grego e cirilico passam intactos: trocar por `?`
    seria pior que deixar como esta.
    """
    if alto == UInt8(0xC3):
        var y = Int(baixo)
        if y >= 0x80 and y <= 0x85:
            return "A"
        if y == 0x87:
            return "C"
        if y >= 0x88 and y <= 0x8B:
            return "E"
        if y >= 0x8C and y <= 0x8F:
            return "I"
        if y == 0x91:
            return "N"
        if (y >= 0x92 and y <= 0x96) or y == 0x98:
            return "O"
        if y >= 0x99 and y <= 0x9C:
            return "U"
        if y == 0x9D:
            return "Y"
        if y >= 0xA0 and y <= 0xA5:
            return "a"
        if y == 0xA7:
            return "c"
        if y >= 0xA8 and y <= 0xAB:
            return "e"
        if y >= 0xAC and y <= 0xAF:
            return "i"
        if y == 0xB1:
            return "n"
        if (y >= 0xB2 and y <= 0xB6) or y == 0xB8:
            return "o"
        if y >= 0xB9 and y <= 0xBC:
            return "u"
        if y == 0xBD or y == 0xBF:
            return "y"
    return ""


def sem_acento(texto: String) raises -> String:
    """Troca vogal acentuada pela sem acento, e cedilha por `c`.

    O que nao esta na tabela passa intacto — inclusive emoji e alfabeto que nao
    seja latino. Perder o caractere seria pior que nao transformar.
    """
    var b = texto.as_bytes()
    var out = List[UInt8](capacity=len(b))
    var i = 0
    while i < len(b):
        var x = b[i]
        if x < UInt8(0x80):
            out.append(x)
            i += 1
            continue
        if i + 1 < len(b):
            var trocado = _sem_acento_par(x, b[i + 1])
            if len(trocado.as_bytes()) > 0:
                for c in trocado.as_bytes():
                    out.append(c)
                i += 2
                continue
        out.append(x)
        i += 1
    return String(from_utf8=Span(out))


def normalizar(texto: String) raises -> String:
    """Aparar, minusculas e sem acento — a padronizacao que se faz antes de
    agrupar ou juntar.

    `" São  PAULO "`, `"Sao Paulo"` e `"são paulo"` viram todos `"sao paulo"`.

    O que ela **nao** faz: tirar pontuacao. `"S. Paulo"` continua com o ponto,
    porque decidir que pontuacao e ruido depende do dado — num nome de cidade o
    ponto sobra, num codigo de produto ele significa.
    """
    return sem_acento(minusculas(aparar(texto)))
