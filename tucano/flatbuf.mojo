"""Construtor de FlatBuffers (M10).

O Arrow IPC guarda seus metadados em FlatBuffers, entao nao se escreve um
arquivo Arrow sem escrever um FlatBuffer primeiro.

O formato monta o buffer **de tras para frente**: cada objeto e escrito antes de
quem o referencia, e as referencias sao distancias ate o fim. Aqui isso vira uma
lista invertida — acrescentar ao fim da lista e o mesmo que inserir no comeco do
buffer — que so e virada no `finalizar()`.

Uma tabela e um deslocamento com sinal ate a **vtable**, que diz onde cada campo
esta. Campo com valor igual ao padrao nao ocupa espaco: some da vtable.

So metadados passam por aqui — esquema e descricao de lote, na casa dos
kilobytes. Os dados vao no corpo da mensagem, sem intermediario.
"""


struct ConstrutorFlat(Movable):
    var rev: List[UInt8]
    var campos: List[Int]
    var inicio_tabela: Int
    var vtables: List[Int]
    var em_tabela: Bool
    var alinhamento_minimo: Int

    def __init__(out self):
        self.rev = List[UInt8]()
        self.campos = List[Int]()
        self.inicio_tabela = 0
        self.vtables = List[Int]()
        self.em_tabela = False
        self.alinhamento_minimo = 1

    def deslocamento(self) -> Int:
        """Bytes ja escritos — a distancia do inicio atual ate o fim."""
        return len(self.rev)

    def _prepend(mut self, b: UInt8):
        self.rev.append(b)

    def preencher(mut self, n: Int):
        for _ in range(n):
            self._prepend(UInt8(0))

    def preparar(mut self, tamanho: Int, adicional: Int):
        """Alinha para que um objeto de `tamanho` caia em fronteira correta."""
        if tamanho > self.alinhamento_minimo:
            self.alinhamento_minimo = tamanho
        var total = self.deslocamento() + adicional
        var falta = ((~total) + 1) & (tamanho - 1)
        self.preencher(falta)

    def _escrever_i32_em(mut self, base: Int, valor: Int):
        """Corrige 4 bytes ja reservados. `base` e o deslocamento antes deles.

        A lista e invertida, entao o byte menos significativo — que no buffer
        final vem primeiro — fica na posicao mais alta das quatro.
        """
        var v = valor & 0xFFFFFFFF
        for i in range(4):
            self.rev[base + 3 - i] = UInt8((v >> (8 * i)) & 0xFF)

    def por_u8(mut self, v: UInt8):
        self.preparar(1, 0)
        self._prepend(v)

    def por_bool(mut self, v: Bool):
        self.por_u8(UInt8(1) if v else UInt8(0))

    def _por_le(mut self, valor: Int, n: Int):
        # little-endian no buffer final => ordem inversa na lista invertida
        for i in range(n - 1, -1, -1):
            self._prepend(UInt8((valor >> (8 * i)) & 0xFF))

    def por_i16(mut self, v: Int):
        self.preparar(2, 0)
        self._por_le(v & 0xFFFF, 2)

    def por_i32(mut self, v: Int):
        self.preparar(4, 0)
        self._por_le(v & 0xFFFFFFFF, 4)

    def por_i64(mut self, v: Int):
        self.preparar(8, 0)
        self._por_le(v, 8)

    def por_i32_cru(mut self, v: Int):
        """Sem alinhar — para escrever dentro de um vetor ja alinhado."""
        self._por_le(v & 0xFFFFFFFF, 4)

    def por_i64_cru(mut self, v: Int):
        self._por_le(v, 8)

    def por_referencia(mut self, alvo: Int) raises:
        """Referencia relativa (uoffset) para um objeto ja escrito."""
        self.preparar(4, 0)
        if alvo > self.deslocamento():
            raise Error("flatbuf: referencia para objeto ainda nao escrito")
        self._por_le(self.deslocamento() - alvo + 4, 4)

    # ------------------------------------------------------------ strings

    def texto(mut self, s: String) raises -> Int:
        var b = s.as_bytes()
        # o alinhamento leva em conta o terminador, que faz parte do bloco
        self.preparar(4, len(b) + 1)
        self._prepend(UInt8(0))
        for i in range(len(b) - 1, -1, -1):
            self._prepend(b[i])
        self._por_le(len(b), 4)
        return self.deslocamento()

    def bytes_crus(mut self, b: List[UInt8]) raises -> Int:
        self.preparar(4, len(b))
        for i in range(len(b) - 1, -1, -1):
            self._prepend(b[i])
        self._por_le(len(b), 4)
        return self.deslocamento()

    # ------------------------------------------------------------- vetores

    def iniciar_vetor(mut self, tamanho_elemento: Int, n: Int, alinhamento: Int):
        self.preparar(4, tamanho_elemento * n)
        self.preparar(alinhamento, tamanho_elemento * n)

    def terminar_vetor(mut self, n: Int) -> Int:
        self._por_le(n, 4)
        return self.deslocamento()

    def vetor_de_referencias(mut self, alvos: List[Int]) raises -> Int:
        self.iniciar_vetor(4, len(alvos), 4)
        for i in range(len(alvos) - 1, -1, -1):
            self.preparar(4, 0)
            if alvos[i] > self.deslocamento():
                raise Error("flatbuf: referencia invalida no vetor")
            self._por_le(self.deslocamento() - alvos[i] + 4, 4)
        return self.terminar_vetor(len(alvos))

    # -------------------------------------------------------------- tabelas

    def iniciar_tabela(mut self) raises:
        if self.em_tabela:
            raise Error("flatbuf: tabela aninhada sem fechar a anterior")
        self.em_tabela = True
        self.campos = List[Int]()
        self.inicio_tabela = self.deslocamento()

    def _marcar(mut self, slot: Int):
        while len(self.campos) <= slot:
            self.campos.append(0)
        self.campos[slot] = self.deslocamento()

    def campo_i8(mut self, slot: Int, valor: Int, padrao: Int):
        if valor == padrao:
            return
        self.por_u8(UInt8(valor & 0xFF))
        self._marcar(slot)

    def campo_bool(mut self, slot: Int, valor: Bool, padrao: Bool):
        if valor == padrao:
            return
        self.por_bool(valor)
        self._marcar(slot)

    def campo_i16(mut self, slot: Int, valor: Int, padrao: Int):
        if valor == padrao:
            return
        self.por_i16(valor)
        self._marcar(slot)

    def campo_i32(mut self, slot: Int, valor: Int, padrao: Int):
        if valor == padrao:
            return
        self.por_i32(valor)
        self._marcar(slot)

    def campo_i64(mut self, slot: Int, valor: Int, padrao: Int):
        if valor == padrao:
            return
        self.por_i64(valor)
        self._marcar(slot)

    def campo_referencia(mut self, slot: Int, alvo: Int) raises:
        if alvo == 0:
            return
        self.por_referencia(alvo)
        self._marcar(slot)

    def terminar_tabela(mut self) raises -> Int:
        """Escreve a vtable e devolve o deslocamento da tabela.

        O `soffset` para a vtable mora **no inicio da tabela**, entao e reservado
        antes de escrever a vtable e corrigido depois. Escreve-lo no fim poria os
        quatro bytes antes da vtable no buffer final, e o leitor do outro lado
        acharia lixo onde espera a tabela.
        """
        self.preparar(4, 0)
        var base = self.deslocamento()
        self.preencher(4)  # reserva o soffset
        var fim_objeto = self.deslocamento()

        # vtable: [tamanho da vtable][tamanho da tabela][offset de cada campo]
        var n = len(self.campos)
        while n > 0 and self.campos[n - 1] == 0:
            n -= 1
        for i in range(n - 1, -1, -1):
            var deslocamento_campo = 0
            if self.campos[i] != 0:
                deslocamento_campo = fim_objeto - self.campos[i]
            self.por_i16(deslocamento_campo)
        self.por_i16(fim_objeto - self.inicio_tabela)
        self.por_i16((n + 2) * 2)

        var inicio_vtable = self.deslocamento()
        self._escrever_i32_em(base, inicio_vtable - fim_objeto)
        self.em_tabela = False
        return fim_objeto

    # ------------------------------------------------------------- fecho

    def finalizar(mut self, raiz: Int) raises -> List[UInt8]:
        self.preparar(self.alinhamento_minimo, 4)
        self.por_referencia(raiz)
        var out = List[UInt8](capacity=len(self.rev))
        for i in range(len(self.rev) - 1, -1, -1):
            out.append(self.rev[i])
        return out^


