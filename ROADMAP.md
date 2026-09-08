# Roadmap Tucano

**Tese:** biblioteca tabular nativa em Mojo — **ergonomia direta, semântica de banco de dados, motor moderno de ponta a ponta**.

**Não é:** mais uma camada de conveniência sobre um modelo de dados frouxo.
**É:** usável no primeiro dia por quem já analisa dados, sem herdar os vícios que a prática consagrou.

Três objetivos, nesta ordem de dependência:

1. **Biblioteca instalável** — o usuário baixa, importa e analisa. Sem `-I .`, sem clonar repo.
2. **Análise tabular com verbos familiares** — `onde`, `selecionar`, `agrupar`, `unir`. Reconhecível em 5 minutos.
3. **Dashboard nativo** — visualização como camada da biblioteca, não como ecossistema separado.

```
API (eager na aparência)
  → Expression → Logical Plan → Optimizer → Physical Plan
  → SIMD / Parallel / Streaming → Memory Engine → CPU
                                                    ↘ Painel (HTTP/JSON)
```

Polars, DuckDB e DataFusion já cobrem DataFrame/SQL moderno. A oportunidade do Tucano é outra: **aproveitar Mojo 1.x (estável, Apache 2.0) do buffer ao kernel**, com especialização em compile-time, ownership explícito e um caminho curto do dado ao painel.

---

## Por que existir: as armadilhas herdadas

A análise tabular em memória consagrou um conjunto de decisões que hoje custam caro. Isto não é decoração: cada linha abaixo é uma decisão de design do Tucano, tomada contra uma dessas heranças.

| Armadilha herdada | Custo real | Decisão do Tucano | Marco |
|---|---|---|---|
| **Index implícito com alinhamento automático** | `a + b` vira NaN silencioso; `reset_index()` em todo lugar | Sem index de rótulo. Join é sempre explícito | M2.5 |
| **NaN como único missing** | Int com 1 nulo vira `float64` e perde precisão | Validity bitmap separado do valor: Int64 continua Int64 com NA | ✅ M1 |
| **String = `object` dtype** | Um ponteiro Python por célula, zero vetorização | `StringStore` (offsets + bytes) + dictionary encoding — `cidade == "SP"` medido 4,2× | ✅ M1 / M4 |
| **View vs. copy indecidível** | `SettingWithCopyWarning`; ninguém sabe se mutou | Ownership do Mojo (`var` / `^` / `ref`) resolve em compile-time | ✅ grátis |
| **Eager sem plano** | `df[df.a>5][['b','c']]` materializa o intermediário | Lazy por padrão + pushdown | ✅ M2 / M8 |
| **`apply(lambda)` 100x lento em silêncio** | O usuário nunca sabe que caiu do caminho rápido | Plano inspecionável + **aviso explícito ao sair do kernel vetorizado** | ✅ M3 |
| **~600 métodos, 5 formas de indexar** | `.loc`/`.iloc`/`.at`/`.iat`/`[]`, `apply`/`map`/`agg`/`transform` | **Uma forma por operação.** Sinônimos são recusados | permanente |
| **Coerção silenciosa de tipo** | Concat de tipos diferentes → `object` | Erro, nunca coerção implícita | ✅ prática atual |
| **Single-threaded (GIL)** | 1 core de 16 | SIMD por padrão (2–4,7× medido); paralelismo por chunk bloqueado no Mojo 1.0 | ✅ SIMD / ⛔ threads |
| **2–5x a RAM do dado** | `inplace=True` mente e copia mesmo assim | Moves explícitos, zero-copy onde couber | parcial |
| **`groupby.apply` com shape imprevisível** | O retorno muda conforme a função | Só agregações tipadas | M6 |
| **`KeyError: 'idade'` e nada mais** | Um typo custa 5 minutos | `coluna inexistente: 'idade'. Você quis dizer 'idades'?` | M2.5 |
| **Tudo precisa caber na RAM** | Morre em 50M linhas num laptop | Streaming out-of-core | M9 |
| **Viz = PNG estático ou reenviar o dataset** | Streamlit re-executa o script; Dash reenvia o DataFrame | **Widget guarda uma `Consulta`, não uma `Tabela`** | M7 |

---

## Decisões travadas

Regras que não se renegociam a cada marco. Quando houver dúvida de implementação, elas decidem.

### 1. Sem index de rótulo

Não existe alinhamento automático. Duas tabelas só se combinam por `unir(por=...)` explícito.
Quando surgir "índice" no futuro (M6), é **estrutura de aceleração interna** para join/lookup — nunca um rótulo visível que participa de aritmética.

### 2. NA é lógica de três valores

Comparação com NA produz **Desconhecido**, não Falso.

```
NA > 18          → Desconhecido
nao(NA > 18)     → Desconhecido      (não True)
Desconhecido & F → Falso
Desconhecido & T → Desconhecido
Desconhecido | T → Verdadeiro
Desconhecido | F → Desconhecido
```

`onde()` mantém apenas linhas **Verdadeiro**. Desconhecido é descartado, com ou sem negação.

Implementado em M2.5 (`Tri` em `tucano/consulta.mojo`). Uma coluna lógica também serve de predicado direto: `onde(coluna("ativo"))`, com ausente valendo Desconhecido.

### 3. Nenhuma coerção implícita

