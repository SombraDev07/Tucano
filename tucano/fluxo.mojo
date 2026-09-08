"""Execucao em fluxo (M9).

Agregar nao exige ter tudo em memoria: exige carregar o **estado dos grupos**,
que e pequeno, e passar os dados por ele uma fatia de cada vez.

    fatia -> filtro / coluna derivada -> estado dos grupos
                                              |
                                        (a fatia e liberada)

O que atravessa fatias precisa ser **combinavel**. Soma de somas e soma; minimo
de minimos e minimo; media nao combina, mas soma e contagem combinam, e a divisao
fica para o fim. `distintos` nao combina sem guardar todos os valores vistos — e
por isso e recusado no fluxo, em vez de fingir que cabe.

Ordenacao e juncao tambem nao fluem: as duas precisam do conjunto inteiro. O
plano e recusado com essa explicacao, nao executado pela metade.
"""

from std.collections import Dict
from .coluna import Coluna
from .dtype import DType
from .schema import Campo
from .agregacao import Agregacao, TipoAgregacao
from .plano import Etapa, TipoEtapa
from .executor import (
    n_linhas,
    posicao_no_lote,
    esquema_do_lote,
    tipo_da_agregacao,
    extrair_coluna,
    _chave_texto,
)


def plano_flui(etapas: List[Etapa]) raises -> String:
    """Devolve "" se o plano flui, ou a razao pela qual nao flui."""
    var vistos_agregacao = 0
    for i in range(len(etapas)):
        var t = etapas[i].tipo
        if t == TipoEtapa.ORDENACAO:
            return "ordenacao precisa do conjunto inteiro"
        if t == TipoEtapa.JUNCAO:
            return "juncao precisa do conjunto inteiro"
        if t == TipoEtapa.CONCATENACAO:
            return "concatenacao precisa do conjunto inteiro"
        if t == TipoEtapa.AGREGACAO:
            vistos_agregacao += 1
            if i != len(etapas) - 1:
                return "a agregacao precisa ser a ultima etapa"
    if vistos_agregacao == 0:
        return "o plano precisa terminar em uma agregacao"
    if vistos_agregacao > 1:
        return "mais de uma agregacao no plano"
    for a in etapas[len(etapas) - 1].agregacoes:
        if a.tipo == TipoAgregacao.DISTINTOS:
            return (
                "distintos(" + a.coluna + ") nao combina entre fatias sem guardar"
                + " todos os valores vistos"
            )
    return ""


