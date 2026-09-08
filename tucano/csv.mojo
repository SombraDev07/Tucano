"""Leitura e escrita de CSV sobre o Memory Engine (M5).

`bytes -> scanner -> parser tipado -> buffers`. Nenhuma `String` por celula: o
scanner marca fronteiras, os parsers leem direto do buffer, e so coluna de texto
materializa `String`.

Tres entradas:
- `ler_csv`      — infere o tipo de cada coluna
- `ler_csv_tipado` — schema explicito, sem adivinhacao
- `LeitorCSV`    — le em fatias, para nao materializar a tabela inteira
"""

from std.pathlib import Path
from .coluna import Coluna
from .tabela import Tabela
from .tipos import Tipo
from .dtype import DType
from .schema import Campo, Schema
from .datas import data_para_texto
from .erros import erro_coluna
from .scanner import (
    Campos,
    escanear,
    eh_na,
    eh_bool,
    para_bool,
    eh_data,
    parse_data,
    eh_datahora,
    parse_datahora,
    parse_int,
    parse_float,
    para_texto,
)


def _delim_byte(delimitador: String) raises -> UInt8:
    var b = delimitador.as_bytes()
    if len(b) != 1:
        raise Error("delimitador deve ser um unico byte: '" + delimitador + "'")
    return b[0]


def _inferir_coluna(
    bytes: List[UInt8], campos: Campos, col: Int, linha_ini: Int
) raises -> Int:
    """Tipo da coluna, decidido sobre as faixas de bytes — sem alocar."""
    var tem_valor = False
    var so_datahora = True
    var so_data = True
    var so_bool = True
    var so_int = True
    var so_float = True

    for l in range(linha_ini, campos.n_linhas):
        var k = campos.indice(l, col)
        var ini = campos.inicio[k]
        var fim = campos.fim[k]
        if eh_na(bytes, ini, fim):
            continue
        tem_valor = True
        if so_datahora and not eh_datahora(bytes, ini, fim):
            so_datahora = False
        if so_data and not eh_data(bytes, ini, fim):
            so_data = False
        if so_bool and not eh_bool(bytes, ini, fim):
            so_bool = False
        var ok = False
        if so_int:
            _ = parse_int(bytes, ini, fim, ok)
            if not ok:
                so_int = False
        if so_float:
            ok = False
            _ = parse_float(bytes, ini, fim, ok)
            if not ok:
                so_float = False
        if (
            not so_datahora
            and not so_data
            and not so_bool
            and not so_int
            and not so_float
        ):
            break

    if not tem_valor:
        return Tipo.TEXTO
    # formatos ISO nunca colidem com inteiro, real ou logico
    if so_datahora:
        return Tipo.DATAHORA
    if so_data:
        return Tipo.DATA
    if so_bool:
        return Tipo.LOGICO
    if so_int:
        return Tipo.INTEIRO
    if so_float:
        return Tipo.REAL
    return Tipo.TEXTO


def _construir_coluna(
    bytes: List[UInt8],
    campos: Campos,
    col: Int,
    linha_ini: Int,
    linha_fim: Int,
    nome: String,
    tipo: Int,
) raises -> Coluna:
    var n = linha_fim - linha_ini
    var ausentes = List[Bool](capacity=n)

    if tipo == Tipo.INTEIRO or tipo == Tipo.DATA or tipo == Tipo.DATAHORA:
        var vals = List[Int64](capacity=n)
        for l in range(linha_ini, linha_fim):
            var k = campos.indice(l, col)
            var ini = campos.inicio[k]
            var fim = campos.fim[k]
            if eh_na(bytes, ini, fim):
                vals.append(Int64(0))
                ausentes.append(True)
                continue
            ausentes.append(False)
            if tipo == Tipo.DATA:
                vals.append(parse_data(bytes, ini, fim))
            elif tipo == Tipo.DATAHORA:
                vals.append(parse_datahora(bytes, ini, fim))
            else:
                var ok = False
                var v = parse_int(bytes, ini, fim, ok)
                if not ok:
                    raise Error(
                        "coluna '" + nome + "': valor nao inteiro na linha "
                        + String(l - linha_ini + 1)
                    )
                vals.append(v)
        if tipo == Tipo.DATA:
            return Coluna.de_datas(nome, vals^, ausentes^)
        if tipo == Tipo.DATAHORA:
            return Coluna.de_datahoras(nome, vals^, ausentes^)
        return Coluna.de_inteiros(nome, vals^, ausentes^)

    if tipo == Tipo.REAL:
        var vals = List[Float64](capacity=n)
        for l in range(linha_ini, linha_fim):
            var k = campos.indice(l, col)
            var ini = campos.inicio[k]
            var fim = campos.fim[k]
            if eh_na(bytes, ini, fim):
                vals.append(0.0)
                ausentes.append(True)
                continue
            ausentes.append(False)
            var ok = False
            var v = parse_float(bytes, ini, fim, ok)
            if not ok:
                raise Error(
                    "coluna '" + nome + "': valor nao numerico na linha "
                    + String(l - linha_ini + 1)
                )
            vals.append(v)
        return Coluna.de_reais(nome, vals^, ausentes^)

    if tipo == Tipo.LOGICO:
        var vals = List[Bool](capacity=n)
        for l in range(linha_ini, linha_fim):
            var k = campos.indice(l, col)
            var ini = campos.inicio[k]
            var fim = campos.fim[k]
            if eh_na(bytes, ini, fim):
                vals.append(False)
                ausentes.append(True)
                continue
            ausentes.append(False)
            if not eh_bool(bytes, ini, fim):
                raise Error(
                    "coluna '" + nome + "': valor nao logico na linha "
                    + String(l - linha_ini + 1)
                )
            vals.append(para_bool(bytes, ini, fim))
        return Coluna.de_logicos(nome, vals^, ausentes^)

    var textos = List[String](capacity=n)
    for l in range(linha_ini, linha_fim):
        var k = campos.indice(l, col)
        var ini = campos.inicio[k]
        var fim = campos.fim[k]
        if eh_na(bytes, ini, fim):
            textos.append("")
            ausentes.append(True)
        else:
            textos.append(para_texto(bytes, ini, fim, campos.citado[k] != 0))
            ausentes.append(False)
    return Coluna.de_textos(nome, textos^, ausentes^)


