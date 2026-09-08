"""ZIP de leitura (PKZIP). So o que o .xlsx precisa.

O Office Open XML e um ZIP com XML dentro. Daqui sai o membro pelo caminho
(`xl/worksheets/sheet1.xml`); o parser da planilha mora em `xlsx.mojo`.

Metodos 0 (store) e 8 (DEFLATE cru). ZIP64, criptografia e disco multiplo
sao recusados com explicacao.
"""

from .deflate import inflar


def _u16(b: List[UInt8], i: Int) raises -> Int:
    if i + 2 > len(b):
        raise Error("zip: cabecalho truncado")
    return Int(b[i]) | (Int(b[i + 1]) << 8)


def _u32(b: List[UInt8], i: Int) raises -> Int:
    if i + 4 > len(b):
        raise Error("zip: cabecalho truncado")
    return (
        Int(b[i])
        | (Int(b[i + 1]) << 8)
        | (Int(b[i + 2]) << 16)
        | (Int(b[i + 3]) << 24)
    )


def _texto(b: List[UInt8], i: Int, n: Int) raises -> String:
    if n < 0 or i + n > len(b):
        raise Error("zip: nome truncado")
    if n == 0:
        return ""
    return String(from_utf8=Span(b)[i : i + n])


def _eocd(b: List[UInt8]) raises -> Int:
    """Posicao da assinatura PK\\x05\\x06. Comentario no maximo 64 KiB."""
    var n = len(b)
    if n < 22:
        raise Error("zip: arquivo pequeno demais")
    var min_pos = n - 22 - 65535
    if min_pos < 0:
        min_pos = 0
    var i = n - 22
    while i >= min_pos:
        if (
            b[i] == UInt8(0x50)
            and b[i + 1] == UInt8(0x4B)
            and b[i + 2] == UInt8(5)
            and b[i + 3] == UInt8(6)
        ):
            return i
        i -= 1
    raise Error("zip: diretorio central nao encontrado")


@fieldwise_init
struct MembroZip(Copyable, Movable):
    var nome: String
    var metodo: Int
    var comprimido: Int
    var original: Int
    var local: Int
    var flags: Int


def _ler_central(b: List[UInt8]) raises -> List[MembroZip]:
    var e = _eocd(b)
    var discos = _u16(b, e + 4)
    var total = _u16(b, e + 10)
    var tam = _u32(b, e + 12)
    var off = _u32(b, e + 16)
    if discos != 0:
        raise Error("zip: arquivo em varios discos nao e suportado")
    if off == 0xFFFFFFFF or tam == 0xFFFFFFFF or total == 0xFFFF:
        raise Error("zip: ZIP64 ainda nao e suportado")
    if off + tam > len(b):
        raise Error("zip: diretorio central fora do arquivo")

    var out = List[MembroZip]()
    var pos = off
    for _ in range(total):
        if _u32(b, pos) != 0x02014B50:
            raise Error("zip: entrada do diretorio central invalida")
        var flags = _u16(b, pos + 8)
        var metodo = _u16(b, pos + 10)
        var csize = _u32(b, pos + 20)
        var usize = _u32(b, pos + 24)
        var nlen = _u16(b, pos + 28)
        var elen = _u16(b, pos + 30)
        var clen = _u16(b, pos + 32)
        var local = _u32(b, pos + 42)
        var nome = _texto(b, pos + 46, nlen)
        pos = pos + 46 + nlen + elen + clen
        out.append(MembroZip(nome, metodo, csize, usize, local, flags))
    return out^


struct Zip(Movable):
    """Arquivo ZIP em memoria, para extrair membros sem recarregar."""

    var bytes: List[UInt8]
    var membros: List[MembroZip]

    def __init__(out self, var bytes: List[UInt8]) raises:
        self.membros = _ler_central(bytes)
        self.bytes = bytes^

    def tem(self, caminho: String) -> Bool:
        for m in self.membros:
            if m.nome == caminho:
                return True
        return False

    def obter(self, caminho: String) raises -> List[UInt8]:
        for m in self.membros:
            if m.nome != caminho:
                continue
            if (m.flags & 1) != 0:
                raise Error("zip: '" + caminho + "' esta cifrado")
            var pos = m.local
            if _u32(self.bytes, pos) != 0x04034B50:
                raise Error("zip: cabecalho local invalido em '" + m.nome + "'")
            var nlen = _u16(self.bytes, pos + 26)
            var elen = _u16(self.bytes, pos + 28)
            var ini = pos + 30 + nlen + elen
            var fim = ini + m.comprimido
            if fim > len(self.bytes):
                raise Error("zip: dados de '" + caminho + "' truncados")
            var bruto = List[UInt8]()
            for i in range(ini, fim):
                bruto.append(self.bytes[i])
            if m.metodo == 0:
                return bruto^
            if m.metodo == 8:
                var out = inflar(bruto^)
                if m.original > 0 and len(out) != m.original:
                    raise Error(
                        "zip: '" + caminho + "' descomprimiu "
                        + String(len(out)) + " bytes, esperado "
                        + String(m.original)
                    )
                return out^
            raise Error(
                "zip: compressao " + String(m.metodo)
                + " em '" + caminho + "' nao suportada (use store ou deflate)"
            )
        raise Error("zip: membro '" + caminho + "' nao existe")
