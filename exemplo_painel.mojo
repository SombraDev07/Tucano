"""Painel do Tucano: um exemplo executavel.

    pixi run painel

Abre em http://127.0.0.1:8080. Cada widget guarda uma consulta, nao uma tabela:
mexer no filtro muda o plano e reexecuta, e o navegador recebe so o resultado
agregado. O rodape da pagina mostra quantos bytes de fato atravessaram.
"""

from tucano import (
    ler_parquet,
    Painel,
    soma,
    media,
    contar,
    distintos,
    coluna,
    lit,
)


def main() raises:
    var vendas = ler_parquet("tests/fixtures/grupos.parquet")

    var p = Painel("Vendas por grupo", vendas)

    p.kpi("Faturamento", soma("valor"))
    p.kpi("Ticket medio", media("valor"))
    p.kpi("Registros", contar())
    p.kpi("Grupos", distintos("grupo"))

    p.grafico("Faturamento por grupo", "grupo", soma("valor"), "barra")
    p.grafico("Participacao", "grupo", soma("valor"), "pizza")
    p.grafico("Registros por grupo", "grupo", contar(), "linha")

    var colunas = List[String]()
    colunas.append("id")
    colunas.append("grupo")
    colunas.append("valor")
    p.tabela("Detalhe", colunas, 50)

    p.filtro("grupo")

    p.servir(8080)
