# Tucano — contrato da API

Engine tabular **100% Mojo**, com ergonomia direta e semântica de banco de dados.

Versão 0.7.0 — M0 → M5 fechados (paralelismo por thread à parte).

Este documento descreve **o que a biblioteca garante**. O `ROADMAP.md` descreve para onde ela vai.

## Tese

Não é a reimplementação de uma API existente. É uma biblioteca tabular usável no primeiro
dia por quem já analisa dados, sobre um execution engine columnar que não repete os vícios
que a prática consagrou.

---

## Regras semânticas

Estas regras valem para toda a API e não mudam entre versões menores.

### 1. Sem index de rótulo

Não existe alinhamento automático entre tabelas. Duas tabelas só se combinam por
`unir(por=...)` explícito. Não há `reset_index()` porque não há índice a resetar.

Quando existir "índice" internamente (M6), ele é estrutura de aceleração de join/lookup —
nunca um rótulo visível que participa de aritmética.

### 2. NA é lógica de três valores

Valor ausente não é `False` nem `0`. Comparação envolvendo NA produz **Desconhecido**.

Os três estados são numerados na ordem do reticulado de Kleene —
`FALSO = 0 < DESCONHECIDO = 1 < VERDADEIRO = 2` — para que `E` seja `min`, `OU` seja `max` e
`NÃO` seja `2 - x`. Cada conectivo é uma instrução SIMD.

| Expressão | Resultado |
|---|---|
| `NA > 18` | Desconhecido |
| `nao(NA > 18)` | Desconhecido |
| `Desconhecido & Falso` | Falso |
| `Desconhecido & Verdadeiro` | Desconhecido |
| `Desconhecido \| Verdadeiro` | Verdadeiro |
| `Desconhecido \| Falso` | Desconhecido |

`onde()` mantém **apenas** linhas Verdadeiro. Linha Desconhecido é descartada, com ou sem
negação.

Uma coluna lógica serve de predicado direto — `onde(coluna("ativo"))` — e ausente nela
também vale Desconhecido.

### 3. NA nunca muda o tipo

Uma coluna de inteiros com valores ausentes continua `inteiro`. O ausente vive no bitmap
de validade, separado do valor — não há upcast para real, não há sentinela dentro do dado.

### 4. Nenhuma coerção implícita

Tipos incompatíveis levantam erro. Nunca coerção silenciosa, nunca tipo genérico de
fallback.

### 5. Agregações ignoram NA

`soma`, `media`, `minimo`, `maximo` operam sobre os valores presentes. `media` divide pela
contagem de válidos, não pelo total de linhas.

Coluna sem nenhum valor válido: `media`, `minimo` e `maximo` levantam erro em vez de
devolver `NaN`. `soma` devolve `0.0` — divergência conhecida em relação ao SQL, onde
`SUM` de tudo nulo é `NULL`. A decidir em M6, junto com as agregações de `agrupar`.

### 6. Uma forma por operação

Não há sinônimos. Antes de qualquer método novo: *já existe um jeito de fazer isso?*

### 7. Zero Python

Sem `std.python`, sem biblioteca de dados em Python no runtime.

---

## Tipos públicos

| Tipo | Papel |
|------|--------|
| `DType` | Tipo lógico: `inteiro`, `real`, `logico`, `texto`, `data`, `datahora` |
| `Campo` / `Schema` / `Shape` | Metadados |
| `Validity` | Bitmap de ausentes (1 bit/linha, 1 = ausente) |
| `StringStore` | `offsets[n+1]` + bytes UTF-8 |
| `Coluna` | Vetor nomeado tipado sobre slabs + validity |
| `Tabela` | Conjunto de colunas alinhadas |
| `Expr` | Nó de expressão (arena) |
| `Consulta` | Pipeline lazy: plano de etapas + materialização |
| `Etapa` / `TipoEtapa` | Uma etapa do plano lógico |
| `Vetor` | Coluna intermediária do executor |
| `Tri` | Verdadeiro / Falso / Desconhecido |
| `DataCivil` | Ano/mês/dia do calendário |

`data` guarda **dias desde 1970-01-01** e `datahora` guarda **microssegundos desde
1970-01-01T00:00:00**, ambos no slab de inteiros: fisicamente inteiros, com o tipo lógico
decidindo a semântica (mesma separação que o Arrow faz com Date32 e Timestamp[us]).
`eh_numerico()` é falso para os dois — `soma()` de datas é erro; `eh_temporal()` é
verdadeiro.

**Fuso horário não é suportado.** Um `Z` final é aceito e ignorado; deslocamentos
(`+03:00`) são recusados.

---

## Storage (Memory Engine)

```
Coluna
├── validity : bitmap empacotado (List[UInt8]) + contagem de ausentes O(1)
├── ints     : slab contíguo Int64    (capacity == len) — inteiro e data
├── reals    : slab contíguo Float64  (capacity == len)
├── logics   : slab contíguo UInt8 0/1
└── textos   : StringStore (offsets + bytes UTF-8)
```

