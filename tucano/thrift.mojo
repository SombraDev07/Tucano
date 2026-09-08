"""Protocolo Thrift compact — leitura (M5).

O Parquet guarda todos os metadados (esquema, row groups, cabecalhos de pagina)
codificados neste protocolo. Sem ele nao se le um byte de dado.

O que o formato faz, em resumo:

- inteiros sao **varint** (ULEB128); com sinal, **zigzag** antes;
- campo de struct e um byte: nibble alto = delta do id em relacao ao campo
  anterior, nibble baixo = tipo. Delta 0 significa id longo, num zigzag varint
  a seguir. Tipo 0 encerra a struct;
- booleano nao ocupa byte de valor: o proprio tipo do campo diz se e verdadeiro
  ou falso;
- lista e um byte `(tamanho << 4) | tipo`, com tamanho em varint a seguir quando
  passa de 14.

`pular_campo` e o que torna o leitor robusto: os metadados do Parquet tem dezenas
de campos opcionais que nao interessam, e todo campo desconhecido precisa ser
atravessado sem interpretar.
"""

from std.memory import bitcast


struct TTipo:
    comptime STOP = 0
    comptime BOOL_TRUE = 1
    comptime BOOL_FALSE = 2
    comptime BYTE = 3
    comptime I16 = 4
    comptime I32 = 5
    comptime I64 = 6
    comptime DOUBLE = 7
    comptime BINARIO = 8
    comptime LISTA = 9
    comptime CONJUNTO = 10
    comptime MAPA = 11
    comptime STRUCT = 12


@fieldwise_init
struct CampoThrift(Copyable, Movable, ImplicitlyCopyable):
    """Cabecalho de campo: tipo e id. Tipo `STOP` encerra a struct."""

    var tipo: Int
    var id: Int


@fieldwise_init
struct ListaThrift(Copyable, Movable, ImplicitlyCopyable):
    var tipo: Int
    var tamanho: Int


struct LeitorThrift(Copyable, Movable):
    """Cursor sobre um buffer de bytes.

    Os bytes ficam fora do leitor, passados a cada chamada: assim nao ha copia
    do arquivo inteiro nem amarra de origem.
    """

    var pos: Int
    var ultimo_id: Int
    var pilha: List[Int]

    def __init__(out self, pos: Int = 0):
        self.pos = pos
        self.ultimo_id = 0
        self.pilha = List[Int]()

    def byte(mut self, bytes: List[UInt8]) raises -> UInt8:
        if self.pos >= len(bytes):
            raise Error("thrift: fim inesperado do buffer")
        var b = bytes[self.pos]
        self.pos += 1
        return b

    def varint(mut self, bytes: List[UInt8]) raises -> Int:
        var resultado = 0
        var deslocamento = 0
        while True:
            var b = Int(self.byte(bytes))
            resultado |= (b & 0x7F) << deslocamento
            if b & 0x80 == 0:
                break
            deslocamento += 7
            if deslocamento > 63:
                raise Error("thrift: varint longo demais")
        return resultado

    def zigzag(mut self, bytes: List[UInt8]) raises -> Int:
        var n = self.varint(bytes)
        return (n >> 1) ^ -(n & 1)

    def duplo(mut self, bytes: List[UInt8]) raises -> Float64:
        """DOUBLE vai em 8 bytes little-endian, sem varint."""
        var bits = 0
        for i in range(8):
            bits |= Int(self.byte(bytes)) << (8 * i)
        return bitcast[DType.float64](Int64(bits))

    def faixa_binaria(mut self, bytes: List[UInt8]) raises -> ListaThrift:
        """Consome um binario e devolve (inicio, tamanho) sem copiar."""
        var n = self.varint(bytes)
        var inicio = self.pos
        if inicio + n > len(bytes):
            raise Error("thrift: binario ultrapassa o buffer")
        self.pos += n
        return ListaThrift(inicio, n)

    def texto(mut self, bytes: List[UInt8]) raises -> String:
        var faixa = self.faixa_binaria(bytes)
        if faixa.tamanho == 0:
            return ""
        return String(
            from_utf8=Span(bytes)[faixa.tipo : faixa.tipo + faixa.tamanho]
        )

    # ------------------------------------------------------------ structs

    def entrar(mut self):
        """Abre uma struct aninhada: o delta de id recomeca do zero."""
        self.pilha.append(self.ultimo_id)
        self.ultimo_id = 0

    def sair(mut self) raises:
        if len(self.pilha) == 0:
            raise Error("thrift: saida de struct sem entrada")
        self.ultimo_id = self.pilha.pop()

    def campo(mut self, bytes: List[UInt8]) raises -> CampoThrift:
        var cabecalho = Int(self.byte(bytes))
        var tipo = cabecalho & 0x0F
        if tipo == TTipo.STOP:
            return CampoThrift(TTipo.STOP, 0)
        var delta = (cabecalho & 0xF0) >> 4
        var id: Int
        if delta == 0:
            id = self.zigzag(bytes)
        else:
            id = self.ultimo_id + delta
        self.ultimo_id = id
        return CampoThrift(tipo, id)

    def lista(mut self, bytes: List[UInt8]) raises -> ListaThrift:
        var cabecalho = Int(self.byte(bytes))
        var tipo = cabecalho & 0x0F
        var tamanho = (cabecalho & 0xF0) >> 4
        if tamanho == 15:
            tamanho = self.varint(bytes)
        return ListaThrift(tipo, tamanho)

    # ---------------------------------------------------- pular o que sobra

    def pular_valor(mut self, bytes: List[UInt8], tipo: Int) raises:
        """Atravessa um valor sem interpretar. Recursivo em lista/mapa/struct."""
        if tipo == TTipo.BOOL_TRUE or tipo == TTipo.BOOL_FALSE:
            return
        if tipo == TTipo.BYTE:
            _ = self.byte(bytes)
            return
        if tipo == TTipo.I16 or tipo == TTipo.I32 or tipo == TTipo.I64:
            _ = self.zigzag(bytes)
            return
        if tipo == TTipo.DOUBLE:
            self.pos += 8
            return
        if tipo == TTipo.BINARIO:
            _ = self.faixa_binaria(bytes)
            return
        if tipo == TTipo.LISTA or tipo == TTipo.CONJUNTO:
            var l = self.lista(bytes)
            for _ in range(l.tamanho):
                self.pular_valor(bytes, l.tipo)
            return
        if tipo == TTipo.MAPA:
            var n = self.varint(bytes)
            if n > 0:
                var tipos = Int(self.byte(bytes))
                var tipo_chave = (tipos & 0xF0) >> 4
                var tipo_valor = tipos & 0x0F
                for _ in range(n):
                    self.pular_valor(bytes, tipo_chave)
                    self.pular_valor(bytes, tipo_valor)
            return
        if tipo == TTipo.STRUCT:
            self.pular_struct(bytes)
            return
        raise Error("thrift: tipo desconhecido " + String(tipo))

    def pular_struct(mut self, bytes: List[UInt8]) raises:
        self.entrar()
        while True:
            var c = self.campo(bytes)
            if c.tipo == TTipo.STOP:
                break
            self.pular_valor(bytes, c.tipo)
        self.sair()


