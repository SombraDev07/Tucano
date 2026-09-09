"""Escreve .xlsx com o Tucano e le de volta, para o openpyxl conferir depois.

    pixi run xlsx-roundtrip && pixi run -e fixtures interop-xlsx
"""

from tucano.coluna import Coluna
from tucano.tabela import Tabela
from tucano.xlsx import para_xlsx, ler_xlsx
from tucano.datas import dias_desde_epoch


def _misto() raises -> Tabela:
    var nomes = List[String]()
    for x in ["ana", "bru & co", "<carlos>", ""]:
        nomes.append(String(x))
    var aus = List[Bool]()
    for b in [False, False, False, True]:
        aus.append(Bool(b))
    var qtd = List[Int64]()
    for x in [1, 20, -3, 400]:
        qtd.append(Int64(x))
    var preco = List[Float64]()
    for x in [1.5, 2.25, -0.75, 100.0]:
        preco.append(Float64(x))
    var ok = List[Bool]()
    for b in [True, False, True, False]:
        ok.append(Bool(b))
    var cols = List[Coluna]()
    cols.append(Coluna.de_textos("nome", nomes^, aus^))
    cols.append(Coluna.de_inteiros("qtd", qtd^))
    cols.append(Coluna.de_reais("preco", preco^))
    cols.append(Coluna.de_logicos("ok", ok^))
    return Tabela(cols^)


def _datas() raises -> Tabela:
    var dias = List[Int64]()
    dias.append(Int64(dias_desde_epoch(2024, 1, 15)))
    dias.append(Int64(dias_desde_epoch(2024, 2, 29)))
    dias.append(Int64(dias_desde_epoch(1969, 12, 31)))
    var micros = List[Int64]()
    micros.append(
        Int64(dias_desde_epoch(2024, 1, 15)) * 86400000000
        + Int64(8 * 3600 + 30 * 60) * 1000000
    )
    micros.append(
        Int64(dias_desde_epoch(2024, 2, 29)) * 86400000000
        + Int64(23 * 3600 + 59 * 60 + 59) * 1000000
    )
    micros.append(
        Int64(dias_desde_epoch(1969, 12, 31)) * 86400000000
        + Int64(23 * 3600 + 59 * 60 + 59) * 1000000
    )
    var cols = List[Coluna]()
    cols.append(Coluna.de_datas("quando", dias^))
    cols.append(Coluna.de_datahoras("carimbo", micros^))
    return Tabela(cols^)


def main() raises:
    var casos = List[String]()
    casos.append("misto")
    casos.append("datas")
    for nome in casos:
        var t: Tabela
        if nome == "misto":
            t = _misto()
        else:
            t = _datas()
        var aba = String("Vendas")
        if nome == "datas":
            aba = "Datas"
        var caminho = "/tmp/tucano_xlsx_" + nome + ".xlsx"
        para_xlsx(t, caminho, aba)
        var volta = ler_xlsx(caminho)
        if volta.linhas() != t.linhas() or volta.colunas() != t.colunas():
            raise Error(
                "xlsx: " + nome + " voltou " + String(volta.linhas()) + "x"
                + String(volta.colunas()) + ", esperado " + String(t.linhas())
                + "x" + String(t.colunas())
            )
        var difs = 0
        for c in range(t.colunas()):
            var a = t.pegar(t.nomes()[c])
            var b = volta.pegar(volta.nomes()[c])
            for i in range(t.linhas()):
                if a.eh_ausente(i) != b.eh_ausente(i):
                    difs += 1
                elif not a.eh_ausente(i) and a.texto_em(i) != b.texto_em(i):
                    difs += 1
        if difs != 0:
            raise Error("xlsx: " + nome + " divergiu em " + String(difs) + " celulas")
        print("  ok   ", nome, volta.linhas(), "linhas ", volta.colunas(), "colunas")
    print("ida e volta .xlsx confirmada")