Tipos incompatíveis levantam erro com mensagem acionável. Nunca `object`, nunca upcast silencioso.

### 4. Uma forma por operação

Antes de adicionar um método, a pergunta é: *já existe um jeito de fazer isso?* Se existe, o novo é recusado. As bibliotecas que chegaram a centenas de métodos começaram assim, uma conveniência de cada vez.

### 5. Erros ensinam

Toda mensagem de erro diz o que aconteceu, onde, e qual é a correção provável. Nome de coluna errado sugere o mais próximo.

### 6. Zero Python

Sem `std.python`, sem biblioteca de dados em Python no runtime.

### 7. Frontend não é Mojo

Mojo faz dado e execução. Navegador faz gráfico, layout e interação. O painel troca **JSON agregado**, nunca o dataset.

---

## Métrica de sucesso

**Não é** "80% da API da biblioteca mais usada". **Nem** "ganhar do DuckDB em TPC-H" — isso levaria anos e não é onde o Tucano é diferente.

São três provas, em ordem de honestidade:

1. **Usabilidade** — um analista acostumado a bibliotecas tabulares resolve uma tarefa real (ler, filtrar, derivar coluna, agrupar, exportar) sem consultar documentação além do README.
2. **Query interativa** — filtro de painel sobre 10M linhas responde em tempo de interação. Aqui pesam startup e replanejamento, onde binário AOT bate stack Python de verdade.
3. **Escala** — suíte pública contra os engines tabulares de referência (1M → 1B linhas): tempo, RAM, throughput, startup, scaling por cores.

---

## Estado atual do código (honestidade)

**M0 → M6 fechados.** Próximo: **M7 — Painel**. 124 testes verdes.

Uma coisa ficou de fora, por bloqueio externo e não por escopo: **paralelismo por thread**, sem primitiva no stdlib do Mojo 1.0. O Parquet, que estava bloqueado por falta de fixture, foi destravado e entregue — leitura e escrita, com interoperabilidade verificada contra outra implementação.

| Peça | Status |
|------|--------|
| `DType` / `Schema` / `Shape` | ✅ M0 |
| `Validity` bitmap + `StringStore` + slabs | ✅ M1 |
| `Expr` (arena) + `coluna`/`lit` + fluent | ✅ M2 |
| `Consulta` lazy + `coletar()` | ✅ M2 |
| API `Tabela` / `Coluna` | ✅ estável |
| NA em lógica de três valores | ✅ M2.5 |
| `DType.DATA` + `lit_data` / `ano` / `mes` / `dia` | ✅ M2.5 |
| Erros com sugestão de nome | ✅ M2.5 |
| README / LICENSE / CHANGELOG / receita conda | ✅ M2.5 |
| Executor coluna-a-coluna (`Vetor` + lotes) | ✅ M3 |
| `Tabela.onde()` lazy + materialização automática | ✅ M3 |
| `com_coluna()` + inferência de tipo derivado | ✅ M3 |
| Plano físico + avisos de caminho escalar | ✅ M3 |
| Propagação de esquema sem executar | ✅ M3 |
| Kernels SIMD (aritmética, comparação, reduções) | ✅ M4 |
| Dictionary encoding automático em texto | ✅ M4 |
| Kernel de calendário em Int32 | ✅ M4 |
| Scanner CSV tipado (`bytes → buffers`) | ✅ M5 — 10,1× |
| Aspas RFC 4180 na leitura e na escrita | ✅ M5 |
| `ler_csv_tipado` (schema explícito) | ✅ M5 |
| `LeitorCSV` (leitura em fatias) | ✅ M5 |
| `DType.DATAHORA` + `hora`/`minuto`/`segundo` | ✅ M5 |
| `ler_parquet` com column pruning | ✅ M5 — 3,6× mais rápido que CSV |
| `para_parquet` com interop verificada | ✅ M5 |
| `agrupar` / `agregar` como operador | ✅ M6 — chave dicionarizada 14,7× |
| `unir` (hash join interno e à esquerda) | ✅ M6 |
| `ordenar` / `concatenar` / `resumo` / `contar_valores` | ✅ M6 |
| `remover_na` / `preencher_na` / `unicos` | ✅ M6 |
| Paralelismo por chunk | ❌ **bloqueado** — sem primitiva no Mojo 1.0 |
| Slab de data em Int32 | ⏸ dívida rastreada — ver abaixo |
| Publicação em canal conda | ❌ exige canal próprio |
| `DType.DATAHORA` | ❌ adiado para M5 |
| Coluna derivada (`com_coluna`) | ❌ M3 |
| `agrupar` / `unir` / `ordenar` | ❌ M6 |
| Painel | ❌ M7 |

### Dívidas concretas identificadas

**1. ~~`Tabela.indice` era um índice implícito nascendo.~~** ✅ Removido em M2.5. `linhas()` vem de `_colunas[0].tamanho()`.

**2. ~~`Consulta.coletar()` é quadrático.~~** ✅ Resolvido em M3. O executor lê cada coluna **uma vez** para um `Vetor` contíguo (com `ref` sobre o lote, sem cópia) e opera sobre ele. `bench/bench_m3.mojo` mede ns/linha praticamente constante de 25k a 200k linhas — escala linear.

