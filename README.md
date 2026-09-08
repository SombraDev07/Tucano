# Tucano

Biblioteca tabular nativa em **Mojo** — ergonomia de pandas, semântica de banco de dados,
motor columnar de ponta a ponta.

Não é um clone da API do pandas. É uma biblioteca usável no primeiro dia por quem vem do
pandas, **sem herdar os erros dele**.

```mojo
from tucano import ler_csv, coluna, lit, lit_int, mes

def main() raises:
    var vendas = ler_csv("vendas.csv")

    vendas.com_coluna("mes", mes(coluna("data")))
          .onde(coluna("valor").gt(lit(1000.0)))
          .selecionar(["mes", "cidade", "valor"])
          .mostrar()
```

Parece eager, executa lazy: `onde()` devolve um plano, e `mostrar()` materializa.

## Instalação

Mojo 1.0+ é o único requisito. Enquanto o pacote não está publicado num canal conda,
use a partir do fonte:

```bash
git clone <url-do-repo> && cd tucano
pixi run test
```

Para usar em outro projeto, copie o diretório `tucano/` e compile com `-I .`:

```bash
mojo -I . meu_script.mojo
```

Precompilar acelera builds locais (o `.mojoc` é ligado à versão do compilador e **não** é
formato de distribuição):

```bash
pixi run build
```

## O que o Tucano faz diferente

| pandas | Tucano |
|---|---|
| Index implícito alinha em silêncio | Sem index de rótulo; join sempre explícito |
| Int com um nulo vira `float64` | Validity bitmap separado — `inteiro` continua `inteiro` |
| String é `object` (um ponteiro por célula) | `StringStore`: offsets + bytes UTF-8 contíguos |
| `SettingWithCopyWarning` | Ownership do Mojo decide cópia vs. movimento em compile-time |
| `df[df.a>5][['b','c']]` materializa o intermediário | Pipeline lazy com plano inspecionável |
| `KeyError: 'idade'` | `coluna inexistente: 'idade'. Voce quis dizer 'idades'?` |
| `NaN` como único ausente, semântica ad-hoc | Lógica de três valores (Verdadeiro / Falso / Desconhecido) |
| String comparada ponteiro a ponteiro | Dictionary encoding: `cidade == "SP"` vira SIMD sobre Int32 (4,2× medido) |
| Single-threaded pelo GIL | Kernels SIMD por padrão — 2× a 4,7× contra o laço escalar |
| `apply()` 100x lento em silêncio | `avisos()` diz quando você saiu do caminho vetorizado |
| tipo da coluna derivada só se sabe depois de calcular | `esquema_previsto()` sem executar nada |

### NA é lógica de três valores

Este é o ponto onde o pandas mais machuca em silêncio. Comparação com ausente não dá
Falso — dá **Desconhecido**, e `onde()` mantém apenas Verdadeiro:

```mojo
lazy(t).onde(coluna("salario").gt(lit(1000.0)))        # linha NA sai
lazy(t).onde(coluna("salario").gt(lit(1000.0)).nao())  # linha NA sai também
```

Nas duas. Sem negação e com negação. É o comportamento do SQL, e é o que impede uma linha
ausente de reaparecer só porque alguém inverteu o predicado.

## API

### Tipos

`inteiro` · `real` · `logico` · `texto` · `data`

```mojo
var c = Coluna.de_inteiros("idade", [Int64(25), Int64(30)])
var d = Coluna.de_datas_texto("quando", ["2024-01-15", "2024-02-20"])
var t = Tabela(colunas)
```

### Tabela

| Operação | Método |
|---|---|
| ler coluna | `pegar(nome)` |
| adicionar / remover | `adicionar(coluna)` · `remover(nome)` |
| projetar | `selecionar([nomes])` |
| metadados | `shape()` · `schema()` · `nomes()` · `linhas()` · `colunas()` · `dtype_de(nome)` |
| agregar | `soma(nome)` · `media(nome)` |
| exibir | `primeiras(n)` · `mostrar()` |

Nenhuma operação muta a tabela original.

### Expressões

```mojo
coluna("idade").gt(lit(18.0)).e(coluna("cidade").eq(lit_texto("SP")))
mes(coluna("data")).eq(lit_int(2))
ano(coluna("data")).ge(lit_int(2024))
coluna("data").ge(lit_data("2024-02-01"))
```

Comparação `.gt .ge .lt .le .eq .ne` · booleanos `.e .ou .nao` ·
aritmética `.mais .menos .vezes .sobre` · datas `ano() mes() dia()`

Operadores nativos (`>`, `&`) ainda não estão disponíveis — a arena de nós evita o ciclo
de tipo que `List[Expr]` criaria.

### Consulta: plano inspecionável

```mojo
var q = (
    tabela
    .com_coluna("dobro", coluna("valor").vezes(lit(2.0)))
    .onde(coluna("dobro").gt(lit(1000.0)))
    .selecionar(["cidade", "dobro"])
)

print(q.descrever())           # plano lógico
print(q.descrever_fisico())    # plano físico + avisos de caminho escalar
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
`pegar`, `soma`, `media`. `coletar()` continua existindo para quem quer o controle.

### Coluna derivada

```mojo
tabela.com_coluna("total", coluna("preco").vezes(coluna("qtd")))
```

O tipo é inferido sem coerção silenciosa: `inteiro + inteiro` dá `inteiro`, divisão dá
sempre `real`, `mes()` dá `inteiro`. Comparar texto com número levanta erro.

## Desempenho

`pixi run bench-m4` compara cada kernel com o laço escalar equivalente, sobre os mesmos
dados (n = 5M, AVX2):

| Operação | Ganho |
|---|---|
| `soma()` | 2,33× |
| comparação → máscara | 3,07× |
| `mes(data)` | 4,70× |
| `cidade == "SP"` (dictionary) | 4,21× |
| `a + b` elementwise | 1,29× (memory-bound) |

E `pixi run bench-m3` mostra escala linear: ns/linha praticamente constante de 25k a 200k.

## Estado

M0 (fundação), M1 (memory engine columnar), M2 (expression engine), M2.5 (biblioteca,
correções de fundação, tipo data), M3 (execution engine) e M4 (SIMD + dictionary encoding)
estão fechados. 60 testes.

Paralelismo por thread está **bloqueado**: o stdlib do Mojo 1.0 não expõe `parallelize`, e o
runtime assíncrono cru não é utilizável para isso hoje. Detalhes no
[ROADMAP.md](ROADMAP.md).

Próximo: **M5 — I/O + Streaming** (scanner CSV tipado, Parquet). Depois: groupby/join, painel.

Roadmap completo em [ROADMAP.md](ROADMAP.md); contrato de API em
[tucano/CONTRATO.md](tucano/CONTRATO.md).

## Desenvolvimento

```bash
pixi run test      # suíte de testes
pixi run bench     # benchmarks M0
pixi run bench-m3  # escala do executor (ns/linha deve ficar constante)
pixi run bench-m4  # SIMD contra o laço escalar equivalente
pixi run exemplo   # exemplo executável
pixi run build     # precompilar o pacote
```

> **Cuidado com `.mojoc` obsoleto.** Se um `tucano.mojoc` precompilado estiver no diretório
> do arquivo que você está compilando, o Mojo o prefere ao fonte — e módulos novos somem
> com um `'Tabela' value has no attribute ...` que não aponta a causa. Apague o `.mojoc`.

## Licença

Apache-2.0 — veja [LICENSE](LICENSE).