# ------------------------------------------------------------------ escrita


struct EscritorThrift(Copyable, Movable):
    """Serializa no protocolo compact.

    Espelha o leitor: id de campo por delta, inteiros em zigzag varint, booleano
    codificado no proprio tipo do campo.
    """

    var bytes: List[UInt8]
    var ultimo_id: Int
    var pilha: List[Int]

    def __init__(out self):
        self.bytes = List[UInt8]()
        self.ultimo_id = 0
        self.pilha = List[Int]()

    def byte(mut self, b: UInt8):
        self.bytes.append(b)

    def varint(mut self, valor: Int):
        var v = valor
        while True:
            var b = v & 0x7F
            v >>= 7
            if v != 0:
                self.bytes.append(UInt8(b | 0x80))
            else:
                self.bytes.append(UInt8(b))
                break

    def zigzag(mut self, valor: Int):
        self.varint((valor << 1) ^ (valor >> 63))

    def binario(mut self, valor: String):
        var b = valor.as_bytes()
        self.varint(len(b))
        for x in b:
            self.bytes.append(x)

    def entrar(mut self):
        self.pilha.append(self.ultimo_id)
        self.ultimo_id = 0

    def sair(mut self) raises:
        """Fecha a struct com o marcador STOP."""
        self.bytes.append(UInt8(TTipo.STOP))
        if len(self.pilha) == 0:
            raise Error("thrift: saida de struct sem entrada")
        self.ultimo_id = self.pilha.pop()

    def campo(mut self, id: Int, tipo: Int):
        var delta = id - self.ultimo_id
        if delta > 0 and delta <= 15:
            self.bytes.append(UInt8((delta << 4) | tipo))
        else:
            self.bytes.append(UInt8(tipo))
            self.zigzag(id)
        self.ultimo_id = id

    def campo_i32(mut self, id: Int, valor: Int):
        self.campo(id, TTipo.I32)
        self.zigzag(valor)

    def campo_i64(mut self, id: Int, valor: Int):
        self.campo(id, TTipo.I64)
        self.zigzag(valor)

    def campo_bool(mut self, id: Int, valor: Bool):
        if valor:
            self.campo(id, TTipo.BOOL_TRUE)
        else:
            self.campo(id, TTipo.BOOL_FALSE)

    def campo_texto(mut self, id: Int, valor: String):
        self.campo(id, TTipo.BINARIO)
        self.binario(valor)

    def campo_bytes(mut self, id: Int, dados: List[UInt8]):
        """Binario cru — min/max do Parquet e PLAIN, nao UTF-8."""
        self.campo(id, TTipo.BINARIO)
        self.varint(len(dados))
        for x in dados:
            self.bytes.append(x)

    def campo_struct(mut self, id: Int):
        self.campo(id, TTipo.STRUCT)
        self.entrar()

    def campo_lista(mut self, id: Int, tipo_elemento: Int, tamanho: Int):
        self.campo(id, TTipo.LISTA)
        self.cabecalho_lista(tipo_elemento, tamanho)

    def finalizar(self) -> List[UInt8]:
        """Bytes acumulados.

        Copia: o Mojo 1.0 nao deixa mover um campo para fora de uma struct que
        ainda precisa ser destruida. O custo e irrelevante — o escritor so serve
        para metadados, na casa dos kilobytes, nunca para dados de coluna.
        """
        return self.bytes.copy()

    def cabecalho_lista(mut self, tipo_elemento: Int, tamanho: Int):
        if tamanho < 15:
            self.bytes.append(UInt8((tamanho << 4) | tipo_elemento))
        else:
            self.bytes.append(UInt8(0xF0 | tipo_elemento))
            self.varint(tamanho)