**3. ~~Lógica de NA sob negação.~~** ✅ Corrigido em M2.5 — ver Decisão 2. Regressão coberta por `test_na_tres_valores_negacao`.

**4. Slab de data em Int32 — dívida rastreada.** Já foi adiada duas vezes, então deixa de ser "herdada do marco anterior" e passa a ter gatilho explícito. Datas e datahoras vivem hoje no slab `Int64` da `Coluna`. O motivo original — velocidade de cálculo — foi resolvido no M4: o kernel de calendário converte para Int32 justamente porque Int64 não vetoriza divisão no AVX2. O que resta é memória: 4 bytes contra 8 por linha de data.

Adicionar agora um sexto `List` paralelo à `Coluna` piora a estrutura em vez de melhorá-la. **Gatilho:** entra junto do redesenho de `Coluna` para um buffer de bytes tipado (largura + tipo lógico, em vez de um `List` por tipo) — que é a forma certa e a que o M9 vai precisar para spill em disco.

---

## Linha do tempo

| Marco | Nome | Prioridade | Status | Resultado |
|-------|------|------------|--------|-----------|
| M0 | Fundação | crítica | ✅ feito | `Tabela`/`Coluna` estáveis + Schema |
| M1 | Memory Engine | crítica | ✅ feito | columnar + validity + buffers |
| M2 | Expression Engine | crítica | ✅ feito | expressões + plano lógico |
| M2.5 | Biblioteca + Correções | crítica | ✅ feito | instalável, sem dívidas de fundação |
| M3 | Execution Engine | crítica | ✅ feito | executor coluna-a-coluna |
| M4 | SIMD (+ Parallel) | crítica | ✅ SIMD / ⛔ paralelo | kernels vetorizados |
| M5 | I/O + Streaming | crítica | ✅ feito | scanner CSV, Parquet, fatias, datahora |
| M6 | Aggregation + Join | crítica | ✅ feito | group/join como operadores |
| **M7** | **Painel** | **alta** | **próximo** | dashboard nativo |
| M8 | Optimizer | crítica | não iniciado | pushdown + folding + reorder |
| M9 | Out-of-Core | alta | não iniciado | datasets > RAM |
| M10 | Interop | alta | não iniciado | Arrow (sem Python) + SQL |
| M11 | GPU | experimental | não iniciado | aceleradores selecionados |
| M12 | Excel | baixa | não iniciado | compatibilidade tardia |

```
M0 Fundação
 ↓
M1 Memory Engine (columnar)
 ↓
M2 Expression Engine
 ↓
M2.5 Biblioteca instalável + correções de fundação
 ↓
M3 Execution Engine (coluna-a-coluna)
 ↓
M4 SIMD + Parallel + dictionary encoding
 ↓
M5 I/O (scanner CSV + Parquet)
 ↓
M6 Aggregation + Join      ← a partir daqui o painel faz sentido
 ↓
M7 Painel
 ↓
M8 Optimizer               ← torna o painel interativo em escala
 ↓
M9 Out-of-Core
 ↓
M10 Interop (Arrow / SQL)
 ↓
Tucano 1.0
   └── M11 GPU [experimental]   M12 Excel [depois]
```

**Por que o Painel antes do Optimizer:** o painel é o primeiro artefato que um usuário vê e entende sem ler benchmark. Ele fecha o objetivo 3 e valida os objetivos 1 e 2 de uma vez. O Optimizer vem logo atrás porque é ele que transforma "painel que funciona" em "painel que responde em 10M linhas".

---

## M0 — Fundação ✅

`DType`, `Campo`, `Schema`, `Shape`, `Validity`, API `shape`/`schema`/`adicionar`/`remover`, testes, `tucano/CONTRATO.md`, `bench/bench_m0.mojo`.

---

## M1 — Columnar Memory Engine ✅

```
Tabela
├── Coluna<Int64>    → slab + validity bitmap
├── Coluna<Float64>  → slab + validity bitmap
└── Coluna<String>   → offsets + bytes + validity bitmap
```

`Validity` bitmap, `StringStore`, slabs numéricos, `Coluna` reescrita, 12 testes.

---

## M2 — Expression Engine ✅

```
coluna("idade").gt(lit(18)).e(coluna("pais").eq(lit_texto("BR")))

          AND
         /   \
       >       ==
      / \     /  \
 idade  18  pais  BR
```

Árvore em arena tipada por `Kind`, pipeline sem materializar (`Consulta`), materialização explícita (`coletar()`).

---

## M2.5 — Biblioteca instalável + correções de fundação ✅

**Bloco curto e obrigatório.** Separou "meu projeto" de "biblioteca" e pagou as três dívidas antes que o M3 as cimentasse.

### Distribuição

- [x] `git init` + histórico inicial
- [x] `README.md` com exemplo que roda em 30 segundos
- [x] `LICENSE` (Apache-2.0) + versão `0.3.0` + `CHANGELOG.md`
- [x] `recipe.yaml` pronto para `rattler-build`
- [x] Tarefa `pixi run build` (`mojo precompile tucano -o tucano.mojoc`)
- [x] Fronteira explícita de API pública em `tucano/__init__.mojo`
- [ ] Publicação em canal conda → `pixi add tucano` — **exige canal próprio (prefix.dev ou equivalente)**

