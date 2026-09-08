"""Painel (M7).

**O widget guarda uma consulta, nao uma tabela.** Mexer num filtro muda o plano
e reexecuta; o navegador recebe o resultado agregado. Um grafico de doze meses
recebe doze pontos, mesmo que a fonte tenha milhoes de linhas — e o rodape da
pagina mostra quantos bytes de fato atravessaram a rede, para que a afirmacao
seja verificavel e nao apenas dita.

    var p = Painel("Vendas", vendas)
    p.kpi("Faturamento", soma("valor"))
    p.grafico("Por cidade", "cidade", soma("valor"))
    p.tabela("Detalhe", ["data", "cidade", "valor"])
    p.filtro("cidade")
    p.servir(8080)
"""

from .coluna import Coluna
from .tabela import Tabela, Consulta
from .dtype import DType
from .expr import Expr, coluna, lit_texto, lit_int, lit_data, lit_datahora
from .agregacao import Agregacao
from .executor import posicao_no_lote, n_linhas
from .json import escapar, tabela_para_json, lista_para_json
from .erros import erro_coluna
from .http import (
    Servidor,
    Requisicao,
    ler_requisicao,
    responder_html,
    responder_json,
    responder_erro,
    fechar_cliente,
    parametros,
)
from .painel_web import pagina


struct TipoWidget:
    comptime KPI = 0
    comptime GRAFICO = 1
    comptime TABELA = 2


struct Widget(Copyable, Movable):
    var tipo: Int
    var titulo: String
    var agregacao: Agregacao
    var eixo_x: String
    var forma: String
    var colunas: List[String]
    var limite: Int

    def __init__(
        out self,
        tipo: Int,
        titulo: String,
        var agregacao: Agregacao,
        eixo_x: String,
        forma: String,
        var colunas: List[String],
        limite: Int,
    ):
        self.tipo = tipo
        self.titulo = titulo
        self.agregacao = agregacao^
        self.eixo_x = eixo_x
        self.forma = forma
        self.colunas = colunas^
        self.limite = limite


def _juntar_nome(mut lista: List[String], nome: String):
    if nome == "":
        return
    for x in lista:
        if x == nome:
            return
    lista.append(nome)


def _literal_do_valor(tipo: Int, valor: String) raises -> Expr:
    """Converte o texto vindo da URL para o literal do tipo da coluna."""
    if tipo == DType.TEXTO:
        return lit_texto(valor)
    if tipo == DType.DATA:
        return lit_data(valor)
    if tipo == DType.DATAHORA:
        return lit_datahora(valor)
    if tipo == DType.INTEIRO:
        return lit_int(atol(valor))
    raise Error(
        "filtro sobre coluna de tipo nao suportado — use texto, inteiro ou data"
    )


