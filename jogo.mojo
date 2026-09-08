# Tesouro no Labirinto — jogo de terminal em Mojo.
# Para jogar: pixi run play   (ou: pixi run mojo jogo.mojo)

from std.random import random_si64, seed
from std.io.io import _fdopen
from std.sys import stdin

comptime LARGURA = 21
comptime ALTURA = 13
comptime TESOUROS = 5

comptime VAZIO = 0
comptime PAREDE = 1
comptime OURO = 2


def idx(x: Int, y: Int) -> Int:
    return y * LARGURA + x


def abs_i(valor: Int) -> Int:
    if valor < 0:
        return -valor
    return valor


def celula_livre(cells: List[Int], x: Int, y: Int, px: Int, py: Int, mx: Int, my: Int) -> Bool:
    if x < 1 or y < 1 or x >= LARGURA - 1 or y >= ALTURA - 1:
        return False
    if x == px and y == py:
        return False
    if x == mx and y == my:
        return False
    return cells[idx(x, y)] == VAZIO


def posicao_livre(mut cells: List[Int], px: Int, py: Int, mx: Int, my: Int) -> Int:
    var tentativas = 0
    while tentativas < 400:
        var x = Int(random_si64(1, LARGURA - 2))
        var y = Int(random_si64(1, ALTURA - 2))
        if celula_livre(cells, x, y, px, py, mx, my):
            return idx(x, y)
        tentativas += 1
    for y in range(1, ALTURA - 1):
        for x in range(1, LARGURA - 1):
            if celula_livre(cells, x, y, px, py, mx, my):
                return idx(x, y)
    return idx(1, 1)


def gerar_labirinto(mut cells: List[Int]):
    for _ in range(LARGURA * ALTURA):
        cells.append(VAZIO)

    for x in range(LARGURA):
        cells[idx(x, 0)] = PAREDE
        cells[idx(x, ALTURA - 1)] = PAREDE
    for y in range(ALTURA):
        cells[idx(0, y)] = PAREDE
        cells[idx(LARGURA - 1, y)] = PAREDE

    var y = 2
    while y < ALTURA - 1:
        var x = 2
        while x < LARGURA - 1:
            cells[idx(x, y)] = PAREDE
            var direcao = Int(random_si64(0, 3))
            if direcao == 0:
                cells[idx(x, y - 1)] = PAREDE
            elif direcao == 1:
                cells[idx(x, y + 1)] = PAREDE
            elif direcao == 2:
                cells[idx(x - 1, y)] = PAREDE
            else:
                cells[idx(x + 1, y)] = PAREDE
            x += 2
        y += 2

    # Garante o canto inicial e o canto do monstro abertos.
    cells[idx(1, 1)] = VAZIO
    cells[idx(2, 1)] = VAZIO
    cells[idx(1, 2)] = VAZIO
    cells[idx(LARGURA - 2, ALTURA - 2)] = VAZIO
    cells[idx(LARGURA - 3, ALTURA - 2)] = VAZIO
    cells[idx(LARGURA - 2, ALTURA - 3)] = VAZIO


def desenhar(
    cells: List[Int],
    px: Int,
    py: Int,
    mx: Int,
    my: Int,
    coletados: Int,
    turnos: Int,
):
    print()
    print("=========================================")
    print("          TESOURO NO LABIRINTO")
    print("=========================================")
    print("Tesouros:", coletados, "/", TESOUROS, "   Turnos:", turnos)
    print("W A S D move    . espera    Q sai")
    print()

    for y in range(ALTURA):
        var linha = String()
        for x in range(LARGURA):
            if x == px and y == py:
                linha += "@"
            elif x == mx and y == my:
                linha += "M"
            else:
                var tile = cells[idx(x, y)]
                if tile == PAREDE:
                    linha += "#"
                elif tile == OURO:
                    linha += "$"
                else:
                    linha += "."
        print(linha)
    print()