> **Correção de fato:** `mojo package` foi substituído por `mojo precompile`, e `.mojopkg` por `.mojoc`. O `.mojoc` é ligado à versão exata do compilador e a própria documentação do Mojo diz que **não é formato de distribuição** — serve para acelerar builds locais. A distribuição de bibliotecas Mojo é **por fonte**: canal conda ou repositório. O `recipe.yaml` cobre o primeiro caso quando houver canal.

> Empacotar cedo força a decisão de superfície pública. Foi a ausência dessa disciplina que produziu bibliotecas com centenas de métodos e cinco formas de indexar.

### Correções

- [x] Remover `Tabela.indice`; `linhas()` vem de `_colunas[0].tamanho()`
- [x] NA como lógica de três valores, `nao()` incluído (Decisão 2)
- [x] Erros com sugestão de nome próximo em coluna inexistente
- [x] Bônus: coluna lógica como predicado direto — `onde(coluna("ativo"))`
- [x] Bônus: `Tabela.dtype_de` / `eh_ausente` — metadados sem copiar a coluna

### Tipo data

- [x] `DType.DATA` — dias desde 1970-01-01 sobre o slab de inteiros
- [x] `Coluna.de_datas` / `de_datas_texto`, módulo `tucano.datas`
- [x] Inferência ISO-8601 no `ler_csv` e round-trip no `para_csv`
- [x] `lit_data()`, `ano()`, `mes()`, `dia()` como expressões
- [ ] `DType.DATAHORA` — **adiado para M5**, junto do scanner de I/O real

> Data é fisicamente um inteiro; o tipo lógico é que decide a semântica — mesma separação do Arrow com Date32. `soma()` de datas continua sendo erro, porque `eh_numerico()` é falso para data. Estreitar o slab para Int32 fica para o M4, quando o storage for revisto para SIMD.

> Nenhuma análise real existe sem data — e é o eixo de qualquer painel (`x = mes`).

### Critério de saída

- [x] Testes de regressão de NA cobrindo negação, `e`/`ou` e resultado vazio
- [x] `DType.DATA` atravessando CSV → filtro → extrator → saída
- [x] 33 testes verdes
- [ ] Um terceiro instala pelo canal conda — pendente de canal

---

## M3 — Execution Engine ✅

```
API → Expression → Logical Plan → Executor físico → Tabela
```

O ponto central: **trocar avaliação linha-a-linha por coluna-a-coluna.** O `Filter` físico recebe ponteiros para os slabs uma vez, produz uma máscara / selection vector, e só então materializa.

```
SCAN → FILTER idade > 18 → PROJECT nome, idade → RESULT
```

### Ergonomia eager, execução lazy

`Tabela.onde()` passa a devolver `Consulta`, não `Tabela`. O plano acumula invisível; `mostrar()`, `primeiras()` e qualquer consumo de valor materializam sozinhos. `coletar()` continua para quem quer controle. `lazy()` sai da API pública — vira o comportamento padrão.

```mojo
var resultado = tabela.onde(coluna("idade").gt(lit(18))).selecionar(["nome", "idade"])
resultado.mostrar()   # materializa aqui
```

### Coluna derivada

Atribuir uma coluna calculada é metade do uso real e hoje não existe:

```mojo
var t = tabela.com_coluna("total", coluna("preco").vezes(coluna("qtd")))
```

### Como ficou

```
tucano/vetor.mojo     Vetor — slab contíguo + máscara de ausentes
tucano/plano.mojo     Etapa / plano lógico / plano físico
tucano/executor.mojo  operadores sobre LOTES de Coluna — não conhece Tabela
tucano/tabela.mojo    Tabela + Consulta (a face eager e a face lazy)
```

O executor opera sobre **lotes** (`List[Coluna]`), não sobre `Tabela`. É a separação
logical/physical de verdade: a camada física não conhece o tipo do usuário — e é a forma
que o M6 precisa, quando join e groupby passarem lotes entre operadores.

O planejador raciocina sobre **esquema** (nome + tipo), não sobre dados: `esquema_apos()`
propaga tipos etapa a etapa, o que dá `esquema_previsto()` sem executar nada e é a base do
otimizador do M8.

### Critério de saída

- [x] Scan / Filter / Project / Expression físicos, coluna-a-coluna
- [x] Separação clara logical vs. physical (executor sobre lotes)
- [x] `com_coluna()` sobre o Expression Engine, com inferência de tipo derivado
- [x] `Tabela.onde()` lazy por padrão, materialização automática na exibição
- [x] Fim da cópia por linha (dívida 2) — `ref` sobre o lote, zero cópia
- [x] `descrever()` lógico e `descrever_fisico()` com plano indentado
- [x] Aviso quando uma operação cai fora do caminho vetorizado
- [x] Mesmos resultados da API antiga — 33 testes de regressão intactos
- [x] Bônus: `esquema_previsto()` — tipos do resultado sem executar
- [x] Bônus: `bench/bench_m3.mojo` demonstra escala linear
- [x] 48 testes verdes

---

## M4 — SIMD ✅ (+ Parallel ⛔ bloqueado)

A justificativa de usar Mojo: kernels especializados que uma biblioteca com runtime interpretado não pode ter.

### Ganhos medidos

