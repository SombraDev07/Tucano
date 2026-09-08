"""Servidor HTTP minimo sobre a libc (M7).

O Mojo 1.0 nao traz sockets no stdlib, mas traz `external_call`. Isto e o
suficiente para o painel: `socket`, `bind`, `listen`, `accept`, `read`, `write`,
`close`.

Deliberadamente pequeno e **sequencial** — atende uma requisicao por vez. Um
painel local nao precisa de mais, e fingir concorrencia aqui seria construir
sobre o runtime assincrono que o M4 ja mostrou nao estar pronto para isso.
"""

from std.ffi import external_call
from .json import escapar

comptime _AF_INET = Int32(2)
comptime _SOCK_STREAM = Int32(1)
comptime _SOL_SOCKET = Int32(1)
comptime _SO_REUSEADDR = Int32(2)
comptime _TAM_BUFFER = 16384


@fieldwise_init
struct Requisicao(Copyable, Movable):
    var metodo: String
    var caminho: String
    var consulta: String


def _hex_valor(b: UInt8) -> Int:
    if b >= UInt8(48) and b <= UInt8(57):
        return Int(b) - 48
    if b >= UInt8(97) and b <= UInt8(102):
        return Int(b) - 87
    if b >= UInt8(65) and b <= UInt8(70):
        return Int(b) - 55
    return -1


def decodificar_url(texto: String) raises -> String:
    """Desfaz `%XX` e `+`."""
    var b = texto.as_bytes()
    var out = List[UInt8]()
    var i = 0
    while i < len(b):
        if b[i] == UInt8(37) and i + 2 < len(b):
            var alto = _hex_valor(b[i + 1])
            var baixo = _hex_valor(b[i + 2])
            if alto >= 0 and baixo >= 0:
                out.append(UInt8(alto * 16 + baixo))
                i += 3
                continue
        if b[i] == UInt8(43):
            out.append(UInt8(32))
        else:
            out.append(b[i])
        i += 1
    return String(from_utf8=Span(out))


def parametros(consulta: String) raises -> List[String]:
    """`a=1&b=2` -> [a, 1, b, 2]. Lista plana: chave, valor, chave, valor."""
    var out = List[String]()
    if consulta == "":
        return out^
    for par in consulta.split("&"):
        var texto = String(par)
        if texto == "":
            continue
        var pos = texto.find("=")
        if pos < 0:
            out.append(decodificar_url(texto))
            out.append("")
        else:
            out.append(decodificar_url(String(texto[byte=0:pos])))
            out.append(
                decodificar_url(String(texto[byte=pos + 1 : texto.byte_length()]))
            )
    return out^


struct Servidor(Movable):
    var fd: Int32
    var porta: Int

    def __init__(out self, porta: Int) raises:
        self.porta = porta
        self.fd = external_call["socket", Int32](_AF_INET, _SOCK_STREAM, Int32(0))
        if self.fd < 0:
            raise Error("http: nao foi possivel criar o socket")

        var um = List[Int32]()
        um.append(Int32(1))
        _ = external_call["setsockopt", Int32](
            self.fd, _SOL_SOCKET, _SO_REUSEADDR, um.unsafe_ptr(), Int32(4)
        )

        # struct sockaddr_in: familia (u16), porta (u16 big-endian), ip (u32), zeros
        var endereco = List[UInt8]()
        for _ in range(16):
            endereco.append(UInt8(0))
        endereco[0] = UInt8(2)
        endereco[2] = UInt8((porta >> 8) & 0xFF)
        endereco[3] = UInt8(porta & 0xFF)

        if external_call["bind", Int32](self.fd, endereco.unsafe_ptr(), Int32(16)) < 0:
            _ = external_call["close", Int32](self.fd)
            raise Error(
                "http: porta " + String(porta) + " ocupada ou indisponivel"
            )
        if external_call["listen", Int32](self.fd, Int32(16)) < 0:
            _ = external_call["close", Int32](self.fd)
            raise Error("http: listen falhou na porta " + String(porta))

    def aceitar(self) raises -> Int32:
        # o endereco do cliente nao interessa, mas `accept` precisa de onde grava-lo
        var endereco = List[UInt8]()
        for _ in range(16):
            endereco.append(UInt8(0))
        var tamanho = List[Int32]()
        tamanho.append(Int32(16))
        var cliente = external_call["accept", Int32](
            self.fd, endereco.unsafe_ptr(), tamanho.unsafe_ptr()
        )
        if cliente < 0:
            raise Error("http: accept falhou")
        return cliente

    def fechar(self):
        _ = external_call["close", Int32](self.fd)


