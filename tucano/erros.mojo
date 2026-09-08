"""Mensagens de erro que ensinam (Decisao 5 do CONTRATO).

Um nome de coluna errado costuma custar um erro de chave seco. Aqui custa uma
sugestao.
"""


def _minusculo(s: String) -> String:
    return String(s.lower())


def distancia_edicao(a: String, b: String) -> Int:
    """Levenshtein sobre bytes, com duas linhas de trabalho."""
    var ba = a.as_bytes()
    var bb = b.as_bytes()
    var n = len(ba)
    var m = len(bb)
    if n == 0:
        return m
    if m == 0:
        return n

    var anterior = List[Int](capacity=m + 1)
    var atual = List[Int](capacity=m + 1)
    for j in range(m + 1):
        anterior.append(j)
        atual.append(0)

    for i in range(1, n + 1):
        atual[0] = i
        for j in range(1, m + 1):
            var custo = 1
            if ba[i - 1] == bb[j - 1]:
                custo = 0
            var d = anterior[j] + 1
            var inserir = atual[j - 1] + 1
            if inserir < d:
                d = inserir
            var substituir = anterior[j - 1] + custo
            if substituir < d:
                d = substituir
            atual[j] = d
        for j in range(m + 1):
            anterior[j] = atual[j]

    return anterior[m]


def sugerir_nome(alvo: String, candidatos: List[String]) -> String:
    """Candidato mais proximo do alvo, ou "" se nenhum for proximo o bastante.

    Limiar: metade do tamanho do alvo, entre 1 e 3. Evita sugerir "cidade"
    quando o usuario digitou "salario".
    """
    var melhor = String("")
    var melhor_d = -1
    var alvo_l = _minusculo(alvo)
    for c in candidatos:
        var d = distancia_edicao(alvo_l, _minusculo(c))
        if melhor_d < 0 or d < melhor_d:
            melhor_d = d
            melhor = c
    if melhor_d < 0:
        return ""

    var limite = alvo.byte_length() // 2
    if limite < 1:
        limite = 1
    if limite > 3:
        limite = 3
    if melhor_d > limite:
        return ""
    return melhor


def _lista_nomes(nomes: List[String]) -> String:
    var s = String("")
    for i in range(len(nomes)):
        if i > 0:
            s += ", "
        s += nomes[i]
    return s


def erro_coluna(nome: String, disponiveis: List[String]) -> Error:
    """Erro de coluna inexistente com sugestao ou lista do que existe."""
    var msg = String("coluna inexistente: '") + nome + "'"
    var sug = sugerir_nome(nome, disponiveis)
    if sug != "":
        return Error(msg + ". Voce quis dizer '" + sug + "'?")
    if len(disponiveis) > 0:
        return Error(msg + ". Colunas disponiveis: " + _lista_nomes(disponiveis))
    return Error(msg)