`pixi run bench-m4` compara cada kernel com o **laço escalar equivalente**, escrito no
próprio bench, sobre os mesmos dados. Não é afirmação, é medição (n = 5M, AVX2, 4×Float64):

| Operação | Escalar | SIMD | Ganho |
|---|---|---|---|
| `soma()` | 7158 µs | 3069 µs | **2,33×** |
| `a + b` elementwise | 12373 µs | 9582 µs | 1,29× |
| comparação → máscara | 19437 µs | 6328 µs | **3,07×** |
| `mes(data)` | 50372 µs | 10707 µs | **4,70×** |
| `cidade == "SP"` (1M) | 2693 µs | 639 µs | **4,21×** |

`a + b` fica em 1,29× porque é *memory-bound*: lê dois vetores e escreve um terceiro. A
banda de memória é o teto, não a ALU.

### Três achados que valem mais que o código

**1. A ordem do `Tri` não é arbitrária.** Trocando para a ordem do reticulado de Kleene —
`FALSO=0 < DESCONHECIDO=1 < VERDADEIRO=2` — o `E` vira `min`, o `OU` vira `max` e o `NÃO`
vira `2 - x`. Cada conectivo passa a ser **uma instrução SIMD**, em vez de uma cadeia de
desvios. A semântica é idêntica; só a numeração mudou.

**2. Int64 não vetoriza divisão no AVX2.** O `civil_de_dias` só divide por constantes, o que
o compilador troca por multiplicação e deslocamento. Em Int64 isso exige multiplicação
64×64→128, que o AVX2 não tem: **ganho medido 1,00×**. Reescrito em Int32 (todos os
intermediários cabem com folga), o mesmo algoritmo dá **4,70×** — e ainda dobra as pistas.

**3. A máscara desempacotada custava mais que a redução.** A primeira versão de `soma()`
desempacotava o bitmap de validade para bytes antes de reduzir: ganho 1,12×. Com a contagem
de ausentes mantida na construção (`Validity.n_ausentes`, O(1)) e um kernel denso para o
caso sem ausentes, foi para **2,33×**.

### Dictionary encoding

Coluna de texto com repetição guarda valores distintos + um `Int32` por linha.
`cidade == "SP"` resolve o literal para um código **uma vez** — varrendo só os distintos — e
o filtro vira comparação de inteiros vetorizada. A alternativa consagrada é comparar
ponteiros de objeto, um por vez.

No M6 a mesma estrutura faz groupby por chave dicionarizada virar **indexação direta de
array**, sem hash.

### Paralelismo — bloqueado

**O stdlib do Mojo 1.0 não expõe `parallelize`.** Existem `TaskGroup` e `create_task` em
`std.runtime.asyncrt`, mas: um `TaskGroup()` destruído sem uso já aborta o processo
(`destroying a non-available AsyncValue isn't implemented`), e passar ponteiros para uma
`async def` exige apagar a origem — `unsafe_ptr()` devolve `Pointer` com origem amarrada, e
não há `origin_cast` nem `MutableAnyOrigin` acessíveis.

Construir paralelismo de dados sobre isso hoje seria frágil. Vira **trilha própria**, a
retomar quando o stdlib expuser uma primitiva estável.

### Critério de saída

- [x] Kernels SIMD nas ops numéricas críticas
- [x] Dictionary encoding automático por cardinalidade
- [x] Kernel de calendário (em Int32, pelo motivo acima)
- [x] Speedup mensurável contra laço escalar equivalente — tabela acima
- [x] `avisos()` vazio para extrator de data e texto dicionarizado
- [x] 60 testes verdes, incluindo equivalência SIMD × escalar
- [ ] Paralelismo por chunks — **bloqueado**, trilha própria
- [ ] Estreitar o slab de data para Int32 — adiado para M5

> O slab de data continua Int64. O motivo que fazia isso urgente era o **cálculo**, e esse já
> está resolvido: o kernel de calendário converte para Int32. O que resta é economia de
> memória, que cabe melhor no M5, junto da reescrita da camada de storage no scanner.

---

## M5 — I/O + Streaming ✅

### CSV: scanner tipado

Não mais `arquivo → String → split → objetos`, que alocava uma `String` por célula **antes de saber o tipo dela**. Agora `bytes → scanner → parser tipado → buffers`: o arquivo é lido uma vez, o scanner marca as fronteiras dos campos (dois inteiros por célula, nenhuma alocação) e o parser escreve direto no slab da coluna. Texto só vira `String` no fim, e só em coluna de texto.

| Medição | Antes | Depois | |
|---|---|---|---|
| `ler_csv` (infere) | 7226 ns/linha | **715 ns/linha** | **10,1×** |
| `ler_csv_tipado` | — | **304 ns/linha** | 2,35× vs. inferir |
| `para_csv` | — | 365 ns/linha | |

Throughput de leitura: 42 MiB/s **com** inferência de tipo.

**Aspas RFC 4180** entraram junto — delimitador e quebra de linha dentro do campo, `""` como aspa escapada — na leitura *e* na escrita. O leitor anterior não suportava; era uma limitação documentada que virava corrupção silenciosa em CSV real.

**Parser de ponto flutuante:** decimal simples é convertido direto dos bytes como `mantissa / 10^k`. Com mantissa ≤ 2⁵³ e até 22 casas decimais, esse resultado é corretamente arredondado — idêntico ao de um parser completo. Fora dessa faixa (expoente, precisão extrema), cai no `atof`. O caminho rápido cobre praticamente todo CSV real sem abrir mão da exatidão.