def fechar_cliente(cliente: Int32):
    _ = external_call["close", Int32](cliente)


def ler_requisicao(cliente: Int32) raises -> Requisicao:
    """Le so a linha de requisicao: o painel nao recebe corpo."""
    var buffer = List[UInt8]()
    for _ in range(_TAM_BUFFER):
        buffer.append(UInt8(0))
    # `recv`/`send` em vez de `read`/`write`: o stdlib do Mojo ja declara estes
    # dois ultimos com outra assinatura, e a redeclaracao nao chega a linkar
    var lidos = external_call["recv", Int64](
        cliente, buffer.unsafe_ptr(), Int64(_TAM_BUFFER), Int32(0)
    )
    if lidos <= 0:
        raise Error("http: conexao fechada antes da requisicao")

    var fim = Int(lidos)
    var quebra = fim
    for i in range(fim):
        if buffer[i] == UInt8(13) or buffer[i] == UInt8(10):
            quebra = i
            break
    var linha = String(from_utf8=Span(buffer)[0:quebra])

    var partes = linha.split(" ")
    if len(partes) < 2:
        raise Error("http: linha de requisicao invalida")
    var metodo = String(partes[0])
    var alvo = String(partes[1])

    var pos = alvo.find("?")
    if pos < 0:
        return Requisicao(metodo, alvo, "")
    return Requisicao(
        metodo,
        String(alvo[byte=0:pos]),
        String(alvo[byte=pos + 1 : alvo.byte_length()]),
    )


def responder(
    cliente: Int32, status: String, tipo: String, corpo: String
) raises:
    var bytes_corpo = corpo.as_bytes()
    var cabecalho = (
        "HTTP/1.1 " + status + "\r\n"
        + "Content-Type: " + tipo + "\r\n"
        + "Content-Length: " + String(len(bytes_corpo)) + "\r\n"
        + "Cache-Control: no-store\r\n"
        + "Connection: close\r\n\r\n"
    )
    var saida = List[UInt8]()
    for b in cabecalho.as_bytes():
        saida.append(b)
    for b in bytes_corpo:
        saida.append(b)

    # sem aritmetica de ponteiro: o que sobra de uma escrita parcial e copiado
    # para um buffer novo. As respostas do painel sao pequenas — o resultado
    # agregado, nunca a tabela — entao a copia nao aparece em lugar nenhum.
    var restante = saida^
    while len(restante) > 0:
        var n = external_call["send", Int64](
            cliente, restante.unsafe_ptr(), Int64(len(restante)), Int32(0)
        )
        if n <= 0:
            break
        var escritos = Int(n)
        if escritos >= len(restante):
            break
        var sobra = List[UInt8](capacity=len(restante) - escritos)
        for i in range(escritos, len(restante)):
            sobra.append(restante[i])
        restante = sobra^


def responder_json(cliente: Int32, corpo: String) raises:
    responder(cliente, "200 OK", "application/json; charset=utf-8", corpo)


def responder_html(cliente: Int32, corpo: String) raises:
    responder(cliente, "200 OK", "text/html; charset=utf-8", corpo)


def responder_erro(cliente: Int32, status: String, mensagem: String) raises:
    responder(
        cliente,
        status,
        "application/json; charset=utf-8",
        '{"erro":' + escapar(mensagem) + "}",
    )