def mover_monstro(
    cells: List[Int], mut mx: Int, mut my: Int, px: Int, py: Int
):
    var dx = 0
    var dy = 0
    if mx < px:
        dx = 1
    elif mx > px:
        dx = -1
    if my < py:
        dy = 1
    elif my > py:
        dy = -1

    var primeiro_x = abs_i(mx - px) >= abs_i(my - py)
    var tentativas = 0
    while tentativas < 2:
        var nx = mx
        var ny = my
        if primeiro_x:
            nx = mx + dx
        else:
            ny = my + dy
        if cells[idx(nx, ny)] != PAREDE:
            mx = nx
            my = ny
            return
        primeiro_x = not primeiro_x
        tentativas += 1


def ler(mut teclado: _fdopen["r"], prompt: String) raises -> String:
    print(prompt, end="")
    return teclado.readline()


def comando_dx(cmd: String) -> Int:
    if cmd == "a" or cmd == "A" or cmd == "h" or cmd == "H":
        return -1
    if cmd == "d" or cmd == "D" or cmd == "l" or cmd == "L":
        return 1
    return 0


def comando_dy(cmd: String) -> Int:
    if cmd == "w" or cmd == "W" or cmd == "k" or cmd == "K":
        return -1
    if cmd == "s" or cmd == "S" or cmd == "j" or cmd == "J":
        return 1
    return 0


def comando_valido(cmd: String) -> Bool:
    if cmd == "w" or cmd == "W" or cmd == "a" or cmd == "A":
        return True
    if cmd == "s" or cmd == "S" or cmd == "d" or cmd == "D":
        return True
    if cmd == "k" or cmd == "K" or cmd == "h" or cmd == "H":
        return True
    if cmd == "j" or cmd == "J" or cmd == "l" or cmd == "L":
        return True
    if cmd == ".":
        return True
    return False


def jogar_partida(mut teclado: _fdopen["r"]) raises -> Bool:
    var cells = List[Int]()
    gerar_labirinto(cells)

    var px = 1
    var py = 1
    var mx = LARGURA - 2
    var my = ALTURA - 2
    var coletados = 0
    var turnos = 0

    for _ in range(TESOUROS):
        var pos = posicao_livre(cells, px, py, mx, my)
        cells[pos] = OURO

    while True:
        desenhar(cells, px, py, mx, my, coletados, turnos)
        if coletados >= TESOUROS:
            print("Você reuniu todos os tesouros. Vitória!")
            return True
        if px == mx and py == my:
            print("O monstro te alcançou. Fim de jogo.")
            return False

        var cmd: String
        try:
            cmd = ler(teclado, "Seu movimento: ")
        except:
            print()
            print("Você abandonou o labirinto.")
            return False
        if cmd == "q" or cmd == "Q":
            print("Você abandonou o labirinto.")
            return False
        if not comando_valido(cmd):
            print("Use W A S D para andar, ponto (.) para esperar ou Q para sair.")
            continue

        var nx = px + comando_dx(cmd)
        var ny = py + comando_dy(cmd)
        if cells[idx(nx, ny)] == PAREDE:
            print("Bateu na parede.")
            continue

        px = nx
        py = ny
        turnos += 1

        if cells[idx(px, py)] == OURO:
            cells[idx(px, py)] = VAZIO
            coletados += 1
            print("Tesouro coletado!")

        if px == mx and py == my:
            desenhar(cells, px, py, mx, my, coletados, turnos)
            print("Você tropeçou no monstro. Fim de jogo.")
            return False

        mover_monstro(cells, mx, my, px, py)


def main() raises:
    seed()
    print()
    print("Bem-vindo ao Tesouro no Labirinto!")
    print("Colete os $ e não deixe o M te pegar.")
    print()

    var teclado = _fdopen["r"](stdin)
    var continuar = True
    while continuar:
        _ = jogar_partida(teclado)
        try:
            var resp = ler(teclado, "Jogar de novo? (s/n) ")
            if resp != "s" and resp != "S" and resp != "sim":
                continuar = False
        except:
            continuar = False

    print("Até a próxima!")