struct EstadoAgregacao(Movable):
    """Estado dos grupos, o unico que sobrevive entre fatias.

    Ocupa memoria proporcional ao **numero de grupos**, nao ao de linhas.
    """

    var chaves: List[String]
    var agregacoes: List[Agregacao]
    var mapa: Dict[String, Int]
    var tipos_chave: List[Int]
    var chave_reais: List[List[Float64]]
    var chave_textos: List[List[String]]
    var chave_na: List[List[Bool]]
    var acc: List[List[Float64]]
    var acc_textos: List[List[String]]
    var vistos: List[List[Int]]
    var linhas: List[Int]
    var tipos_saida: List[Int]
    var pico_linhas: Int
    var fatias: Int

    def __init__(
        out self,
        chaves: List[String],
        agregacoes: List[Agregacao],
        esquema: List[Campo],
    ) raises:
        self.chaves = chaves.copy()
        self.agregacoes = agregacoes.copy()
        self.mapa = Dict[String, Int]()
        self.tipos_chave = List[Int]()
        self.chave_reais = List[List[Float64]]()
        self.chave_textos = List[List[String]]()
        self.chave_na = List[List[Bool]]()
        self.acc = List[List[Float64]]()
        self.acc_textos = List[List[String]]()
        self.vistos = List[List[Int]]()
        self.linhas = List[Int]()
        self.tipos_saida = List[Int]()
        self.pico_linhas = 0
        self.fatias = 0

        for c in chaves:
            var achou = -1
            for campo in esquema:
                if campo.nome == c:
                    achou = campo.dtype.codigo
            if achou < 0:
                raise Error("fluxo: chave inexistente no esquema: " + c)
            self.tipos_chave.append(achou)
            self.chave_reais.append(List[Float64]())
            self.chave_textos.append(List[String]())
            self.chave_na.append(List[Bool]())

        for a in agregacoes:
            self.tipos_saida.append(tipo_da_agregacao(a, esquema))
            self.acc.append(List[Float64]())
            self.acc_textos.append(List[String]())
            self.vistos.append(List[Int]())

    def n_grupos(self) -> Int:
        return len(self.linhas)

    def absorver(mut self, cols: List[Coluna]) raises:
        """Passa uma fatia pelo estado. A fatia pode ser liberada depois."""
        var n = n_linhas(cols)
        if n == 0:
            return
        self.fatias += 1
        if n > self.pico_linhas:
            self.pico_linhas = n

        var pos_chave = List[Int]()
        for c in self.chaves:
            pos_chave.append(posicao_no_lote(cols, c))

        # identifica os grupos desta fatia
        var ids = List[Int](capacity=n)
        for i in range(n):
            var composta = String("")
            for p in pos_chave:
                composta += _chave_texto(cols[p], i) + "\x01"
            if composta in self.mapa:
                ids.append(self.mapa[composta])
            else:
                var novo = len(self.linhas)
                self.mapa[composta] = novo
                ids.append(novo)
                self.linhas.append(0)
                for k in range(len(pos_chave)):
                    ref col = cols[pos_chave[k]]
                    self.chave_na[k].append(col.eh_ausente(i))
                    if col.tipo == DType.TEXTO:
                        self.chave_textos[k].append(
                            "" if col.eh_ausente(i) else col.texto_bruto(i)
                        )
                        self.chave_reais[k].append(0.0)
                    else:
                        self.chave_textos[k].append("")
                        self.chave_reais[k].append(
                            0.0 if col.eh_ausente(i) else col._como_real(i)
                        )
                for j in range(len(self.agregacoes)):
                    self.acc[j].append(0.0)
                    self.acc_textos[j].append("")
                    self.vistos[j].append(0)

        for i in range(n):
            self.linhas[ids[i]] += 1

        for j in range(len(self.agregacoes)):
            self._absorver_agregacao(cols, j, ids, n)

    def _absorver_agregacao(
        mut self, cols: List[Coluna], j: Int, ids: List[Int], n: Int
    ) raises:
        ref a = self.agregacoes[j]
        if a.tipo == TipoAgregacao.CONTAGEM and a.coluna == "":
            return  # ja contado em `linhas`

        var pos = posicao_no_lote(cols, a.coluna)
        ref col = cols[pos]

        if col.tipo == DType.TEXTO:
            for i in range(n):
                if col.eh_ausente(i):
                    continue
                var g = ids[i]
                var v = col.texto_bruto(i)
                if a.tipo == TipoAgregacao.CONTAGEM:
                    self.vistos[j][g] += 1
                    continue
                if self.vistos[j][g] == 0:
                    self.acc_textos[j][g] = v
                elif a.tipo == TipoAgregacao.MINIMO:
                    if v < self.acc_textos[j][g]:
                        self.acc_textos[j][g] = v
                elif a.tipo == TipoAgregacao.MAXIMO:
                    if v > self.acc_textos[j][g]:
                        self.acc_textos[j][g] = v
                # PRIMEIRO mantem o primeiro visto
                self.vistos[j][g] += 1
            return

        var v = extrair_coluna(cols, a.coluna)
        for i in range(n):
            if v.na[i] != 0:
                continue
            var g = ids[i]
            var x = v.reais[i]
            if self.vistos[j][g] == 0:
                self.acc[j][g] = x
            elif a.tipo == TipoAgregacao.SOMA or a.tipo == TipoAgregacao.MEDIA:
                self.acc[j][g] += x
            elif a.tipo == TipoAgregacao.MINIMO:
                if x < self.acc[j][g]:
                    self.acc[j][g] = x
            elif a.tipo == TipoAgregacao.MAXIMO:
                if x > self.acc[j][g]:
                    self.acc[j][g] = x
            self.vistos[j][g] += 1

    def finalizar(self) raises -> List[Coluna]:
        var g = self.n_grupos()
        var saida = List[Coluna]()

        for k in range(len(self.chaves)):
            var tipo = self.tipos_chave[k]
            var aus = self.chave_na[k].copy()
            if tipo == DType.TEXTO:
                saida.append(
                    Coluna.de_textos(self.chaves[k], self.chave_textos[k].copy(), aus^)
                )
            elif tipo == DType.REAL:
                saida.append(
                    Coluna.de_reais(self.chaves[k], self.chave_reais[k].copy(), aus^)
                )
            elif tipo == DType.LOGICO:
                var vals = List[Bool](capacity=g)
                for i in range(g):
                    vals.append(self.chave_reais[k][i] != 0.0)
                saida.append(Coluna.de_logicos(self.chaves[k], vals^, aus^))
            else:
                var vals = List[Int64](capacity=g)
                for i in range(g):
                    vals.append(Int64(Int(self.chave_reais[k][i])))
                if tipo == DType.DATA:
                    saida.append(Coluna.de_datas(self.chaves[k], vals^, aus^))
                elif tipo == DType.DATAHORA:
                    saida.append(Coluna.de_datahoras(self.chaves[k], vals^, aus^))
                else:
                    saida.append(Coluna.de_inteiros(self.chaves[k], vals^, aus^))

        for j in range(len(self.agregacoes)):
            ref a = self.agregacoes[j]
            var nome = a.nome_saida()
            var tipo = self.tipos_saida[j]

            if a.tipo == TipoAgregacao.CONTAGEM:
                var vals = List[Int64](capacity=g)
                for i in range(g):
                    if a.coluna == "":
                        vals.append(Int64(self.linhas[i]))
                    else:
                        vals.append(Int64(self.vistos[j][i]))
                saida.append(Coluna.de_inteiros(nome, vals^, List[Bool]()))
                continue

            if tipo == DType.TEXTO:
                var vals = List[String](capacity=g)
                var aus = List[Bool](capacity=g)
                for i in range(g):
                    vals.append(self.acc_textos[j][i])
                    aus.append(self.vistos[j][i] == 0)
                saida.append(Coluna.de_textos(nome, vals^, aus^))
                continue

            var reais = List[Float64](capacity=g)
            var aus = List[Bool](capacity=g)
            for i in range(g):
                var sem = self.vistos[j][i] == 0
                aus.append(sem)
                if sem:
                    reais.append(0.0)
                elif a.tipo == TipoAgregacao.MEDIA:
                    reais.append(self.acc[j][i] / Float64(self.vistos[j][i]))
                else:
                    reais.append(self.acc[j][i])

            if tipo == DType.INTEIRO or tipo == DType.DATA or tipo == DType.DATAHORA:
                var vals = List[Int64](capacity=g)
                for i in range(g):
                    vals.append(Int64(Int(reais[i])))
                if tipo == DType.DATA:
                    saida.append(Coluna.de_datas(nome, vals^, aus^))
                elif tipo == DType.DATAHORA:
                    saida.append(Coluna.de_datahoras(nome, vals^, aus^))
                else:
                    saida.append(Coluna.de_inteiros(nome, vals^, aus^))
            else:
                saida.append(Coluna.de_reais(nome, reais^, aus^))

        return saida^