**Schema explícito** (`ler_csv_tipado`) além da inferência: é 2,35× mais rápido, e é a única forma de garantir que o tipo de hoje continua sendo o de amanhã quando o arquivo mudar.

### Datahora

`DType.DATAHORA` guarda **microssegundos desde a epoch** em Int64 — mesma unidade que o Arrow usa por padrão em timestamp. Parsing ISO-8601 com fração de segundo e `Z` opcional, extratores `hora()`, `minuto()`, `segundo()`, e `ano()`/`mes()`/`dia()` funcionando igualmente sobre `data` e `datahora`.

O último item saiu de graça de uma decisão pequena: o `Vetor` passou a carregar a **unidade** dos seus números (número puro / dias / microssegundos). Sem ela, o executor precisaria consultar o esquema para saber se `ano(x)` recebeu dias ou microssegundos. Como efeito colateral, `coluna("data").mais(lit_int(7))` continua sendo uma data.

**Fuso horário não é suportado:** um `Z` final é aceito e ignorado, deslocamentos (`+03:00`) são recusados. Meia implementação de fuso é pior que nenhuma — entra quando houver um tipo com fuso de verdade.

### Streaming em fatias

`LeitorCSV` entrega a tabela em fatias de N linhas, para não materializar tudo de uma vez. O buffer de bytes e as fronteiras dos campos ainda ficam todos em memória: **E/S com memória limitada de verdade é trabalho do out-of-core (M9)**, e o roadmap não deve fingir o contrário.

### Parquet

Estava bloqueado por não haver, nesta máquina, forma de produzir um arquivo Parquet real para verificar o leitor contra. Um parser de formato binário sem fixture não é código pronto. O destrave foi adotar `pyarrow` como dependência **de geração de fixture**, em ambiente pixi separado — o princípio de Zero Python é sobre o que a biblioteca carrega em produção, e nenhum módulo em `tucano/` importa nada dele.

Com isso, entregue leitura e escrita:

| | ns/linha | |
|---|---|---|
| `ler_parquet` (6 colunas) | **215** | **3,6×** mais rápido que CSV |
| `ler_parquet` com pruning (2 de 6) | **76** | **2,8×** mais rápido que ler tudo |
| `para_parquet` | 232 | 2,4× mais rápido que escrever CSV |
| só o rodapé (esquema + contagem) | — | 2,2 ms, sem tocar em byte de dado |

**Column pruning nasceu no design**, não como otimização posterior: os metadados ficam no rodapé justamente para que se saiba onde cada coluna começa antes de ler qualquer dado. `ler_parquet(caminho, ["a", "b"])` nunca toca nos bytes das outras.

Coberto: esquema plano, `PLAIN` e `RLE_DICTIONARY`, níveis de definição em RLE/bit-packed, páginas V1 e V2, sem compressão e Snappy, múltiplos row groups, e os tipos lógicos que importam (`UTF8`, `DATE`, `TIMESTAMP` em milis/micros/nanos, via `ConvertedType` **e** `LogicalType`).

Três camadas novas, todas independentes do resto:

```
tucano/thrift.mojo   protocolo Thrift compact — leitura e escrita
tucano/codecs.mojo   Snappy cru + RLE/bit-packing híbrido
tucano/parquet.mojo  metadados, páginas, montagem de coluna
```

**A verificação é o ponto.** Round-trip próprio não prova nada: um leitor e um escritor com o mesmo mal-entendido concordam entre si. `pixi run -e fixtures interop` lê com outra implementação os arquivos que o Tucano escreveu e compara valor a valor — é isso que autoriza dizer que está pronto.

Foi essa verificação que pegou o único erro de semântica que o round-trip próprio não pegaria: sem emitir `LogicalType`, um carimbo de tempo ingênuo volta marcado como UTC, porque o `ConvertedType` legado não distingue os dois casos.

### Critério de saída

- [x] `ler_csv` / `para_csv` sobre o Memory Engine, sem `String.split` — 10,1×
- [x] Aspas RFC 4180 na leitura e na escrita
- [x] Schema explícito opcional na leitura
- [x] `DType.DATAHORA` com parsing ISO-8601 — herdado do M2.5
- [x] Caminho de streaming por fatias
- [x] `ler_parquet` / `para_parquet` com column pruning
- [x] Interoperabilidade verificada contra outra implementação
- [x] 99 testes verdes
- [ ] Slab de data em Int32 — adiado para o M6

> O slab de data continua Int64. Adicionar agora um sexto `List` paralelo em `Coluna` iria na direção contrária da reescrita de storage que o M6 precisa fazer para join e groupby. Entra lá, junto.

---

## M6 — Aggregation + Join ✅

Operadores do engine, não funções soltas: `HashAggregateExec`, `HashJoinExec`, `SortExec`, `UnionExec`, `DropNullExec`, `FillNullExec` — todos visíveis em `descrever_fisico()`.

### O dictionary encoding se paga aqui

`pixi run bench-m6`, 1 milhão de linhas, chave de 50 valores distintos:

