# Tucano

**Biblioteca tabular nativa em Mojo.** Análise de dados com uma API direta, sobre um engine
columnar vetorizado — do buffer ao kernel, sem Python em lugar nenhum.

```mojo
from tucano import ler_csv, coluna, lit, lit_int, mes

def main() raises:
    ler_csv("vendas.csv")
        .com_coluna("mes", mes(coluna("data")))
        .onde(coluna("valor").gt(lit(1000.0)))
        .selecionar(["mes", "cidade", "valor"])
        .mostrar()
```

Parece imediato, executa adiado: `onde()` devolve um plano, e `mostrar()` materializa.

---

## O que é

Tucano é um engine tabular escrito 100% em Mojo. A superfície é pequena e previsível — uma
`Tabela` de `Coluna`s tipadas, expressões componíveis, um plano que você pode inspecionar
antes de executar. Por baixo, cada operação passa por kernels SIMD sobre slabs contíguos.

O projeto tem uma tese: **ergonomia direta na frente, semântica de banco de dados atrás**.
Os verbos são fáceis de aprender; o comportamento é o que um engine de consultas faria, não
o que for mais conveniente na hora.

## Principais recursos

- **Armazenamento columnar tipado** — slabs contíguos por coluna, `capacity == len`, sem
  lista de objetos em lugar nenhum.
- **Ausentes de primeira classe** — bitmap de validade separado do valor. Uma coluna de
  inteiros com valores ausentes continua sendo de inteiros: não há promoção silenciosa para
  ponto flutuante, não há sentinela dentro do dado.
- **Lógica de três valores** — comparar com ausente produz Desconhecido, não Falso. É a
  semântica do SQL, e ela vale igual com ou sem negação.
- **Plano inspecionável** — `descrever()` mostra o plano lógico, `descrever_fisico()` mostra
  os operadores, `esquema_previsto()` dá os tipos do resultado **sem executar nada**.
- **Kernels SIMD** — aritmética, comparação, reduções e calendário vetorizados. De 2× a 4,7×
  contra o laço escalar equivalente, medido.
- **Dictionary encoding** — coluna de texto com repetição vira códigos `Int32`, e um filtro
  por categoria vira comparação de inteiros vetorizada.
- **Avisos de caminho lento** — `avisos()` diz quando uma operação caiu fora do kernel
  vetorizado. Você não descobre por acaso, seis meses depois.
- **Erros que ensinam** — nome de coluna errado devolve a sugestão mais próxima, não um
  código de erro seco.
- **Sem índice implícito** — nenhum alinhamento automático pelas costas. Tabelas se combinam
  por junção explícita.
- **Zero Python** — sem interpretador, sem pontes, sem dependência de runtime.

## Instalação

Mojo 1.0 ou superior é o único requisito.

```bash
git clone git@github.com:SombraDev07/Tucano.git
cd Tucano
pixi run test
```

Para usar em outro projeto, copie o diretório `tucano/` e compile com `-I .`:

```bash
mojo -I . meu_script.mojo
```

Precompilar acelera builds locais — o `.mojoc` é ligado à versão do compilador e não é
formato de distribuição:

```bash
pixi run build
```

O pacote ainda não está publicado num canal conda; `recipe.yaml` está pronto para quando
houver um.

## Começando

```mojo
from tucano import ler_csv, coluna, lit, lit_texto

def main() raises:
    var t = ler_csv("pessoas.csv")

    t.mostrar()
    print(t.shape().linhas, "x", t.shape().colunas)
    print("média de idade:", t.media("idade"))

    t.onde(coluna("idade").gt(lit(18.0)).e(coluna("cidade").eq(lit_texto("SP")))).mostrar()
```

## Tipos

`inteiro` · `real` · `logico` · `texto` · `data`

```mojo
var idade = Coluna.de_inteiros("idade", [Int64(25), Int64(30)])
var valor = Coluna.de_reais("valor", [1200.0, 800.0])
var ativo = Coluna.de_logicos("ativo", [True, False])
var cidade = Coluna.de_textos("cidade", ["SP", "RJ"])
var quando = Coluna.de_datas_texto("quando", ["2024-01-15", "2024-02-20"])
```

Datas são dias desde 1970-01-01 sobre o slab de inteiros: fisicamente um inteiro, com o tipo
lógico decidindo a semântica. Somar datas continua sendo erro.

## API

### Tabela

| Operação | Método |
|---|---|
| ler coluna | `pegar(nome)` |
| adicionar / remover | `adicionar(coluna)` · `remover(nome)` |
| projetar | `selecionar([nomes])` |
| filtrar | `onde(expr)` |
| coluna derivada | `com_coluna(nome, expr)` |
| metadados | `shape()` · `schema()` · `nomes()` · `linhas()` · `colunas()` · `dtype_de(nome)` |
| agregar | `soma(nome)` · `media(nome)` |
| exibir | `primeiras(n)` · `mostrar()` |

Nenhuma operação muta a tabela original.

### Expressões

```mojo
coluna("idade").gt(lit(18.0)).e(coluna("cidade").eq(lit_texto("SP")))
coluna("preco").vezes(coluna("qtd"))
mes(coluna("data")).eq(lit_int(2))
coluna("data").ge(lit_data("2024-02-01"))
```

| Grupo | Métodos |
|---|---|
| comparação | `.gt .ge .lt .le .eq .ne` |
| booleanos | `.e .ou .nao` |
| aritmética | `.mais .menos .vezes .sobre` |
| datas | `ano() mes() dia()` |
| literais | `lit lit_int lit_texto lit_bool lit_data` |