- As factories (`de_inteiros`, `de_reais`, `de_logicos`, `de_textos`) aceitam `List` na
  entrada e **copiam** para o layout columnar.
- `List` aqui é o slab contíguo do Mojo — não uma lista de objetos.
├── codigos  : Int32 por linha quando a coluna de texto é dicionarizada
```

- As factories (`de_inteiros`, …) aceitam `List` na entrada e **copiam** para o layout.
- `List` aqui é o slab contíguo do Mojo — não uma lista de objetos.
- O layout interno não é API pública. Os kernels SIMD acessam esses slabs por ponteiro.

### Dictionary encoding (M4)

Coluna de texto **com repetição** guarda os valores distintos em `textos` e um `Int32` por
linha em `codigos`. Uma comparação com literal resolve o texto para um código uma única vez
— varrendo só os distintos — e o filtro vira comparação de inteiros vetorizada.

`eh_dicionarizada()` e `cardinalidade()` expõem o estado. Coluna com todos os valores
distintos não é dicionarizada: não haveria ganho.

---

## Semântica de memória

- `Tabela` e `Coluna` são `Copyable` e `Movable`. Cópia é **profunda e explícita**.
- Não existe view compartilhada implícita: o ownership do Mojo (`var`, `^`, `ref`) decide
  em compile-time se houve cópia ou movimento.
- Não existe `inplace`. Toda operação devolve um valor novo; use `^` para mover sem copiar.

Isso elimina por construção a classe de bugs de `SettingWithCopyWarning`.

---

## Camadas

```
kernels      SIMD puro — não importa nada do Tucano
    ↓
coluna · dtype · buffer · datas · erros · schema · expr     base
    ↓
vetor · plano                                               tipos do executor
    ↓
executor     opera sobre LOTES (List[Coluna])               camada física
    ↓
tabela       Tabela + Consulta                              API do usuário
```

`tucano/kernels.mojo` fica isolado de propósito: o `DType` lá é o **do Mojo** (parâmetro de
`SIMD`), não o tipo lógico do Tucano.

O **executor não conhece `Tabela`**. Ele recebe e devolve lotes de `Coluna`. Essa é a
separação logical/physical: a camada física não depende do tipo do usuário.

O **planejador raciocina sobre esquema**, não sobre dados: tipos e avisos são calculados
sem executar.

## API da `Tabela`

| Operação | Método |
|---|---|
| criar | `Tabela([colunas…])` |
| ler coluna | `pegar(nome)` |
| adicionar / remover | `adicionar(coluna)` / `remover(nome)` |
| projetar | `selecionar([nomes])` |
| metadados | `shape()` / `schema()` / `nomes()` / `linhas()` / `colunas()` |
| tipo / validade sem cópia | `dtype_de(nome)` / `eh_ausente(nome, i)` |
| agregar | `soma(nome)` / `media(nome)` |
| exibir | `primeiras(n)` / `mostrar()` |
| filtrar (lazy) | `onde(expr)` → `Consulta` |
| coluna derivada (lazy) | `com_coluna(nome, expr)` → `Consulta` |
| entrar no plano | `consultar()` → `Consulta` |
| lote para o executor | `lote()` → `List[Coluna]` |

`Coluna` expõe `soma`, `media`, `minimo`, `maximo`, `contar_ausentes`, `contar_validos`,
`eh_ausente(i)`, `texto_em(i)`, `dias_em(i)` (só em coluna de data).

Factories: `de_inteiros`, `de_reais`, `de_logicos`, `de_textos`, `de_datas` (dias),
`de_datas_texto` (AAAA-MM-DD).

`linhas()` vem sempre das próprias colunas — não existe campo de contagem paralelo.

Todas as operações devolvem uma nova `Tabela`; nenhuma muta a original.

---

## Expressões e consulta

**Ergonomia eager, execução lazy.** `onde()` devolve um plano; a materialização é
automática ao consumir um valor.

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
var t = q.coletar()            # ou explicitamente
```

Materializam sozinhos: `mostrar`, `primeiras`, `linhas`, `colunas`, `shape`, `schema`,
`nomes`, `pegar`, `soma`, `media`. Não materializam: `descrever`, `descrever_fisico`,
`esquema_previsto`, `avisos`, `etapas_do_plano`.

- Construtores: `coluna(nome)`, `lit(f64)`, `lit_int`, `lit_texto`, `lit_bool`, `lit_data`
- Fluente: `.gt .ge .lt .le .eq .ne .e .ou .nao`, aritmética `.mais .menos .vezes .sobre`
- Datas: `ano(expr)`, `mes(expr)`, `dia(expr)` — servem para `data` e `datahora`
- Horas: `hora(expr)`, `minuto(expr)`, `segundo(expr)` — exigem `datahora`
- Literais temporais: `lit_data("2024-02-01")`, `lit_datahora("2024-02-01T10:30:00")`
- Uma coluna temporal compara como número, então
  `coluna("data").ge(lit_data("2024-02-01"))` funciona direto