| Formação de grupos | ns/linha | |
|---|---|---|
| chave de texto **dicionarizada** | **11** | indexação direta de array, sem hash |
| chave inteira | 16 | hash de inteiros |
| chave composta | 161 | chave textual concatenada |

**14,7× entre o caminho dicionarizado e o composto.** A estrutura criada no M4 para acelerar `cidade == "SP"` acelera `agrupar(["cidade"])` pelo mesmo motivo: o código `Int32` já *é* o identificador do grupo, então não há o que hashear.

| Operação (1M linhas) | ns/linha |
|---|---|
| `agrupar` + 3 agregações | 43 |
| `unir` à esquerda | 316 |
| `ordenar` (mesclagem estável) | 382 |

O join também ganhou caminho tipado: chave única inteira usa `Dict[Int, …]`, chave única de texto usa a própria `String`, e só combinações de colunas pagam a chave composta.

### Agregações

```mojo
tabela.agrupar(["cidade"]).agregar([soma("valor"), media("valor"), contar()])
```

`soma`, `media`, `contar`, `contar_de`, `minimo`, `maximo`, `primeiro`, `distintos`, com `.como("apelido")` para renomear a saída. Um jeito só de agregar — sem `apply` que devolve qualquer coisa, sem retorno cuja forma dependa do que a função fez. O tipo de saída é conhecido **antes** de executar, e `esquema_previsto()` mostra.

`minimo`/`maximo` preservam o tipo de entrada: o máximo de uma coluna `data` é uma `data`, não um número.

### Somar nada não dá zero

Decisão que estava pendente desde o M1, fechada aqui: **grupo sem nenhum valor válido sai como ausente**, não como `0`. E `Coluna.soma()` passou a levantar erro nesse caso, em vez de devolver `0.0` — a mesma regra que `media`, `minimo` e `maximo` já seguiam.

Zero é uma afirmação sobre a soma. Quando não há o que somar, a resposta honesta é Desconhecido.

### Junção

```mojo
vendas.unir(cidades, ["cidade"], "esquerda")
```

Interna e à esquerda, com hash na tabela direita e sondagem pela esquerda — o lado direito é o construído porque é o que desaparece do resultado quando não há par.

**Chave ausente não casa com nada**, nem com outra ausente: ausente não é um valor, é Desconhecido. Mesma regra do filtro.

**Nome repetido fora das chaves é recusado**, não renomeado em silêncio com um sufixo. O erro diz o que fazer.

### Ordenação

`ordenar(chaves, descendente)` é **estável**, e ausente vai sempre para o fim nas duas direções. Direções mistas saem de dois passos — `ordenar(["b"], True).ordenar(["a"])` dá `a` crescente com `b` decrescente dentro de cada `a` — e é por isso que não existe uma segunda forma de ordenar.

### Também neste marco

`concatenar` (exige mesmo esquema, sem alinhamento por posição), `remover_na`, `preencher_na` (sem conversão implícita), `contar_valores`, `unicos`, `resumo`.

O `resumo()` não inventa estatística: coluna não numérica traz contagens, e média/mínimo/máximo saem **ausentes** em vez de zero.

### Critério de saída

- [x] GroupBy + agregações (soma, média, contagem, min, max, primeiro, distintos)
- [x] Join hash interno e à esquerda
- [x] Verbos de análise: ordenar, concatenar, resumo, contar_valores, únicos, preencher_na, remover_na
- [x] Operadores físicos visíveis no plano
- [x] 124 testes verdes
- [ ] Benchmarks contra engines de referência — **exige instalá-los**

> A comparação externa precisa de Polars e DuckDB na máquina. Adicioná-los como dependência **de benchmark** (ambiente separado, como já foi feito para as fixtures de Parquet) é decisão de projeto, não técnica — e é o próximo passo natural para a suíte pública.

---

## M7 — Painel

O dashboard como camada da biblioteca. A arquitetura vem direto da crítica às ferramentas existentes: o gráfico embutido gera PNG estático, Streamlit re-executa o script inteiro, Dash reenvia o DataFrame. Todos tratam o painel como consumidor de **dados**.

### O widget guarda uma `Consulta`, não uma `Tabela`

```mojo
var vendas = ler_parquet("vendas.parquet")
var painel = vendas.painel("Vendas")

painel.kpi("Faturamento", coluna("valor").soma())
painel.grafico(tipo="linha", x=mes(coluna("data")), y=soma("valor"))
painel.tabela(["cidade", "valor"])
painel.filtro("estado")
painel.filtro("cidade")

painel.abrir()
```

Mexer num filtro **muda o plano**, não os dados. O servidor reexecuta e devolve o agregado:

```
500.000 linhas → agrupar(mes) → 12 linhas → JSON → navegador
```

```json
[{"mes": "jan", "valor": 120000}, {"mes": "fev", "valor": 140000}]
```

Nenhuma cópia do dataset atravessa a rede. Com o M8, o filtro vira predicate pushdown e nem chega a varrer tudo.

### Arquitetura

```
Mojo
 │  Tucano (Tabela / Consulta / Executor)
 │  Servidor de painel
 ▼  HTTP + JSON  (SSE ou WebSocket para atualização)
Navegador
    HTML / CSS / JS estático, embutido na biblioteca
```

### Escopo deliberadamente magro

