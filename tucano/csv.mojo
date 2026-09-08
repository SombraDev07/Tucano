from std.pathlib import Path
from .coluna import Coluna
from .tabela import Tabela
from .tipos import Tipo
from .dtype import DType
from .datas import eh_data_iso, parse_data_iso


def _eh_na(celula: String) -> Bool:
    var t = celula.strip().lower()
    return (
        t == ""
        or t == "na"
        or t == "nan"
        or t == "null"
        or t == "none"
        or t == "n/a"
    )


def _eh_bool(celula: String) -> Bool:
    var t = celula.strip().lower()
    return t == "true" or t == "false"


def _para_bool(celula: String) -> Bool:
    return celula.strip().lower() == "true"


def _eh_int(celula: String) -> Bool:
    try:
        _ = atol(celula.strip())
        return True
    except:
        return False


def _eh_float(celula: String) -> Bool:
    try:
        _ = atof(celula.strip())
        return True
    except:
        return False


def _partir_linhas(texto: String) -> List[String]:
    var brutas = texto.split("\n")
    var linhas = List[String]()
    for linha in brutas:
        var limpa = String(linha).replace("\r", "")
        if limpa == "":
            continue
        linhas.append(limpa^)
    return linhas^


def _inferir_tipo(celulas: List[String], ausentes: List[Bool]) -> Int:
    var tem_valor = False
    var so_bool = True
    var so_int = True
    var so_float = True
    var so_data = True
    for i in range(len(celulas)):
        if ausentes[i]:
            continue
        tem_valor = True
        if not _eh_bool(celulas[i]):
            so_bool = False
        if not _eh_int(celulas[i]):
            so_int = False
        if not _eh_float(celulas[i]):
            so_float = False
        if not eh_data_iso(celulas[i]):
            so_data = False
    if not tem_valor:
        return Tipo.TEXTO
    # AAAA-MM-DD nunca colide com inteiro, real ou logico
    if so_data:
        return Tipo.DATA
    if so_bool:
        return Tipo.LOGICO
    if so_int:
        return Tipo.INTEIRO
    if so_float:
        return Tipo.REAL
    return Tipo.TEXTO


def _coluna_de_celulas(nome: String, celulas: List[String]) raises -> Coluna:
    var ausentes = List[Bool]()
    for celula in celulas:
        ausentes.append(_eh_na(celula))
    var tipo = _inferir_tipo(celulas, ausentes)

    if tipo == Tipo.LOGICO:
        var valores = List[Bool]()
        for i in range(len(celulas)):
            if ausentes[i]:
                valores.append(False)
            else:
                valores.append(_para_bool(celulas[i]))
        return Coluna.de_logicos(nome, valores^, ausentes^)

    if tipo == Tipo.DATA:
        var valores = List[Int64]()
        for i in range(len(celulas)):
            if ausentes[i]:
                valores.append(Int64(0))
            else:
                valores.append(Int64(parse_data_iso(celulas[i])))
        return Coluna.de_datas(nome, valores^, ausentes^)

    if tipo == Tipo.INTEIRO:
        var valores = List[Int64]()
        for i in range(len(celulas)):
            if ausentes[i]:
                valores.append(Int64(0))
            else:
                valores.append(Int64(atol(celulas[i].strip())))
        return Coluna.de_inteiros(nome, valores^, ausentes^)

    if tipo == Tipo.REAL:
        var valores = List[Float64]()
        for i in range(len(celulas)):
            if ausentes[i]:
                valores.append(0.0)
            else:
                valores.append(atof(celulas[i].strip()))
        return Coluna.de_reais(nome, valores^, ausentes^)

    var textos = List[String]()
    for i in range(len(celulas)):
        if ausentes[i]:
            textos.append("")
        else:
            textos.append(celulas[i].copy())
    return Coluna.de_textos(nome, textos^, ausentes^)


def ler_csv(
    caminho: String,
    delimitador: String = ",",
    tem_cabecalho: Bool = True,
    nrows: Int = -1,
) raises -> Tabela:
    """Le CSV em Mojo puro. Campos com o delimitador dentro de aspas ainda nao sao suportados."""
    var texto = Path(caminho).read_text()
    var linhas = _partir_linhas(texto)
    if len(linhas) == 0:
        raise Error("CSV vazio: " + caminho)

    var inicio = 0
    var nomes = List[String]()
    if tem_cabecalho:
        var cab = linhas[0].split(delimitador)
        for nome in cab:
            nomes.append(String(nome.strip()))
        inicio = 1
    else:
        var n_cols_sem = len(linhas[0].split(delimitador))
        for i in range(n_cols_sem):
            nomes.append("col" + String(i))

    var n_cols = len(nomes)
    if n_cols == 0:
        raise Error("CSV sem colunas: " + caminho)

    var grade = List[List[String]]()
    for _ in range(n_cols):
        grade.append(List[String]())

    var lidas = 0
    for i in range(inicio, len(linhas)):
        if nrows >= 0 and lidas >= nrows:
            break
        var campos = linhas[i].split(delimitador)
        if len(campos) != n_cols:
            raise Error(
                "linha "
                + String(i + 1)
                + " tem "
                + String(len(campos))
                + " campos, esperado "
                + String(n_cols)
            )
        for c in range(n_cols):
            grade[c].append(String(campos[c]))
        lidas += 1

    if lidas == 0:
        raise Error("CSV sem linhas de dados: " + caminho)

    var colunas = List[Coluna]()
    for c in range(n_cols):
        colunas.append(_coluna_de_celulas(nomes[c], grade[c]))
    return Tabela(colunas^)


def para_csv(tabela: Tabela, caminho: String, delimitador: String = ",") raises:
    var saida = String()
    var nomes = tabela.nomes()
    for i in range(len(nomes)):
        if i > 0:
            saida += delimitador
        saida += nomes[i]
    saida += "\n"

    for linha in range(tabela.linhas()):
        for c in range(tabela.colunas()):
            if c > 0:
                saida += delimitador
            saida += tabela.pegar(nomes[c]).texto_em(linha)
        saida += "\n"

    Path(caminho).write_text(saida)