# ------------------------------------------------------------------ leitura
#
# Ler e mais simples que escrever: e so seguir deslocamentos. A tabela comeca
# com um `soffset` **subtraido** da propria posicao para achar a vtable; a vtable
# diz, por slot, a que distancia do inicio da tabela cada campo esta. Slot com
# deslocamento zero significa campo ausente — e ausente quer dizer "use o
# padrao", nao "erro".


def ler_u8(b: List[UInt8], pos: Int) -> Int:
    return Int(b[pos])


def ler_u16(b: List[UInt8], pos: Int) -> Int:
    return Int(b[pos]) | (Int(b[pos + 1]) << 8)


def ler_i16(b: List[UInt8], pos: Int) -> Int:
    var v = ler_u16(b, pos)
    if v >= 0x8000:
        v -= 0x10000
    return v


def ler_u32(b: List[UInt8], pos: Int) -> Int:
    var v = 0
    for i in range(4):
        v |= Int(b[pos + i]) << (8 * i)
    return v


def ler_i32(b: List[UInt8], pos: Int) -> Int:
    var v = ler_u32(b, pos)
    if v >= 0x80000000:
        v -= 0x100000000
    return v


def ler_i64(b: List[UInt8], pos: Int) -> Int:
    var v = 0
    for i in range(8):
        v |= Int(b[pos + i]) << (8 * i)
    return v


def raiz_flat(b: List[UInt8], base: Int) -> Int:
    """Posicao da tabela raiz."""
    return base + ler_u32(b, base)


def campo_flat(b: List[UInt8], tabela: Int, slot: Int) -> Int:
    """Posicao do campo, ou -1 se ausente."""
    var vtable = tabela - ler_i32(b, tabela)
    var tamanho_vtable = ler_u16(b, vtable)
    var pos_slot = 4 + slot * 2
    if pos_slot >= tamanho_vtable:
        return -1
    var deslocamento = ler_u16(b, vtable + pos_slot)
    if deslocamento == 0:
        return -1
    return tabela + deslocamento


def referencia_flat(b: List[UInt8], pos: Int) -> Int:
    """Segue um uoffset relativo."""
    return pos + ler_u32(b, pos)


def texto_flat(b: List[UInt8], pos: Int) raises -> String:
    var alvo = referencia_flat(b, pos)
    var n = ler_u32(b, alvo)
    if n == 0:
        return ""
    return String(from_utf8=Span(b)[alvo + 4 : alvo + 4 + n])


def tamanho_vetor_flat(b: List[UInt8], pos: Int) -> Int:
    return ler_u32(b, referencia_flat(b, pos))


def inicio_vetor_flat(b: List[UInt8], pos: Int) -> Int:
    return referencia_flat(b, pos) + 4