O `Vetor` carrega a **unidade** dos seus números (número puro / dias / microssegundos), o
que permite `ano()` servir aos dois tipos e faz `coluna("data").mais(lit_int(7))` continuar
sendo uma data.
- Operadores nativos (`>`, `&`) ainda não disponíveis — a arena evita o ciclo de tipo que
  `List[Expr]` criaria
- `descrever()` imprime o plano; `coletar()` materializa

### Coluna derivada e tipo

`com_coluna` infere o tipo do resultado sem coerção silenciosa:

| Expressão | Tipo |
|---|---|
| `inteiro + inteiro` | `inteiro` |
| qualquer operando `real` | `real` |
| divisão | `real` (sempre) |
| `ano/mes/dia` | `inteiro` |
| `lit_data` | `data` |
| comparação / booleano | `logico` |

Comparar texto com número levanta erro — nunca converte em silêncio.

### Avisos

`avisos()` lista as operações que ainda não têm kernel vetorizado. O normal é a ferramenta
não avisar que você saiu do caminho rápido; aqui avisa.

Depois do M4, sobra um caso: comparação em coluna de texto **não dicionarizada** (todos os
valores distintos, ou coluna derivada). Aritmética, comparação numérica, extrator de data e
texto dicionarizado não avisam mais.

Em M3 esta API muda de forma compatível: `Tabela.onde()` passará a devolver `Consulta`
diretamente e a materialização vira automática na exibição. `lazy()` sai da superfície
pública.

---

## I/O

| Entrada | Papel |
|---|---|
| `ler_csv(caminho, delimitador, tem_cabecalho, nrows, pular)` | infere o tipo de cada coluna |
| `ler_csv_tipado(caminho, schema, …)` | schema explícito, sem inferência |
| `LeitorCSV(caminho, …)` | leitura em fatias: `.proximo(n)`, `.fim()`, `.restantes()` |
| `para_csv(tabela, caminho, delimitador)` | escrita |

O caminho é `bytes → scanner → parser tipado → buffers`: nenhuma `String` por célula. Só
coluna de texto materializa `String`, e no fim.

**Aspas RFC 4180** na leitura e na escrita: delimitador e quebra de linha dentro do campo,
`""` como aspa escapada. `para_csv` cita automaticamente o que precisar.

**Inferência**: `datahora` → `data` → `logico` → `inteiro` → `real` → `texto`. Formatos ISO
nunca colidem com número ou booleano.

**Ponto flutuante**: decimal simples é convertido direto dos bytes como `mantissa / 10^k`,
correto por construção enquanto mantissa ≤ 2⁵³ e casas ≤ 22; fora disso cai no `atof`.

`LeitorCSV` limita a **tabela materializada**, não a memória total: o buffer de bytes e as
fronteiras dos campos ficam inteiros em memória. E/S com memória limitada é M9.

### Parquet

| Entrada | Papel |
|---|---|
| `ler_parquet(caminho)` | lê o arquivo inteiro |
| `ler_parquet(caminho, [nomes])` | **column pruning**: as outras colunas nunca são lidas |
| `para_parquet(tabela, caminho)` | escreve |
| `esquema_parquet(caminho)` | esquema só do rodapé, sem tocar nos dados |
| `metadados_parquet(caminho)` | linhas, row groups, codificações, compressão |

Leitura cobre: esquema plano, `PLAIN` e `RLE_DICTIONARY`, níveis de definição RLE/bit-packed,
páginas V1 e V2, sem compressão e Snappy, múltiplos row groups, tipos lógicos por
`ConvertedType` e `LogicalType`.

Escrita usa um subconjunto deliberado — `PLAIN`, sem compressão, um row group, colunas
opcionais — que qualquer leitor aceita. A interoperabilidade é verificada lendo os arquivos
gerados com outra implementação (`pixi run -e fixtures interop`), não com o próprio leitor:
um leitor e um escritor com o mesmo mal-entendido concordam entre si.

---

## Estabilidade

| Superfície | Garantia |
|---|---|
| `DType`, `Schema`, `Campo`, `Shape` | estável |
| `Tabela`, `Coluna` (métodos acima) | estável |
| `Expr` construtores e fluente | estável |
| `tucano.datas` / `tucano.erros` | estável |
| `Consulta`, `Tabela.onde` / `com_coluna` | estável |
| `lazy()` | mantido por compatibilidade — prefira `tabela.onde(...)` |
| `tucano.executor` / `tucano.vetor` / `tucano.plano` | **interno**, muda no M6 |
| `tucano.kernels` | **interno**, contrato de ponteiros pode mudar |
| `tucano.scanner` / `tucano.thrift` / `tucano.codecs` | **interno** |
| `ler_parquet` / `para_parquet` / `esquema_parquet` | estável |
| `ler_csv_tipado` / `LeitorCSV` | estável |
| `ler_csv` / `para_csv` | assinatura estável, implementação refeita em M5 |
| Layout interno de `Coluna` / `buffer.mojo` | **não é API pública** |