Servidor + JSON + frontend estático. KPI, gráfico (linha/barra/pizza), tabela, filtro. **Nada além disso no M7.** Layout customizável, temas, drill-down e exportação ficam para depois de o painel provar seu valor.

### Risco a resolver antes de começar

Verificar se existe stack HTTP utilizável para Mojo 1.x. Historicamente isso era comunidade (`lightbug_http`), não stdlib. Se não houver, o M7 vira "escrever um servidor HTTP" em vez de "entregar um painel" — nesse caso, reavaliar escopo antes de abrir o marco.

### Critério de saída

- [ ] `painel.abrir()` sobe servidor e abre no navegador
- [ ] KPI, gráfico, tabela e filtro funcionando
- [ ] Filtro recalcula plano e reenvia só o agregado
- [ ] Payload medido: JSON proporcional ao agregado, não ao dataset
- [ ] Demo pública com dataset de 1M+ linhas

---

## M8 — Query Optimizer

- Projection pushdown
- Predicate pushdown (especialmente Parquet)
- Constant folding
- Common subexpression elimination
- Join ordering (v1 simples)
- Type specialization
- Cardinalidade (v1 heurística)

### Critério de saída

- [ ] Planos antes/depois inspecionáveis
- [ ] Pushdown demonstrável em Parquet
- [ ] Menos I/O e menos colunas lidas nos benches
- [ ] Filtro de painel sobre 10M linhas em tempo de interação

---

## M9 — Out-of-Core / Streaming Execution

Datasets > RAM: chunk → filter/aggregate → merge; spill-to-disk; memória limitada.

### Critério de saída

- [ ] Pipeline bounded-memory em ao menos um workload (groupby ou filter+agg)
- [ ] Teste com dataset artificial maior que a RAM disponível

---

## M10 — Interoperabilidade

```
Tucano ↔ Arrow memory ↔ Polars / DuckDB / DataFusion
```

Depois: SQL → JSON → (muito depois) Excel.

### Critério de saída

- [ ] Export/import Arrow zero-copy onde possível, sem Python
- [ ] Dialeto SQL mínimo sobre o mesmo planner (desejável)

---

## M11 — GPU [experimental]

Trilha paralela, **fora** do caminho crítico. Só depois de Filter / GroupBy / Aggregate / Sort estarem maduros na CPU, e só onde o workload justificar.

---

## M12 — Excel [baixa]

Último. Compatibilidade, não inovação.

---

## Tucano 1.0 — definição de pronto

**Core** — Tabela, Coluna, schema, Int/Float/Bool/String/Data, NA de três valores, memória columnar

**Expressions** — coluna, literais, comparação, aritmética, booleanos, coluna derivada

**Execution** — filter, projection, expression, sort, aggregation

**Analytics** — groupby, join, concat, resumo, estatísticas básicas

**I/O** — CSV, Parquet

**Painel** — KPI, gráfico, tabela, filtro interativo

**Performance** — SIMD, multithreading, dictionary encoding, streaming, benchmarks públicos

**Distribuição** — pacote instalável, README, documentação de API

**Fora do 1.0** — Python, Excel, clonagem de API alheia, GPU obrigatória

---

## API de destino

```mojo
from tucano import ler_parquet, coluna, lit, soma, mes

def main() raises:
    var vendas = ler_parquet("vendas.parquet")

    var resumo = vendas
        .onde(coluna("valor").gt(lit(1000)))
        .com_coluna("mes", mes(coluna("data")))
        .agrupar(["cidade", "mes"])
        .agregar([soma("valor")])

    resumo.mostrar()
    resumo.para_parquet("saida.parquet")

    var painel = vendas.painel("Vendas")
    painel.kpi("Faturamento", coluna("valor").soma())
    painel.grafico(tipo="linha", x="mes", y=soma("valor"))
    painel.filtro("cidade")
    painel.abrir()
```

Por baixo: Expression → Logical Plan → Optimizer → Physical Plan → SIMD/Parallel/Streaming → Memory Engine.

---

## Suíte de benchmarks

Tucano × Polars × DuckDB × a biblioteca tabular mais usada em Python, de 1M a 1B linhas:

tempo, RAM, throughput, **startup**, scaling por cores, I/O

E, a partir do M7, a métrica que é nossa: **latência de filtro de painel** e **bytes de payload por interação**.

---

## Próximo passo

1. ~~Fechar **M0**~~
2. ~~**M1**: storage columnar (buffers + validity + strings)~~
3. ~~**M2**: Expression Engine (`coluna` / `lit` / plano lógico / `coletar`)~~
4. ~~**M2.5**: empacotar a biblioteca, remover `Tabela.indice`, NA de três valores, `DType.DATA`~~
5. ~~**M3**: executor coluna-a-coluna, `com_coluna()`, lazy por padrão~~
6. ~~**M4**: kernels SIMD sobre os slabs, dictionary encoding~~
7. ~~**M5**: scanner CSV tipado (bytes → buffers), streaming em fatias, datahora~~
8. ~~**M6**: groupby e join como operadores~~
9. ~~Decidir sobre `pyarrow` como dependência **de fixture** para destravar Parquet~~
10. Reavaliar paralelismo quando o stdlib do Mojo expuser primitiva estável
11. Quando houver canal conda: publicar com `recipe.yaml` e fechar o último item do M2.5