def _nomes_do_cabecalho(
    bytes: List[UInt8], campos: Campos, tem_cabecalho: Bool
) raises -> List[String]:
    var nomes = List[String]()
    if tem_cabecalho:
        for c in range(campos.n_cols):
            var k = campos.indice(0, c)
            nomes.append(
                para_texto(bytes, campos.inicio[k], campos.fim[k], campos.citado[k] != 0)
            )
    else:
        for c in range(campos.n_cols):
            nomes.append("col" + String(c))
    return nomes^


def _montar(
    bytes: List[UInt8],
    campos: Campos,
    nomes: List[String],
    tipos: List[Int],
    linha_ini: Int,
    linha_fim: Int,
) raises -> Tabela:
    var colunas = List[Coluna]()
    for c in range(campos.n_cols):
        colunas.append(
            _construir_coluna(
                bytes, campos, c, linha_ini, linha_fim, nomes[c], tipos[c]
            )
        )
    return Tabela(colunas^)


struct FonteCSV(Movable):
    """Buffer de bytes + fronteiras dos campos. Nunca copiado."""

    var bytes: List[UInt8]
    var campos: Campos

    def __init__(out self, var bytes: List[UInt8], var campos: Campos):
        self.bytes = bytes^
        self.campos = campos^


def _ler_campos(
    caminho: String, delimitador: String, tem_cabecalho: Bool, nrows: Int, pular: Int
) raises -> FonteCSV:
    var bytes = Path(caminho).read_bytes()
    var limite = nrows
    if limite >= 0 and tem_cabecalho:
        limite += 1
    var campos = escanear(bytes, _delim_byte(delimitador), pular, limite)
    if campos.n_linhas == 0:
        raise Error("CSV vazio: " + caminho)
    if campos.n_cols == 0:
        raise Error("CSV sem colunas: " + caminho)
    return FonteCSV(bytes^, campos^)


def ler_csv(
    caminho: String,
    delimitador: String = ",",
    tem_cabecalho: Bool = True,
    nrows: Int = -1,
    pular: Int = 0,
) raises -> Tabela:
    """Le CSV inferindo o tipo de cada coluna.

    Suporta aspas RFC 4180: delimitador e quebra de linha dentro do campo, e
    `""` como aspa escapada.
    """
    var fonte = _ler_campos(caminho, delimitador, tem_cabecalho, nrows, pular)
    ref bytes = fonte.bytes
    ref campos = fonte.campos

    var nomes = _nomes_do_cabecalho(bytes, campos, tem_cabecalho)
    var linha_ini = 0
    if tem_cabecalho:
        linha_ini = 1
    if campos.n_linhas <= linha_ini:
        raise Error("CSV sem linhas de dados: " + caminho)

    var tipos = List[Int]()
    for c in range(campos.n_cols):
        tipos.append(_inferir_coluna(bytes, campos, c, linha_ini))
    return _montar(bytes, campos, nomes, tipos, linha_ini, campos.n_linhas)


