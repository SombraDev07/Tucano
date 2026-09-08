"""Tabela e Consulta — a face eager e a face lazy da mesma abstracao (M3).

As duas vivem no mesmo modulo porque sao mutuamente recursivas: `Tabela.onde()`
devolve `Consulta` e `Consulta.coletar()` devolve `Tabela`. O Mojo aceita
recursao mutua dentro de um modulo, mas nao ciclo entre modulos.

**Ergonomia eager, execucao lazy.** `tabela.onde(...)` parece imediato mas devolve
um plano; `mostrar()`, `linhas()`, `soma()` e companhia materializam sozinhos.
`coletar()` continua existindo para quem quer o controle.

Abaixo das duas fica o executor, que **nao** conhece nenhuma delas: opera sobre
lotes de `Coluna`. Essa e a separacao logico/fisico do M3.
"""

from .coluna import Coluna
from .schema import Campo, Schema, Shape
from .dtype import DType
from .erros import erro_coluna
from .expr import Expr
from .plano import Etapa, TipoEtapa, descrever_logico, descrever_fisico
from .agregacao import Agregacao, contar
from .parquet import (
    ler_parquet_lote,
    para_parquet_lote,
    esquema_parquet,
    VarreduraParquet,
)
from .fluxo import plano_flui, EstadoAgregacao
from .schema import Campo
from .otimizador import otimizar, PlanoOtimizado
from .executor import (
    executar,
    avisos_plano,
    esquema_apos,
    esquema_do_lote,
    TipoJuncao,
    coletar_linhas,
)


# ---------------------------------------------------------------- Consulta



struct Fonte:
    """De onde a consulta le.

    Quando a fonte e um arquivo, a leitura acontece no `coletar()` — depois do
    otimizador. E o que permite ler so as colunas que o plano usa, em vez de ler
    tudo e descartar.
    """

    comptime MEMORIA = 0
    comptime PARQUET = 1


