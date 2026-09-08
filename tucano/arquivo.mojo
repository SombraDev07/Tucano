"""Leitura de faixa de arquivo (M9).

`Path.read_bytes()` carrega o arquivo inteiro. Para um arquivo maior que a RAM,
isso derrota o proposito antes de comecar — nao adianta processar em fatias se a
leitura ja estourou a memoria.

Aqui a leitura e por faixa, via `pread` da libc: abre uma vez, le so o pedaco
pedido, e o resto do arquivo nunca entra em memoria.
"""

from std.ffi import external_call

comptime _O_RDONLY = Int32(0)
comptime _SEEK_END = Int32(2)


struct LeitorArquivo(Movable):
    var fd: Int32
    var caminho: String
    var tamanho: Int

    def __init__(out self, caminho: String) raises:
        self.caminho = caminho
        var bytes_caminho = List[UInt8]()
        for b in caminho.as_bytes():
            bytes_caminho.append(b)
        bytes_caminho.append(UInt8(0))  # terminador para a libc

        # `open`, como `read` e `write`, ja e declarado pelo stdlib com outra
        # assinatura, e a redeclaracao nao chega a linkar. `open64` e o mesmo
        # ponto de entrada sem a colisao.
        self.fd = external_call["open64", Int32](
            bytes_caminho.unsafe_ptr(), _O_RDONLY
        )
        if self.fd < 0:
            raise Error("arquivo: nao foi possivel abrir '" + caminho + "'")

        var fim = external_call["lseek64", Int64](self.fd, Int64(0), _SEEK_END)
        if fim < 0:
            _ = external_call["close", Int32](self.fd)
            raise Error("arquivo: nao foi possivel medir '" + caminho + "'")
        self.tamanho = Int(fim)

    def ler(self, deslocamento: Int, quantidade: Int) raises -> List[UInt8]:
        """Le `quantidade` bytes a partir de `deslocamento`. Nada mais."""
        if quantidade <= 0:
            return List[UInt8]()
        if deslocamento < 0 or deslocamento + quantidade > self.tamanho:
            raise Error(
                "arquivo: faixa [" + String(deslocamento) + ", "
                + String(deslocamento + quantidade) + ") fora de '"
                + self.caminho + "' (" + String(self.tamanho) + " bytes)"
            )
        var buffer = List[UInt8](capacity=quantidade)
        for _ in range(quantidade):
            buffer.append(UInt8(0))

        var lidos = 0
        while lidos < quantidade:
            var n = external_call["pread64", Int64](
                self.fd,
                buffer.unsafe_ptr(),
                Int64(quantidade - lidos),
                Int64(deslocamento + lidos),
            )
            if n <= 0:
                raise Error("arquivo: leitura curta em '" + self.caminho + "'")
            if Int(n) == quantidade - lidos:
                break
            # leitura parcial: o resto entra num buffer proprio e e emendado
            var resto = List[UInt8](capacity=quantidade - lidos - Int(n))
            for _ in range(quantidade - lidos - Int(n)):
                resto.append(UInt8(0))
            var m = external_call["pread64", Int64](
                self.fd,
                resto.unsafe_ptr(),
                Int64(quantidade - lidos - Int(n)),
                Int64(deslocamento + lidos + Int(n)),
            )
            if m <= 0:
                raise Error("arquivo: leitura curta em '" + self.caminho + "'")
            for i in range(Int(m)):
                buffer[lidos + Int(n) + i] = resto[i]
            lidos += Int(n) + Int(m)
        return buffer^

    def fechar(self):
        _ = external_call["close", Int32](self.fd)