Operadores nativos (`>`, `&`) ainda não estão disponíveis: a árvore de expressão vive numa
arena, o que evita o ciclo de tipo que uma lista recursiva criaria.

### Consulta

```mojo
var q = (
    tabela
    .com_coluna("dobro", coluna("valor").vezes(lit(2.0)))
    .onde(coluna("dobro").gt(lit(1000.0)))
    .selecionar(["cidade", "dobro"])
)

print(q.descrever())           # plano lógico
print(q.descrever_fisico())    # plano físico + avisos
print(q.esquema_previsto())    # tipos do resultado, sem executar
q.mostrar()                    # materializa aqui
```

```
        ProjectionExec: PROJECT [cidade, dobro]
      FilterExec: FILTER (coluna(dobro) > lit(1000.0))
    ExpressionExec: WITH_COLUMN dobro = (coluna(valor) * lit(2.0))
  ScanExec: tabela em memoria
```

Materializam sozinhos: `mostrar`, `primeiras`, `linhas`, `colunas`, `shape`, `schema`,
`pegar`, `soma`, `media`. `coletar()` existe para quem quer o controle explícito.

## Semântica

Três regras que não se renegociam. Elas decidem qualquer dúvida de implementação.

### Ausente é Desconhecido, não Falso

```mojo
tabela.onde(coluna("salario").gt(lit(1000.0)))        # linha ausente sai
tabela.onde(coluna("salario").gt(lit(1000.0)).nao())  # linha ausente sai também
```

Nas duas. Uma linha ausente não reaparece só porque alguém inverteu o predicado. Os três
estados são numerados na ordem do reticulado de Kleene — `FALSO < DESCONHECIDO < VERDADEIRO`
— de modo que `E` é `min`, `OU` é `max` e `NÃO` é `2 - x`: cada conectivo é uma instrução
SIMD.

### Nenhuma coerção implícita

Tipos incompatíveis levantam erro. Comparar texto com número não converte em silêncio.
Coluna derivada tem tipo inferido: `inteiro + inteiro` é `inteiro`, divisão é sempre `real`,
`mes()` é `inteiro`.

### Uma forma por operação

Antes de qualquer método novo, a pergunta é se já existe um jeito de fazer aquilo. Se existe,
o novo é recusado. Bibliotecas de análise costumam crescer para centenas de métodos porque
cada conveniência parecia inofensiva sozinha.

## Desempenho

`pixi run bench-m4` compara cada kernel com o **laço escalar equivalente**, escrito no
próprio benchmark, sobre os mesmos dados. São medições, não afirmações (n = 5M, AVX2):

| Operação | Escalar | SIMD | Ganho |
|---|---|---|---|
| `soma()` | 7158 µs | 3069 µs | **2,33×** |
| comparação → máscara | 19437 µs | 6328 µs | **3,07×** |
| `mes(data)` | 50372 µs | 10707 µs | **4,70×** |
| `cidade == "SP"` (1M linhas) | 2693 µs | 639 µs | **4,21×** |
| `a + b` elementwise | 12373 µs | 9582 µs | 1,29× |

O `a + b` fica em 1,29× por ser limitado por banda de memória: lê dois vetores e escreve um
terceiro. A ALU não é o gargalo ali.

`pixi run bench-m3` mostra que o executor escala linear — ns/linha praticamente constante de
25 mil a 200 mil linhas.

## Arquitetura

```
kernels      SIMD puro — não conhece nada do Tucano
    ↓
coluna · buffer · dtype · schema · datas · erros · expr
    ↓
vetor · plano
    ↓
executor     opera sobre LOTES de Coluna — não conhece Tabela
    ↓
tabela       Tabela + Consulta — a API do usuário
```

A camada física não depende do tipo que o usuário vê. O planejador raciocina sobre esquema
(nome + tipo), não sobre dados, o que permite tipar e avisar sem executar.

## Estado do projeto

| Marco | |
|---|---|
| Fundação, tipos e esquema | ✅ |
| Memory engine columnar | ✅ |
| Expression engine | ✅ |
| Biblioteca instalável, tipo data | ✅ |
| Execution engine coluna-a-coluna | ✅ |
| Kernels SIMD e dictionary encoding | ✅ |
| I/O tipado (CSV scanner, Parquet) | em andamento |
| Agregação e junção | planejado |
| Painel de visualização | planejado |
| Otimizador de consultas | planejado |
| Execução out-of-core | planejado |
| Interoperabilidade Arrow | planejado |

60 testes. Roadmap completo em [ROADMAP.md](ROADMAP.md); contrato de API em
[tucano/CONTRATO.md](tucano/CONTRATO.md).

Paralelismo por thread está bloqueado: o stdlib do Mojo 1.0 não expõe uma primitiva de
paralelismo de dados, e o runtime assíncrono cru não é utilizável para isso hoje.

## Desenvolvimento

```bash
pixi run test      # suíte de testes
pixi run exemplo   # exemplo executável
pixi run bench     # benchmarks de fundação
pixi run bench-m3  # escala do executor
pixi run bench-m4  # SIMD contra o laço escalar
pixi run build     # precompilar o pacote
```

> **Cuidado com `.mojoc` obsoleto.** Se houver um `tucano.mojoc` precompilado no diretório do
> arquivo que você está compilando, o Mojo o prefere ao fonte — e módulos novos somem com um
> `value has no attribute ...` que não aponta a causa. Apague o `.mojoc`.

## Licença

[Apache-2.0](LICENSE).