def ler_csv_tipado(
    caminho: String,
    schema: Schema,
    delimitador: String = ",",
    tem_cabecalho: Bool = True,
    nrows: Int = -1,
    pular: Int = 0,
) raises -> Tabela:
    """Le CSV com schema explicito — sem inferencia, sem surpresa.

    A inferencia acerta na maioria dos casos, mas so o schema explicito garante
    que o tipo de hoje e o mesmo de amanha quando o arquivo mudar.
    """
    var fonte = _ler_campos(caminho, delimitador, tem_cabecalho, nrows, pular)
    ref bytes = fonte.bytes
    ref campos = fonte.campos

    if schema.tamanho() != campos.n_cols:
        raise Error(
            "schema tem " + String(schema.tamanho()) + " campos, CSV tem "
            + String(campos.n_cols) + " colunas"
        )

    var linha_ini = 0
    if tem_cabecalho:
        linha_ini = 1
    if campos.n_linhas <= linha_ini:
        raise Error("CSV sem linhas de dados: " + caminho)

    var nomes = List[String]()
    var tipos = List[Int]()
    for i in range(schema.tamanho()):
        var campo = schema.campo_em(i)
        nomes.append(campo.nome)
        tipos.append(campo.dtype.codigo)
    return _montar(bytes, campos, nomes, tipos, linha_ini, campos.n_linhas)


struct LeitorCSV(Movable):
    """Leitura em fatias: a tabela materializada por vez e limitada.

    O buffer de bytes e as fronteiras dos campos ainda ficam todos em memoria —
    E/S com memoria limitada de verdade e trabalho do out-of-core (M9). O que
    isto entrega e nao materializar a tabela inteira de uma vez.
    """

    var fonte: FonteCSV
    var nomes: List[String]
    var tipos: List[Int]
    var linha_ini: Int
    var cursor: Int

    def __init__(
        out self,
        caminho: String,
        delimitador: String = ",",
        tem_cabecalho: Bool = True,
        pular: Int = 0,
    ) raises:
        self.fonte = _ler_campos(caminho, delimitador, tem_cabecalho, -1, pular)
        self.nomes = _nomes_do_cabecalho(
            self.fonte.bytes, self.fonte.campos, tem_cabecalho
        )
        self.linha_ini = 0
        if tem_cabecalho:
            self.linha_ini = 1
        self.tipos = List[Int]()
        for c in range(self.fonte.campos.n_cols):
            self.tipos.append(
                _inferir_coluna(
                    self.fonte.bytes, self.fonte.campos, c, self.linha_ini
                )
            )
        self.cursor = self.linha_ini

    def total_linhas(self) -> Int:
        return self.fonte.campos.n_linhas - self.linha_ini

    def restantes(self) -> Int:
        return self.fonte.campos.n_linhas - self.cursor

    def fim(self) -> Bool:
        return self.cursor >= self.fonte.campos.n_linhas

    def schema(self) raises -> Schema:
        var campos_out = List[Campo]()
        for c in range(self.fonte.campos.n_cols):
            campos_out.append(Campo(self.nomes[c], DType(self.tipos[c])))
        return Schema(campos_out^)

    def proximo(mut self, tamanho: Int) raises -> Tabela:
        """Proxima fatia de ate `tamanho` linhas."""
        if tamanho <= 0:
            raise Error("tamanho de fatia deve ser positivo")
        if self.fim():
            raise Error("leitor no fim: nao ha mais linhas")
        var ate = self.cursor + tamanho
        if ate > self.fonte.campos.n_linhas:
            ate = self.fonte.campos.n_linhas
        var t = _montar(
            self.fonte.bytes,
            self.fonte.campos,
            self.nomes,
            self.tipos,
            self.cursor,
            ate,
        )
        self.cursor = ate
        return t^


def _precisa_aspas(valor: String, delim: UInt8) -> Bool:
    for b in valor.as_bytes():
        if b == delim or b == UInt8(34) or b == UInt8(10) or b == UInt8(13):
            return True
    return False


def _citar(valor: String) -> String:
    """Envolve em aspas e duplica as aspas internas (RFC 4180)."""
    return '"' + valor.replace('"', '""') + '"'


def _celula(valor: String, delim: UInt8) -> String:
    if _precisa_aspas(valor, delim):
        return _citar(valor)
    return valor


def para_csv(tabela: Tabela, caminho: String, delimitador: String = ",") raises:
    """Escreve CSV, citando campos que contenham delimitador, aspas ou quebra."""
    var delim = _delim_byte(delimitador)
    var nomes = tabela.nomes()
    # as colunas sao buscadas UMA vez, nao por celula
    var colunas = tabela.lote()

    var saida = String()
    for i in range(len(nomes)):
        if i > 0:
            saida += delimitador
        saida += _celula(nomes[i], delim)
    saida += "\n"

    for linha in range(tabela.linhas()):
        for c in range(len(colunas)):
            if c > 0:
                saida += delimitador
            saida += _celula(colunas[c].texto_em(linha), delim)
        saida += "\n"

    Path(caminho).write_text(saida)