struct Consulta(Copyable, Movable):
    """Pipeline lazy sobre um lote de colunas ou sobre um arquivo.

    `onde` / `selecionar` / `com_coluna` so acrescentam etapas ao plano. A
    materializacao e automatica: `mostrar()`, `linhas()`, `soma()` e companhia
    executam. `coletar()` continua existindo para quem quer o controle explicito.
    """

    var fonte: List[Coluna]
    var etapas: List[Etapa]
    var chaves_pendentes: List[String]
    var caminho: String
    var tipo_fonte: Int

    def __init__(out self, var fonte: List[Coluna]):
        self.fonte = fonte^
        self.etapas = List[Etapa]()
        self.chaves_pendentes = List[String]()
        self.caminho = ""
        self.tipo_fonte = Fonte.MEMORIA

    @staticmethod
    def de_parquet(caminho: String) -> Self:
        """Varredura adiada: o arquivo so e lido em `coletar()`."""
        var q = Self(List[Coluna]())
        q.caminho = caminho
        q.tipo_fonte = Fonte.PARQUET
        return q^

    def le_de_arquivo(self) -> Bool:
        return self.tipo_fonte != Fonte.MEMORIA

    @staticmethod
    def de(tab: Tabela) -> Self:
        return Self(tab.lote())

    # ------------------------------------------------------------ plano

    def onde(var self, var pred: Expr) -> Self:
        self.etapas.append(Etapa.filtro(pred^))
        return self^

    def selecionar(var self, nomes: List[String]) raises -> Self:
        if len(nomes) == 0:
            raise Error("selecionar exige pelo menos um nome")
        var copia = List[String]()
        for nome in nomes:
            copia.append(nome)
        self.etapas.append(Etapa.projecao(copia^))
        return self^

    def com_coluna(var self, nome: String, var expr: Expr) -> Self:
        """Coluna derivada. Substitui a coluna se o nome ja existir."""
        self.etapas.append(Etapa.com_coluna(nome, expr^))
        return self^

    def unir(
        var self, outra: Tabela, por: List[String], tipo: String = "interno"
    ) raises -> Self:
        """Junta com outra tabela pelas chaves dadas.

        `tipo` e "interno" ou "esquerda". As colunas de chave aparecem uma unica
        vez no resultado; nomes que colidem fora das chaves sao recusados, nao
        renomeados em silencio.
        """
        if len(por) == 0:
            raise Error("unir exige pelo menos uma chave")
        var chaves = List[String]()
        for c in por:
            chaves.append(c)
        self.etapas.append(
            Etapa.juncao(outra.lote(), chaves^, TipoJuncao.de_texto(tipo))
        )
        return self^

    def ordenar(
        var self, chaves: List[String], descendente: Bool = False
    ) raises -> Self:
        """Ordena pelas colunas dadas. Ausente vai sempre para o fim.

        A ordenacao e **estavel**, entao direcoes mistas saem de dois passos:
        `ordenar(["b"], True).ordenar(["a"])` da `a` crescente e, dentro de cada
        `a`, `b` decrescente. Por isso nao ha uma segunda forma de ordenar.
        """
        if len(chaves) == 0:
            raise Error("ordenar exige pelo menos uma coluna")
        var copia = List[String]()
        var desc = List[Bool]()
        for c in chaves:
            copia.append(c)
            desc.append(descendente)
        self.etapas.append(Etapa.ordenacao(copia^, desc^))
        return self^

    def concatenar(var self, outra: Tabela) raises -> Self:
        """Empilha outra tabela. Exige mesmo esquema, na mesma ordem."""
        self.etapas.append(Etapa.concatenacao(outra.lote()))
        return self^

    def remover_na(var self, nomes: List[String] = List[String]()) raises -> Self:
        """Descarta linhas com ausente. Sem argumento, olha todas as colunas."""
        var copia = List[String]()
        for c in nomes:
            copia.append(c)
        self.etapas.append(Etapa.remover_na(copia^))
        return self^

    def preencher_na(var self, nome: String, var valor: Expr) raises -> Self:
        """Substitui os ausentes de uma coluna. Sem conversao implicita."""
        self.etapas.append(Etapa.preencher_na(nome, valor^))
        return self^

    def agrupar(var self, chaves: List[String]) raises -> Self:
        """Define as chaves de grupo. Encadeie `.agregar([...])` em seguida."""
        if len(chaves) == 0:
            raise Error("agrupar exige pelo menos uma chave")
        var copia = List[String]()
        for c in chaves:
            copia.append(c)
        self.chaves_pendentes = copia^
        return self^

    def agregar_total(var self, var agregacoes: List[Agregacao]) raises -> Self:
        """Reduz a tabela inteira a uma linha, sem chave de grupo."""
        if len(agregacoes) == 0:
            raise Error("agregar exige pelo menos uma agregacao")
        self.etapas.append(Etapa.agregacao(List[String](), agregacoes^))
        return self^

    def agregar(var self, var agregacoes: List[Agregacao]) raises -> Self:
        """Reduz cada grupo. Exige um `agrupar` antes."""
        if len(self.chaves_pendentes) == 0:
            raise Error("agregar exige um agrupar antes")
        if len(agregacoes) == 0:
            raise Error("agregar exige pelo menos uma agregacao")
        var chaves = self.chaves_pendentes^
        self.chaves_pendentes = List[String]()
        self.etapas.append(Etapa.agregacao(chaves^, agregacoes^))
        return self^

    # ---------------------------------------------------------- inspecao

    def descrever(self) raises -> String:
        """Plano logico: o que o usuario pediu."""
        return descrever_logico(self.etapas)

    def descrever_fisico(self) raises -> String:
        """Plano fisico, com avisos de caminho escalar."""
        var s = descrever_fisico(self.etapas)
        var notas = self.avisos()
        if len(notas) > 0:
            s += "\n\navisos:"
            for nota in notas:
                s += "\n  ! " + nota
        return s

    def avisos(self) raises -> List[String]:
        """Operacoes que ainda nao terao kernel vetorizado no M4."""
        return avisos_plano(self.fonte, self.etapas)

    def etapas_do_plano(self) -> Int:
        return len(self.etapas)

    def esquema_previsto(self) raises -> Schema:
        """Esquema do resultado **sem executar o plano**.

        O usual e so descobrir o tipo de uma coluna derivada depois de calcula-la.
        Aqui o planejador sabe antes — e e sobre isso que o otimizador do M8 vai
        raciocinar.
        """
        return Schema(esquema_apos(esquema_do_lote(self.fonte), self.etapas))

    # ----------------------------------------------------- materializacao

    def _nomes_da_fonte(self) raises -> List[String]:
        if self.le_de_arquivo():
            return esquema_parquet(self.caminho).nomes()
        var out = List[String]()
        for c in self.fonte:
            out.append(c.nome)
        return out^

    def plano_otimizado(self) raises -> PlanoOtimizado:
        return otimizar(self.etapas, self._nomes_da_fonte())

    def _lote_de_entrada(self, colunas_lidas: List[String]) raises -> List[Coluna]:
        if self.le_de_arquivo():
            # aqui a poda vira menos I/O: as outras colunas nao saem do disco
            return ler_parquet_lote(self.caminho, colunas_lidas)
        if len(colunas_lidas) == 0:
            return self.fonte.copy()
        var out = List[Coluna]()
        for nome in colunas_lidas:
            for c in self.fonte:
                if c.nome == nome:
                    out.append(c.copy())
        return out^

    def coletar(self) raises -> Tabela:
        """Otimiza o plano e executa."""
        if len(self.chaves_pendentes) > 0:
            raise Error(
                "agrupar sem agregar: encadeie `.agregar([...])` depois de"
                " `.agrupar([...])`"
            )
        var plano = self.plano_otimizado()
        var entrada = self._lote_de_entrada(plano.colunas_lidas)
        return Tabela(executar(entrada, plano.etapas))

    def coletar_sem_otimizar(self) raises -> Tabela:
        """Executa o plano como escrito, sem otimizar.

        Existe para duas coisas: medir o ganho do otimizador, e provar que ele
        nao mudou a resposta. Uma regra que as vezes muda o resultado nao e
        otimizacao, e defeito — e isso precisa ser verificavel.
        """
        if len(self.chaves_pendentes) > 0:
            raise Error("agrupar sem agregar")
        var entrada: List[Coluna]
        if self.le_de_arquivo():
            entrada = ler_parquet_lote(self.caminho, List[String]())
        else:
            entrada = self.fonte.copy()
        return Tabela(executar(entrada, self.etapas))

    def pode_fluir(self) raises -> String:
        """"" se o plano executa em fluxo; a razao, se nao executa."""
        return plano_flui(self.plano_otimizado().etapas)

    def _esquema_da_entrada(self, colunas_lidas: List[String]) raises -> List[Campo]:
        var todos = List[Campo]()
        if self.le_de_arquivo():
            var e = esquema_parquet(self.caminho)
            for i in range(e.tamanho()):
                todos.append(e.campo_em(i))
        else:
            for c in self.fonte:
                todos.append(Campo(c.nome, c.dtype()))
        if len(colunas_lidas) == 0:
            return todos^
        var out = List[Campo]()
        for nome in colunas_lidas:
            for c in todos:
                if c.nome == nome:
                    out.append(c.copy())
        return out^

    def coletar_em_fluxo(self, linhas_por_fatia: Int = 200_000) raises -> Tabela:
        """Executa em memoria limitada, uma fatia de cada vez.

        Exige que o plano termine em agregacao: e o que permite trocar os dados
        pelo **estado dos grupos**, que e proporcional ao numero de grupos e nao
        ao de linhas. Sobre Parquet, a fatia e o row group, e o arquivo nunca e
        carregado inteiro.

        Ordenacao e juncao precisam do conjunto todo. O plano e recusado com essa
        explicacao, nao executado pela metade.
        """
        if len(self.chaves_pendentes) > 0:
            raise Error("agrupar sem agregar")
        var plano = self.plano_otimizado()
        var razao = plano_flui(plano.etapas)
        if razao != "":
            raise Error("coletar_em_fluxo: " + razao + " — use coletar()")

        var ultima = plano.etapas[len(plano.etapas) - 1].copy()
        var pre = List[Etapa]()
        for i in range(len(plano.etapas) - 1):
            pre.append(plano.etapas[i].copy())

        var esq_fonte = self._esquema_da_entrada(plano.colunas_lidas)
        var esq_entrada = esquema_apos(esq_fonte, pre)
        var estado = EstadoAgregacao(ultima.nomes, ultima.agregacoes, esq_entrada)

        if self.le_de_arquivo():
            var v = VarreduraParquet(self.caminho, plano.colunas_lidas)
            for g in range(v.n_grupos()):
                var lote = v.ler_grupo(g)
                estado.absorver(executar(lote, pre))
            v.fechar()
        else:
            var entrada = self._lote_de_entrada(plano.colunas_lidas)
            var n = 0
            if len(entrada) > 0:
                n = entrada[0].tamanho()
            var i = 0
            while i < n:
                var fim = i + linhas_por_fatia
                if fim > n:
                    fim = n
                var indices = List[Int](capacity=fim - i)
                for k in range(i, fim):
                    indices.append(k)
                var fatia = List[Coluna]()
                for c in entrada:
                    fatia.append(coletar_linhas(c, indices))
                estado.absorver(executar(fatia, pre))
                i = fim

        return Tabela(estado.finalizar())

    def descrever_otimizado(self) raises -> String:
        """Plano logico depois do otimizador."""
        return descrever_logico(self.plano_otimizado().etapas)

    def explicar(self) raises -> String:
        """Plano antes, plano depois e as regras que dispararam."""
        var plano = self.plano_otimizado()
        var s = String("LOGICO     ") + descrever_logico(self.etapas)
        s += "\nOTIMIZADO  " + descrever_logico(plano.etapas)
        if self.le_de_arquivo():
            s += "\nFONTE      parquet " + self.caminho
        var todas = self._nomes_da_fonte()
        s += "\nCOLUNAS    "
        if len(plano.colunas_lidas) == 0:
            s += String(len(todas)) + " de " + String(len(todas)) + " (sem poda)"
        else:
            s += String(len(plano.colunas_lidas)) + " de " + String(len(todas)) + " ["
            for i in range(len(plano.colunas_lidas)):
                if i > 0:
                    s += ", "
                s += plano.colunas_lidas[i]
            s += "]"
        s += "\nREGRAS     "
        if len(plano.regras) == 0:
            s += "nenhuma"
        else:
            for i in range(len(plano.regras)):
                if i > 0:
                    s += ", "
                s += plano.regras[i]
        return s

    def mostrar(self) raises:
        self.coletar().mostrar()

    def primeiras(self, n: Int = 5) raises:
        self.coletar().primeiras(n)

    def linhas(self) raises -> Int:
        return self.coletar().linhas()

    def colunas(self) raises -> Int:
        return self.coletar().colunas()

    def shape(self) raises -> Shape:
        return self.coletar().shape()

    def schema(self) raises -> Schema:
        return self.coletar().schema()

    def nomes(self) raises -> List[String]:
        return self.coletar().nomes()

    def pegar(self, nome: String) raises -> Coluna:
        return self.coletar().pegar(nome)

    def soma(self, nome: String) raises -> Float64:
        return self.coletar().soma(nome)

    def media(self, nome: String) raises -> Float64:
        return self.coletar().media(nome)