struct Painel(Movable):
    var titulo: String
    var fonte: List[Coluna]
    var widgets: List[Widget]
    var filtros: List[String]

    def __init__(out self, titulo: String, fonte: Tabela):
        self.titulo = titulo
        self.fonte = fonte.lote()
        self.widgets = List[Widget]()
        self.filtros = List[String]()

    # ------------------------------------------------------------ widgets

    def kpi(mut self, titulo: String, var agregacao: Agregacao):
        """Um numero: a agregacao sobre tudo que passou pelos filtros."""
        self.widgets.append(
            Widget(
                TipoWidget.KPI, titulo, agregacao^, "", "", List[String](), 0
            )
        )

    def grafico(
        mut self,
        titulo: String,
        x: String,
        var y: Agregacao,
        forma: String = "barra",
    ):
        """Agrupa por `x` e reduz com `y`. Formas: barra, linha, pizza.

        Para eixo derivado — mes, ano — crie a coluna antes com `com_coluna` e
        passe o nome dela. O painel nao precisa de uma segunda linguagem.
        """
        self.widgets.append(
            Widget(TipoWidget.GRAFICO, titulo, y^, x, forma, List[String](), 0)
        )

    def tabela(
        mut self, titulo: String, colunas: List[String], limite: Int = 50
    ):
        var copia = List[String]()
        for c in colunas:
            copia.append(c)
        self.widgets.append(
            Widget(
                TipoWidget.TABELA, titulo, Agregacao(0, ""), "", "", copia^, limite
            )
        )

    def filtro(mut self, nome_coluna: String) raises:
        _ = posicao_no_lote(self.fonte, nome_coluna)
        self.filtros.append(nome_coluna)

    # ------------------------------------------------------------ dados

    def _valores_do_filtro(self, nome_coluna: String) raises -> List[String]:
        var t = Tabela(self.fonte.copy()).unicos(nome_coluna)
        var col = t.pegar(nome_coluna)
        var out = List[String]()
        for i in range(col.tamanho()):
            if not col.eh_ausente(i):
                out.append(col.texto_em(i))
        return out^

    def json_painel(self) raises -> String:
        var out = String('{"titulo":') + escapar(self.titulo) + ',"filtros":['
        for i in range(len(self.filtros)):
            if i > 0:
                out += ","
            out += (
                '{"coluna":' + escapar(self.filtros[i]) + ',"valores":'
                + lista_para_json(self._valores_do_filtro(self.filtros[i])) + "}"
            )
        return out + "]}"

    def colunas_usadas(self) raises -> List[String]:
        """Uniao das colunas que os widgets e os filtros leem.

        O painel sabe disso antes de executar, entao a projecao entra no plano e
        o resto nem e materializado. E poda de colunas no nivel do painel, pelo
        mesmo motivo que o otimizador faz no nivel do plano.
        """
        var out = List[String]()
        for f in self.filtros:
            _juntar_nome(out, f)
        for w in self.widgets:
            if w.tipo == TipoWidget.TABELA:
                for c in w.colunas:
                    _juntar_nome(out, c)
            else:
                _juntar_nome(out, w.eixo_x)
                _juntar_nome(out, w.agregacao.coluna)
        return out^

    def _filtrada(self, consulta: String) raises -> Consulta:
        """Aplica os filtros ativos como etapas do plano."""
        var q = Consulta(self.fonte.copy())
        var ps = parametros(consulta)
        var i = 0
        while i + 1 < len(ps):
            var nome = ps[i]
            var valor = ps[i + 1]
            i += 2
            if valor == "":
                continue
            var achou = False
            for f in self.filtros:
                if f == nome:
                    achou = True
            if not achou:
                continue
            var tipo = self.fonte[posicao_no_lote(self.fonte, nome)].tipo
            q = q^.onde(coluna(nome).eq(_literal_do_valor(tipo, valor)))

        var usadas = self.colunas_usadas()
        if len(usadas) > 0 and len(usadas) < len(self.fonte):
            q = q^.selecionar(usadas)
        return q^

    def json_dados(self, consulta: String) raises -> String:
        var base = self._filtrada(consulta)
        var filtrada = base.coletar()
        var corpo = String("[")
        var primeiro_widget = True

        for w in self.widgets:
            if not primeiro_widget:
                corpo += ","
            primeiro_widget = False
            corpo += '{"titulo":' + escapar(w.titulo)

            if w.tipo == TipoWidget.KPI:
                var aggs = List[Agregacao]()
                aggs.append(w.agregacao.copy())
                var r = filtrada.agregar_total(aggs^).coletar()
                var nome = w.agregacao.nome_saida()
                corpo += ',"tipo":"kpi","valor":'
                if r.linhas() == 0 or r.pegar(nome).eh_ausente(0):
                    corpo += "null"
                else:
                    ref c = r.pegar(nome)
                    if c.tipo == DType.REAL:
                        corpo += String(c.reals[0])
                    elif c.tipo == DType.INTEIRO:
                        corpo += String(c.ints[0])
                    else:
                        corpo += escapar(c.texto_em(0))
                corpo += "}"

            elif w.tipo == TipoWidget.GRAFICO:
                var chaves = List[String]()
                chaves.append(w.eixo_x)
                var aggs = List[Agregacao]()
                aggs.append(w.agregacao.copy())
                # o eixo sai ordenado: um grafico em ordem de aparicao dos
                # grupos nao e um grafico, e um sorteio
                var r = (
                    filtrada.agrupar(chaves).agregar(aggs^).ordenar(chaves).coletar()
                )
                var nome = w.agregacao.nome_saida()
                ref eixo = r.pegar(w.eixo_x)
                ref valores = r.pegar(nome)
                corpo += ',"tipo":"grafico","forma":' + escapar(w.forma) + ',"pontos":['
                for i in range(r.linhas()):
                    if i > 0:
                        corpo += ","
                    corpo += '{"x":' + escapar(eixo.texto_em(i)) + ',"y":'
                    if valores.eh_ausente(i):
                        corpo += "null"
                    elif valores.tipo == DType.REAL:
                        corpo += String(valores.reals[i])
                    else:
                        corpo += String(valores.ints[i])
                    corpo += "}"
                corpo += "]}"

            else:
                var recorte = filtrada.selecionar(w.colunas)
                var limitada = recorte.primeiras_linhas(w.limite)
                corpo += ',"tipo":"tabela","colunas":' + lista_para_json(w.colunas)
                corpo += ',"linhas":' + tabela_para_json(limitada) + "}"

        corpo += "]"

        return (
            String('{"widgets":') + corpo
            + ',"linhas_fonte":' + String(n_linhas(self.fonte))
            + ',"linhas_filtradas":' + String(filtrada.linhas())
            + ',"bytes_resposta":' + String(corpo.byte_length())
            + "}"
        )

    # ------------------------------------------------------------ servidor

    def servir(self, porta: Int = 8080, requisicoes: Int = -1) raises:
        """Sobe o servidor. `requisicoes` limita o laco — util em teste."""
        var s = Servidor(porta)
        print("painel '" + self.titulo + "' em http://127.0.0.1:" + String(porta))
        print("Ctrl+C para parar")
        var n = 0
        while requisicoes < 0 or n < requisicoes:
            var cliente = s.aceitar()
            try:
                var r = ler_requisicao(cliente)
                if r.caminho == "/":
                    responder_html(cliente, pagina(self.titulo))
                elif r.caminho == "/api/painel":
                    responder_json(cliente, self.json_painel())
                elif r.caminho == "/api/dados":
                    responder_json(cliente, self.json_dados(r.consulta))
                else:
                    responder_erro(
                        cliente, "404 Not Found", "rota desconhecida: " + r.caminho
                    )
            except e:
                try:
                    responder_erro(cliente, "500 Internal Server Error", String(e))
                except:
                    pass
            fechar_cliente(cliente)
            n += 1
        s.fechar()
