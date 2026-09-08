"""Politica de paralelismo — quantas threads, e quando vale usar.

O laco de `pthread_create` mora onde a tarefa e conhecida: o trabalhador precisa
ser uma funcao **concreta** para virar ponteiro, e uma funcao generica sobre o
tipo da tarefa nao vira. Aqui fica so a decisao, que e a parte que precisa ser
a mesma em todo lugar — e a parte que alguem vai querer discutir.

O que o Mojo 1.0 permite, verificado em vez de suposto:

- `pthread_create` aceita uma `def` comum do Mojo como rotina de entrada. Nao
  precisa de `@export`; precisa que o parametro seja um ponteiro com a origin
  fixada: `UnsafePointer[T, origin=AnyOrigin[mut=True]]`. Deixar a origin
  solta com `_` torna a funcao parametrica, e funcao parametrica nao tem
  endereco — o compilador recusa com "cannot use parametric function as a
  runtime closure".
- O alocador aguenta: oito threads criando `List` e `String` sem parar
  devolveram todos os resultados corretos.
- Escala de verdade: carga aritmetica identica em oito threads mediu 7,75x.
  Nao ha lock global no runtime.
- `try`/`except` dentro do trabalhador funciona, e e assim que o erro volta:
  a rotina de entrada nao pode propagar excecao para quem deu `join`.

Duas regras que o desenho respeita, e que valem mais que a velocidade:

**Nenhuma tarefa escreve onde outra le.** Cada uma tem o seu proprio destino, e
o encontro e depois do `join`. Nao ha mutex no caminho quente porque nao ha o
que proteger.

**`pread` e a razao de isso ser simples.** Ler por faixa nao usa o cursor do
arquivo, entao duas threads lendo o mesmo descritor nao disputam nada. O Tucano
ja lia assim desde o M9, por causa de memoria — o paralelismo veio de graca em
cima disso.
"""

from std.ffi import external_call
from std.memory import UnsafePointer

# `_SC_NPROCESSORS_ONLN` no glibc/Linux
comptime _SC_NPROCESSORS_ONLN = 84

# Abaixo disso o trabalho nao paga a criacao da thread. Medido, lendo um Parquet
# de 4 colunas, melhor de 7, com o limiar desligado — a primeira versao chutou
# 50 mil e errou por cinco vezes:
#
#     linhas    sequencial   paralelo   ganho
#      1.000        64 us     110 us     0,58x
#      5.000       104 us     113 us     0,92x
#     10.000       172 us     140 us     1,23x
#     25.000       392 us     256 us     1,53x
#    100.000      1498 us     868 us     1,73x
#
# O ganho satura perto de 1,7x com 4 colunas, nao 4x: as colunas custam coisas
# diferentes, e o total e o da mais cara, nao a media.
comptime LINHAS_MINIMAS_POR_TAREFA = 10_000


def _do_ambiente() -> Int:
    """`TUCANO_THREADS`, ou 0 se nao estiver definida ou nao for numero.

    Quem embute o Tucano num servidor que ja tem o proprio conjunto de threads
    precisa poder dizer "uma so". Variavel de ambiente e o lugar certo: nao
    acrescenta parametro em toda funcao de leitura, e e onde quem opera o
    processo ja procura esse tipo de ajuste.
    """
    var nome = List[UInt8]()
    for b in String("TUCANO_THREADS").as_bytes():
        nome.append(b)
    nome.append(UInt8(0))  # terminador para a libc
    # `getenv` devolve NULL quando a variavel nao existe, e no Mojo um `Pointer`
    # e nao-nulo por construcao. O endereco vem como inteiro, que e onde o zero
    # ainda quer dizer "nao ha".
    var endereco = external_call["getenv", Int](nome.unsafe_ptr())
    if endereco == 0:
        return 0
    var p = UnsafePointer[UInt8, origin=AnyOrigin[mut=True]](
        unsafe_from_address=endereco
    )
    var valor = 0
    var i = 0
    while True:
        var b = p.unsafe_load(i)
        if b == UInt8(0):
            break
        if b < UInt8(48) or b > UInt8(57):
            return 0
        valor = valor * 10 + Int(b - UInt8(48))
        i += 1
        if i > 9:
            return 0
    if i == 0:
        return 0
    return valor


def nucleos() -> Int:
    """Nucleos a usar: `TUCANO_THREADS` manda; senao, os do sistema."""
    var pedido = _do_ambiente()
    if pedido >= 1:
        return pedido
    var n = external_call["sysconf", Int](Int(_SC_NPROCESSORS_ONLN))
    if n < 1:
        return 1
    return n


def threads_para(tarefas: Int, linhas_por_tarefa: Int) -> Int:
    """Quantas threads usar — 1 significa fazer em linha, sem thread nenhuma.

    Nunca mais threads que tarefas: dividir uma coluna entre duas threads exige
    que as duas escrevam no mesmo destino, e e justamente isso que este desenho
    evita.
    """
    if tarefas <= 1:
        return 1
    if linhas_por_tarefa < LINHAS_MINIMAS_POR_TAREFA:
        return 1
    var n = nucleos()
    if tarefas < n:
        return tarefas
    return n