def ler_parquet(
    caminho: String, colunas: List[String] = List[String]()
) raises -> Tabela:
    """Le um arquivo Parquet. `colunas` faz column pruning."""
    return Tabela(ler_parquet_lote(caminho, colunas))


def para_parquet(
    tabela: Tabela, caminho: String, linhas_por_grupo: Int = 0
) raises:
    """Grava a tabela em Parquet.

    `linhas_por_grupo` divide o arquivo em row groups. Grupos menores permitem
    leitura em fluxo com pico de memoria menor.
    """
    para_parquet_lote(tabela.lote(), tabela.nomes(), caminho, linhas_por_grupo)


def varredura_parquet(caminho: String) -> Consulta:
    """Varredura adiada de Parquet: o arquivo so e lido em `coletar()`.

    E o que permite o otimizador decidir quais colunas ler antes de ler.
    """
    return Consulta.de_parquet(caminho)


def lazy(tab: Tabela) -> Consulta:
    """Entrada no pipeline lazy.

    Mantido por compatibilidade — prefira `tabela.onde(...)`, que ja devolve
    uma `Consulta`.
    """
    return Consulta.de(tab)


# ------------------------------------------------------------------ Tabela


struct Tabela(Copyable, Movable):
    """Tabela coluna-a-coluna tipada, Mojo puro.

    Storage columnar (M1). Execucao vetorizada (M3). Plano lazy: `lazy(tabela)`.

    Nao existe index de rotulo (Decisao 1 do CONTRATO): a contagem de linhas vem
    das proprias colunas, nunca de um campo paralelo que possa divergir. Duas
    tabelas so se combinam por join explicito.
    """

    var _colunas: List[Coluna]

    def __init__(out self, colunas: List[Coluna]) raises:
        if len(colunas) == 0:
            raise Error("tabela precisa de pelo menos uma coluna")
        var n = colunas[0].tamanho()
        var nomes_vistos = List[String]()
        var copia = List[Coluna]()
        for c in colunas:
            if c.tamanho() != n:
                raise Error("todas as colunas precisam ter o mesmo tamanho")
            for nome in nomes_vistos:
                if nome == c.nome:
                    raise Error("nome de coluna duplicado: " + c.nome)
            nomes_vistos.append(c.nome)
            copia.append(c.copy())
        self._colunas = copia^

    def linhas(self) -> Int:
        return self._colunas[0].tamanho()

    def colunas(self) -> Int:
        return len(self._colunas)

    def shape(self) -> Shape:
        return Shape(self.linhas(), self.colunas())

    def schema(self) raises -> Schema:
        var campos = List[Campo]()
        for c in self._colunas:
            campos.append(Campo(c.nome, c.dtype()))
        return Schema(campos^)

    def nomes(self) raises -> List[String]:
        return self.schema().nomes()

    def _posicao(self, nome: String) raises -> Int:
        for i in range(len(self._colunas)):
            if self._colunas[i].nome == nome:
                return i
        raise erro_coluna(nome, self.nomes())

    def pegar(self, nome: String) raises -> Coluna:
        return self._colunas[self._posicao(nome)].copy()

    def posicao(self, nome: String) raises -> Int:
        """Posicao de uma coluna pelo nome, com erro que sugere."""
        return self._posicao(nome)

    def lote(self) -> List[Coluna]:
        """Copia das colunas, no formato que o executor consome."""
        var out = List[Coluna]()
        for c in self._colunas:
            out.append(c.copy())
        return out^

    def dtype_de(self, nome: String) raises -> DType:
        """Tipo de uma coluna sem copiar a coluna."""
        return self._colunas[self._posicao(nome)].dtype()

    def eh_ausente(self, nome: String, i: Int) raises -> Bool:
        """Consulta de validade sem copiar a coluna."""
        return self._colunas[self._posicao(nome)].eh_ausente(i)

    def adicionar(self, coluna: Coluna) raises -> Self:
        if coluna.tamanho() != self.linhas():
            raise Error("coluna nova deve ter o mesmo numero de linhas")
        for c in self._colunas:
            if c.nome == coluna.nome:
                raise Error("coluna ja existe: " + coluna.nome)
        var cols = List[Coluna]()
        for c in self._colunas:
            cols.append(c.copy())
        cols.append(coluna.copy())
        return Self(cols^)

    def remover(self, nome: String) raises -> Self:
        if self.colunas() == 1:
            raise Error("nao e possivel remover a unica coluna")
        var cols = List[Coluna]()
        var achou = False
        for c in self._colunas:
            if c.nome == nome:
                achou = True
                continue
            cols.append(c.copy())
        if not achou:
            raise erro_coluna(nome, self.nomes())
        return Self(cols^)

    def selecionar(self, nomes: List[String]) raises -> Self:
        if len(nomes) == 0:
            raise Error("selecionar exige pelo menos um nome")
        var escolhidas = List[Coluna]()
        for nome in nomes:
            escolhidas.append(self.pegar(nome))
        return Self(escolhidas^)

    def onde(self, var pred: Expr) -> Consulta:
        """Filtra. Devolve uma `Consulta` lazy — o plano so executa ao exibir.

        A ergonomia e eager, a execucao e lazy: `mostrar()`, `linhas()` e
        `soma()` materializam sozinhos.
        """
        var q = Consulta(self.lote())
        return q^.onde(pred^)

    def selecionar_lazy(self, nomes: List[String]) raises -> Consulta:
        """Projecao lazy. `selecionar()` continua eager por compatibilidade."""
        var q = Consulta(self.lote())
        return q^.selecionar(nomes)

    def agrupar(self, chaves: List[String]) raises -> Consulta:
        """Agrupa. Encadeie `.agregar([...])` em seguida."""
        var q = Consulta(self.lote())
        return q^.agrupar(chaves)

    def agregar_total(self, var agregacoes: List[Agregacao]) raises -> Consulta:
        """Reduz a tabela inteira a uma linha. Devolve `Consulta`."""
        var q = Consulta(self.lote())
        return q^.agregar_total(agregacoes^)

    def unir(
        self, outra: Tabela, por: List[String], tipo: String = "interno"
    ) raises -> Consulta:
        """Junta com outra tabela. Devolve `Consulta`."""
        var q = Consulta(self.lote())
        return q^.unir(outra, por, tipo)

    def ordenar(self, chaves: List[String], descendente: Bool = False) raises -> Consulta:
        """Ordena. Devolve `Consulta`."""
        var q = Consulta(self.lote())
        return q^.ordenar(chaves, descendente)

    def concatenar(self, outra: Tabela) raises -> Consulta:
        """Empilha outra tabela. Devolve `Consulta`."""
        var q = Consulta(self.lote())
        return q^.concatenar(outra)

    def remover_na(self, nomes: List[String] = List[String]()) raises -> Consulta:
        """Descarta linhas com ausente. Devolve `Consulta`."""
        var q = Consulta(self.lote())
        return q^.remover_na(nomes)

    def preencher_na(self, nome: String, var valor: Expr) raises -> Consulta:
        """Substitui ausentes de uma coluna. Devolve `Consulta`."""
        var q = Consulta(self.lote())
        return q^.preencher_na(nome, valor^)

    def contar_valores(self, nome: String) raises -> Tabela:
        """Quantas vezes cada valor aparece, do mais frequente ao menos."""
        var aggs = List[Agregacao]()
        aggs.append(contar())
        var chaves = List[String]()
        chaves.append(nome)
        var ordem = List[String]()
        ordem.append("contagem")
        return (
            Consulta(self.lote())
            .agrupar(chaves)
            .agregar(aggs^)
            .ordenar(ordem, True)
            .coletar()
        )

    def unicos(self, nome: String) raises -> Tabela:
        """Valores distintos da coluna, na ordem em que aparecem."""
        var chaves = List[String]()
        chaves.append(nome)
        var aggs = List[Agregacao]()
        aggs.append(contar())
        var so_chave = List[String]()
        so_chave.append(nome)
        return (
            Consulta(self.lote())
            .agrupar(chaves)
            .agregar(aggs^)
            .selecionar(so_chave)
            .coletar()
        )

    def resumo(self) raises -> Tabela:
        """Uma linha por coluna: tipo, contagens e estatisticas quando cabem.

        Colunas nao numericas trazem contagens; media, minimo e maximo ficam
        ausentes nelas, em vez de virar zero ou texto.
        """
        var nomes_col = List[String]()
        var tipos = List[String]()
        var linhas_col = List[Int64]()
        var validos = List[Int64]()
        var ausentes = List[Int64]()
        var medias = List[Float64]()
        var minimos = List[Float64]()
        var maximos = List[Float64]()
        var sem_stat = List[Bool]()

        for c in self._colunas:
            nomes_col.append(c.nome)
            tipos.append(c.tipo_nome())
            linhas_col.append(Int64(c.tamanho()))
            validos.append(Int64(c.contar_validos()))
            ausentes.append(Int64(c.contar_ausentes()))
            if c.dtype().eh_numerico() and c.contar_validos() > 0:
                medias.append(c.media())
                minimos.append(c.minimo())
                maximos.append(c.maximo())
                sem_stat.append(False)
            else:
                medias.append(0.0)
                minimos.append(0.0)
                maximos.append(0.0)
                sem_stat.append(True)

        var cols = List[Coluna]()
        cols.append(Coluna.de_textos("coluna", nomes_col^))
        cols.append(Coluna.de_textos("tipo", tipos^))
        cols.append(Coluna.de_inteiros("linhas", linhas_col^))
        cols.append(Coluna.de_inteiros("validos", validos^))
        cols.append(Coluna.de_inteiros("ausentes", ausentes^))
        cols.append(Coluna.de_reais("media", medias^, sem_stat.copy()))
        cols.append(Coluna.de_reais("minimo", minimos^, sem_stat.copy()))
        cols.append(Coluna.de_reais("maximo", maximos^, sem_stat^))
        return Tabela(cols^)

    def com_coluna(self, nome: String, var expr: Expr) -> Consulta:
        """Coluna derivada: atribui uma coluna calculada.

        Substitui a coluna se o nome ja existir. Devolve `Consulta`.
        """
        var q = Consulta(self.lote())
        return q^.com_coluna(nome, expr^)

    def consultar(self) -> Consulta:
        """Entra no pipeline lazy sem aplicar nenhuma etapa."""
        return Consulta(self.lote())

    def media(self, nome: String) raises -> Float64:
        return self.pegar(nome).media()

    def soma(self, nome: String) raises -> Float64:
        return self.pegar(nome).soma()

    def primeiras_linhas(self, n: Int) raises -> Self:
        """As primeiras `n` linhas, como Tabela."""
        var limite = n
        if limite > self.linhas():
            limite = self.linhas()
        var indices = List[Int](capacity=limite)
        for i in range(limite):
            indices.append(i)
        var cols = List[Coluna]()
        for c in self._colunas:
            cols.append(coletar_linhas(c, indices))
        return Self(cols^)

    def primeiras(self, n: Int = 5) raises:
        var limite = n
        if limite > self.linhas():
            limite = self.linhas()
        var cabecalho = String("#")
        for c in self._colunas:
            cabecalho += "\t" + c.nome
        print(cabecalho)
        for linha in range(limite):
            var texto = String(linha)
            for c in self._colunas:
                texto += "\t" + c.texto_em(linha)
            print(texto)

    def mostrar(self) raises:
        var s = self.shape()
        print("Tabela", s.linhas, "x", s.colunas)
        self.primeiras(self.linhas())
