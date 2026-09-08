# Roadmap Tucano

**Tese:** biblioteca tabular nativa em Mojo — **ergonomia direta, semântica de banco de dados, motor moderno de ponta a ponta**.

**Não é:** mais uma camada de conveniência sobre um modelo de dados frouxo.
**É:** usável no primeiro dia por quem já analisa dados, sem herdar os vícios que a prática consagrou.

Três objetivos, nesta ordem de dependência:

1. **Biblioteca instalável** — o usuário baixa, importa e analisa. Sem `-I .`, sem clonar repo.
2. **Análise tabular com verbos familiares** — `onde`, `selecionar`, `agrupar`, `unir`. Reconhecível em 5 minutos.

O terceiro objetivo original — **dashboard nativo via HTTP** — está **fora do caminho crítico**. O M7 existe como protótipo (`Painel`, JSON agregado, servidor sequencial sobre libc). Sem `std.net` no Mojo 1.0, continuar nisso é escrever servidor em vez de engine. Reavalia quando o stdlib expuser sockets.

```
API (eager na aparência)
  → Expression → Logical Plan → Optimizer → Physical Plan
  → SIMD / Parallel / Streaming → Memory Engine → CPU
```

Polars, DuckDB e DataFusion já cobrem DataFrame/SQL moderno. A oportunidade do Tucano é outra: **aproveitar Mojo 1.x (estável, Apache 2.0) do buffer ao kernel**, com especialização em compile-time, ownership explícito e um caminho curto do dado ao resultado.

---

## Por que existir: as armadilhas herdadas

A análise tabular em memória consagrou um conjunto de decisões que hoje custam caro. Isto não é decoração: cada linha abaixo é uma decisão de design do Tucano, tomada contra uma dessas heranças.

| Armadilha herdada | Custo real | Decisão do Tucano | Marco |
|---|---|---|---|
| **Index implícito com alinhamento automático** | `a + b` vira NaN silencioso; `reset_index()` em todo lugar | Sem index de rótulo. Join é sempre explícito | M2.5 |
| **NaN como único missing** | Int com 1 nulo vira `float64` e perde precisão | Validity bitmap separado do valor: Int64 continua Int64 com NA | ✅ M1 |
| **String = `object` dtype** | Um ponteiro Python por célula, zero vetorização | `StringStore` (offsets + bytes) + dictionary encoding — `cidade == "SP"` medido 4,2× | ✅ M1 / M4 |
| **View vs. copy indecidível** | `SettingWithCopyWarning`; ninguém sabe se mutou | Ownership do Mojo (`var` / `^` / `ref`) resolve em compile-time | ✅ grátis |
| **Eager sem plano** | Cada passo materializa um intermediário que ninguém pediu | Lazy por padrão + otimizador: filtro sobe, coluna não usada não é lida | ✅ M2 / M8 |
| **`apply(lambda)` 100x lento em silêncio** | O usuário nunca sabe que caiu do caminho rápido | Plano inspecionável + **aviso explícito ao sair do kernel vetorizado** | ✅ M3 |
| **~600 métodos, 5 formas de indexar** | `.loc`/`.iloc`/`.at`/`.iat`/`[]`, `apply`/`map`/`agg`/`transform` | **Uma forma por operação.** Sinônimos são recusados | permanente |
| **Coerção silenciosa de tipo** | Concat de tipos diferentes → `object` | Erro, nunca coerção implícita | ✅ prática atual |
| **Single-threaded (GIL)** | 1 core de 16 | SIMD por padrão (2–4,7× medido); paralelismo por chunk bloqueado no Mojo 1.0 | ✅ SIMD / ⛔ threads |
| **2–5x a RAM do dado** | `inplace=True` mente e copia mesmo assim | Moves explícitos, zero-copy onde couber | parcial |
| **`groupby.apply` com shape imprevisível** | O retorno muda conforme a função | Só agregações tipadas | M6 |
| **`KeyError: 'idade'` e nada mais** | Um typo custa 5 minutos | `coluna inexistente: 'idade'. Você quis dizer 'idades'?` | M2.5 |
| **Tudo precisa caber na RAM** | Morre em 50M linhas num laptop | Agregação em fluxo: pico proporcional ao número de grupos, não de linhas | ✅ M9 |
| **Viz = PNG estático ou reenviar o dataset** | Ferramentas de painel re-executam o script inteiro ou reenviam a tabela | **Widget guarda uma `Consulta`, não uma `Tabela`** — payload medido na própria página | ✅ M7 |

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

### 7. Frontend não é Mojo — estacionado

O M7 deixou o gráfico no navegador e o motor em Mojo, trocando JSON agregado. Isso continua válido como protótipo. **O servidor HTTP sobre libc não é o produto**: não há `std.net`, e o caminho crítico é o engine, não o socket. `json_painel()` / `json_dados()` continuam gerando o payload sem subir servidor.

---

## Métrica de sucesso

**Não é** "80% da API da biblioteca mais usada". **Nem** "ganhar do DuckDB em TPC-H" — isso levaria anos e não é onde o Tucano é diferente.

São três provas, em ordem de honestidade:

1. **Usabilidade** — um analista acostumado a bibliotecas tabulares resolve uma tarefa real (ler, filtrar, derivar coluna, agrupar, exportar) sem consultar documentação além do README.
2. **Query interativa** — filtro + agregação sobre 10M linhas responde em tempo de interação. Aqui pesam startup e replanejamento, onde binário AOT bate stack Python de verdade. (O filtro de painel via HTTP mediu isso no M7; a prova agora é o mesmo plano sem o servidor.)
3. **Escala** — suíte pública contra os engines tabulares de referência. **Feita e medida** — números abaixo.

### Onde o Tucano está (medido)

`pixi run bench-leitura` / `pixi run -e comparativo leitura` e `pixi run bench-comparativo` / `pixi run -e comparativo referencia-1t`. Mesmo arquivo Parquet, mesma pergunta, menor de três execuções. Uma thread contra uma thread.

O arquivo é o que o próprio Tucano escreve com o padrão de hoje: texto repetido em `RLE_DICTIONARY`, páginas em Snappy — 44 MiB.

| 5M linhas, uma thread | Tucano | pandas 3.0.5 | Polars | DuckDB |
|---|---|---|---|---|
| ler 5 colunas | 102 ms | **90 ms** | 31 ms | 5 ms |
| pipeline (filtro + groupby + 3 agregações) | **117 ms** | 224 ms | 134 ms | 89 ms |

No pipeline o Tucano é **1,9×** o pandas e **1,1×** o Polars em uma thread. Na leitura está **1,1× atrás** do pandas: descomprimir 124 MiB de saída custa ~40 ms que o pandas paga mais barato. Sem compressão o Tucano lê os mesmos dados em 60 ms — mas o padrão é comprimido, e é o padrão que se publica.

DuckDB em 16 threads faz o mesmo pipeline em 13 ms — essa distância é paralelismo, bloqueado no Mojo 1.0.

A tabela de 972 ms contra Polars/DuckDB (M10) e a de 230 ms contra pandas (M10.5) ficam nos marcos correspondentes: são o ponto de partida, não o estado.

---

## Estado atual do código (honestidade)

**M0 → M10.13 fechados, leitura .xlsx no M12.** Testes verdes, interoperabilidade verificada nos dois formatos e nos dois sentidos. Uma thread do Tucano está à frente do pandas no pipeline (1,9×) e do Polars em uma thread; na leitura pura está 1,1× atrás do pandas, custo da descompressão. SQL junta com `USING`, filtra grupos com `HAVING` e conta distintos. O escritor comprime páginas com Snappy. Planilha `.xlsx` abre como `Tabela`. O servidor HTTP do painel está estacionado.

Falta para o 1.0, e nada disso é questão de escopo:

| O que falta | Por quê |
|---|---|
| **Paralelismo por thread** | Fechado por construção no Mojo 1.0 — a linguagem proíbe o apagamento de origem que um payload de thread exige. É o que ainda separa o Tucano do DuckDB em 16 núcleos. Detalhes no M4. |
| **Publicação em canal conda** | `recipe.yaml` está pronto; falta um canal (prefix.dev ou equivalente). Decisão de projeto. |
| **Slab de data em Int32** | Dívida rastreada com gatilho explícito — ver abaixo. |

GPU (M11) e o servidor HTTP do painel (M7) seguem fora do caminho crítico. Escrita de Excel fica para depois da leitura.

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
| Painel: KPI, gráfico, tabela, filtro | ⏸ M7 — protótipo, fora do caminho |
| Servidor HTTP sobre libc (`external_call`) | ⏸ M7 — estacionado; não há `std.net` |
| Otimizador: dobra, fusão, empurrão, poda | ✅ M8 |
| Varredura Parquet adiada + pushdown de colunas | ✅ M8 — 1,9× |
| Leitura por faixa (`pread`) e por row group | ✅ M9 |
| Agregação em fluxo, memória limitada | ✅ M9 — pico 0,6% do arquivo |
| Escrita em múltiplos row groups | ✅ M9 |
| SQL sobre o mesmo planner | ✅ M10 |
| Arrow IPC: leitura e escrita, interop verificada | ✅ M10 |
| Suíte comparativa pública | ✅ — números publicados, inclusive os desfavoráveis |
| Escritor `RLE_DICTIONARY` em texto | ✅ M10.6 — 245 → 124 MiB |
| `pread` sem zerar; RLE em `Int32`; gather numérico | ✅ M10.6 |
| Filtro compacta o slab; agregação sem `extrair_coluna` | ✅ M10.6 |
| Mais rápido que pandas no pipeline (1,9×) | ✅ M10.6 |
| Decodificador Snappy sem cópia byte a byte | ✅ M10.12 |
| Estatísticas min/max no row group + predicate pushdown | ✅ M10.7 |
| `distinct_count` + hash join no lado mais barato | ✅ M10.8 |
| SQL `JOIN` / `LEFT JOIN` com `USING` | ✅ M10.9 |
| Escritor emite Snappy | ✅ M10.10 |
| SQL `HAVING` + `COUNT(DISTINCT)` | ✅ M10.11 |
| Leitura `.xlsx` | ✅ M12 |
| SQL `SELECT DISTINCT` | ✅ M10.13 |
| Paralelismo por chunk | ❌ **bloqueado** — fechado por construção no Mojo 1.0 |
| Slab de data em Int32 | ⏸ dívida rastreada — ver abaixo |
| Publicação em canal conda | ❌ exige canal próprio |

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
| M7 | Painel (HTTP) | baixa | ⏸ estacionado | protótipo; sem `std.net` não é produto |
| M8 | Optimizer | crítica | ✅ feito | pushdown + folding + reorder |
| M9 | Out-of-Core | alta | ✅ feito | datasets > RAM |
| M10 | Interop | alta | ✅ feito | Arrow (sem Python) + SQL |
| M10.5 | Desperdício do leitor | crítica | ✅ feito | 1112 → 230 ms |
| M10.6 | Passar o pandas | crítica | ✅ feito | medido sem compressão |
| M10.7 | Predicate pushdown | crítica | ✅ feito | min/max no rodapé; pula row group |
| M10.8 | distinct_count + join | crítica | ✅ feito | NDV no rodapé; hash no lado barato |
| M10.9 | SQL JOIN | crítica | ✅ feito | `USING` sobre o mesmo `unir` |
| M10.10 | Snappy na escrita | crítica | ✅ feito | páginas comprimidas por padrão |
| M10.11 | SQL HAVING + COUNT(DISTINCT) | crítica | ✅ feito | mesmo `onde` / `distintos` |
| M12 | Excel (leitura) | alta | ✅ feito | `ler_xlsx`, primeira aba ou pelo nome |
| M10.12 | Snappy sem cópia byte a byte | crítica | ✅ feito | leitura 259 → 102 ms |
| M10.13 | SQL SELECT DISTINCT | crítica | ✅ feito | o mesmo `agrupar`, sem operador novo |
| M11 | GPU | experimental | não iniciado | aceleradores selecionados |
| M12b | Excel (escrita) | baixa | não iniciado | compatibilidade tardia |

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
M6 Aggregation + Join
 ↓
M8 Optimizer
 ↓
M9 Out-of-Core
 ↓
M10 Interop (Arrow / SQL)
 ↓
M10.5 Desperdício do leitor
 ↓
M10.6 Passar o pandas
 ↓
M10.7 Predicate pushdown
 ↓
M10.8 distinct_count + reordenação de junção
 ↓
M10.9 SQL JOIN
 ↓
M10.10 Snappy na escrita
 ↓
M10.11 SQL HAVING + COUNT(DISTINCT)
 ↓
M12 Excel leitura (`.xlsx`)
 ↓
Tucano 1.0
   └── M11 GPU [experimental]   escrita Excel [depois]
       M7 Painel HTTP [estacionado]
```

**Por que o Optimizer veio depois da agregação:** é ele que transforma "plano que funciona" em "plano que não lê coluna inútil nem ordena o que vai embora". O painel HTTP (M7) ficou no meio da linha do tempo porque existia; **não é mais o caminho** — ver M7.

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

### Paralelismo — bloqueado, e agora se sabe por quê

**O stdlib do Mojo 1.0 não expõe `parallelize`.** `TaskGroup` e `create_task` existem em
`std.runtime.asyncrt`, mas um `TaskGroup()` destruído sem uso já aborta o processo
(`destroying a non-available AsyncValue isn't implemented`).

Com `external_call` funcionando bem em outros pontos (sockets no M7, `pread` no M9), a rota
óbvia era pthreads direto. **E ela chega surpreendentemente longe:** `pthread_create` aceita
um ponteiro de função produzido pelo Mojo e devolve 0.

O que fecha a porta é outra coisa, e é uma decisão de linguagem, não uma lacuna de
biblioteca:

```
error: struct fields cannot expose AnyOrigin in their type
```

Um payload de thread ao estilo C é um `void*` — um ponteiro com a origem apagada. O Mojo 1.0
**proíbe deliberadamente** guardar um ponteiro de origem apagada num campo de struct, que é
exatamente o que marshalar parâmetros para uma thread exige. Não há como contrabandear os
ponteiros para dentro da thread sem furar a regra que existe justamente para impedir isso.

Ou seja: não é falta de esforço nem de primitiva conveniente. **Paralelismo de dados em
espaço de usuário está fechado por construção no Mojo 1.0**, e a saída tem de vir de uma
primitiva de primeira classe. É isso que se espera do compilador — e enquanto não vem, a
suíte comparativa mede exatamente quanto isso custa: de metade a dois terços da distância
para os engines de referência.

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

> Feito no M10: ambiente `comparativo` com Polars, DuckDB e pandas, separado do runtime.

---

## M7 — Painel ⏸

**Fora do caminho crítico.** O marco está fechado como protótipo: o widget guarda uma
`Consulta`, o payload é JSON agregado, e isso continua verdadeiro. O servidor HTTP
sobre libc **não** é o produto. Sem `std.net`, investir mais aqui é escrever servidor em
vez de engine. O código permanece; `json_painel()` / `json_dados()` geram o payload sem
subir socket. Reavalia quando o stdlib expuser sockets.

O dashboard como camada da biblioteca, não como ecossistema à parte.

### O widget guarda uma consulta, não uma tabela

É a diferença que decide a arquitetura. Mexer num filtro **muda o plano** e reexecuta; o navegador recebe o resultado agregado. Um gráfico de doze meses recebe doze pontos, mesmo que a fonte tenha milhões de linhas.

E o rodapé da página mostra quantos bytes de fato atravessaram — a afirmação fica verificável, não apenas dita:

```
3.000 linhas na fonte · 1.000 após os filtros · 2.331 bytes trafegados
```

```mojo
var p = Painel("Vendas", vendas)
p.kpi("Faturamento", soma("valor"))
p.grafico("Por cidade", "cidade", soma("valor"), "barra")
p.tabela("Detalhe", ["data", "cidade", "valor"], 50)
p.filtro("cidade")
p.servir(8080)
```

### O risco registrado se confirmou — e teve saída

O roadmap avisava: *"se ainda não existe stack HTTP na stdlib do Mojo 1.0, você acaba escrevendo servidor HTTP em vez de executor"*. Não existe — não há `std.net`, não há sockets.

Mas há `external_call` em `std.ffi`, e com ele a libc inteira: `socket`, `bind`, `listen`, `accept`, `recv`, `send`, `close`. O servidor cabe em 200 linhas, é sequencial de propósito, e **não desviou o projeto**: nenhuma linha do executor mudou por causa dele.

> Armadilha do caminho: `read` e `write` já são declarados pelo stdlib com outra assinatura, e a redeclaração não chega a linkar. `recv` e `send` — que são os próprios de socket — resolvem.

### Frontend embutido, sem CDN

Página única servida pela própria biblioteca. Os gráficos são **SVG desenhado à mão em JavaScript**, sem biblioteca de terceiros: o painel roda em rede local ou sem rede nenhuma, e uma dependência externa quebraria isso. Um teste garante que a página não contém nenhuma URL.

Barras, linha e pizza; tema claro e escuro pelo `prefers-color-scheme`; números formatados em pt-BR; ausente aparece como `—`, nunca como zero.

### Escopo mantido magro

KPI, gráfico, tabela, filtro. Nada além disso — como o marco prometia. Eixo derivado (mês, ano) sai de `com_coluna` antes do painel: não há uma segunda linguagem só para o dashboard.

O eixo do gráfico sai **ordenado**. Um gráfico na ordem de aparição dos grupos não é um gráfico, é um sorteio.

### Critério de saída

- [x] `servir()` sobe servidor e a página abre no navegador
- [x] KPI, gráfico, tabela e filtro funcionando
- [x] Filtro recalcula o plano e reenvia só o agregado
- [x] Payload medido e exibido na própria página
- [x] Sem dependência externa no frontend
- [x] 137 testes verdes

---

## M8 — Query Optimizer ✅

O plano lógico diz **o que** o usuário quer. Nada nele obriga a executar naquela ordem, e é essa folga que o otimizador aproveita.

### Quatro regras, todas conservadoras

| Regra | O que faz |
|---|---|
| **dobra de constantes** | `lit(2) * lit(3)` vira `lit(6)` uma vez, em vez de uma multiplicação por linha |
| **fusão de filtros** | filtros seguidos viram um `E`, numa passada só |
| **empurrão de filtro** | o filtro sobe no plano, para que ordenação e colunas derivadas trabalhem sobre menos linhas |
| **poda de colunas** | o que o plano não usa não é lido — sobre arquivo, isso vira menos I/O de verdade |

Uma regra que às vezes muda o resultado não é otimização, é defeito. Por isso o empurrão é conservador: passa por ordenação e projeção, para por causa da coluna que o filtro lê, e **nunca** atravessa agregação, junção, concatenação ou preenchimento — filtrar antes de agregar é outra pergunta, não a mesma mais rápida.

### Ganhos medidos

`pixi run bench-m8`, 500 mil linhas em 5 colunas:

| | sem otimizar | otimizado | ganho |
|---|---|---|---|
| agrupar sobre Parquet (lê 2 de 5 colunas) | 288 ms | **152 ms** | **1,90×** |
| ordenar e filtrar (25k de 500k linhas) | 351 ms | **30 ms** | **11,5×** |

O segundo caso é o retrato do problema: ordenar 500 mil linhas para depois jogar fora 95% delas. O plano escrito diz isso; o plano executado não precisa obedecer.

### A prova que autoriza otimizar

`coletar_sem_otimizar()` executa o plano como escrito. Existe para duas coisas: medir o ganho, e **provar que o otimizador não mudou a resposta**. Os testes comparam os dois caminhos linha a linha.

### Varredura adiada

`varredura_parquet(caminho)` devolve uma `Consulta` cuja fonte é o **arquivo**, não um lote já lido. O arquivo só é aberto no `coletar()` — depois que o otimizador decidiu quais colunas o plano usa. É o que transforma poda de colunas em menos I/O em vez de menos cópia.

```
LOGICO     SCAN -> AGGREGATE [grupo] -> [soma(valor)] -> RESULT
OTIMIZADO  SCAN -> AGGREGATE [grupo] -> [soma(valor)] -> RESULT
FONTE      parquet vendas.parquet
COLUNAS    2 de 5 [valor, grupo]
REGRAS     poda de colunas (5 -> 2)
```

### O painel também poda

O painel sabe quais colunas seus widgets leem antes de executar, então a projeção entra no plano e o resto nem é materializado. Sobre **10 milhões de linhas**:

| | tempo | payload |
|---|---|---|
| painel sem filtro | 887 ms | 980 bytes |
| painel com filtro | **186 ms** | 336 bytes |

Com filtro é mais rápido que sem: o filtro reduz as linhas antes das agregações. É o critério de "tempo de interação" cumprido com número.

### Critério de saída

- [x] Planos antes/depois inspecionáveis (`explicar()`)
- [x] Pushdown demonstrável em Parquet — 1,9×, com as colunas lidas listadas
- [x] Menos I/O e menos colunas lidas nos benches
- [x] Filtro de painel sobre 10M linhas em tempo de interação — 186 ms
- [x] Equivalência otimizado × não otimizado verificada em teste
- [x] 151 testes verdes
- [x] Reordenação de junção — hash no lado de menor custo (NDV da chave dicionarizada, ou `n_linhas`). Junção à esquerda não inverte.

> Reordenar junções exige saber o tamanho de cada lado. `distinct_count` no rodapé (M10.8) e a cardinalidade em memória da chave dicionarizada escolhem o lado da hash sem adivinhar. **Próximo item com retorno:** publicação em canal conda, quando houver canal.

---

## M9 — Out-of-Core / Streaming Execution ✅

Agregar não exige ter tudo em memória: exige carregar o **estado dos grupos**, que é pequeno, e passar os dados por ele uma fatia de cada vez.

```
fatia -> filtro / coluna derivada -> estado dos grupos
                                           |
                                     (a fatia é liberada)
```

### Medido

`pixi run bench-m9`, 1 milhão de linhas em 5 colunas, arquivo de 72 MB em 40 row groups:

| | tempo | pico de memória |
|---|---|---|
| de uma vez | 416 ms | as colunas inteiras |
| em fluxo | 442 ms | **467 KiB** — um row group |

**0,6% do arquivo**, por 6% a mais de tempo. E os dois caminhos dão exatamente o mesmo resultado, verificado em teste.

### `Path.read_bytes()` derrota o propósito

Não adianta processar em fatias se a leitura já estourou a memória. `tucano/arquivo.mojo` lê **por faixa**, via `pread` da libc: abre uma vez, lê só o pedaço pedido, e o resto do arquivo nunca entra em memória. `metadados_parquet` passou a usar isso — dá para inspecionar o esquema de um arquivo maior que a RAM.

`VarreduraParquet` lê **row group por row group**, e cada pedaço de coluna na sua própria faixa de bytes: as colunas não pedidas nunca saem do disco.

> Terceira vez que a mesma armadilha aparece: `open`, como `read` e `write`, já é declarado pelo stdlib com outra assinatura, e a redeclaração não chega a linkar. `open64`, `lseek64` e `pread64` são os mesmos pontos de entrada sem a colisão.

### O que atravessa fatias precisa ser combinável

Soma de somas é soma; mínimo de mínimos é mínimo. Média não combina, mas soma e contagem combinam, e a divisão fica para o fim.

`distintos` **não** combina sem guardar todos os valores vistos — e por isso é recusado no fluxo, em vez de fingir que cabe. Ordenação e junção também precisam do conjunto inteiro: o plano é recusado com essa explicação, não executado pela metade.

```
> plano com ordenacao pode fluir?
ordenacao precisa do conjunto inteiro — use coletar()
```

### Escrita em row groups

`para_parquet(tabela, caminho, linhas_por_grupo)` divide o arquivo. Grupos menores dão pico menor na leitura em fluxo. A interoperabilidade continua verificada — com row groups de duas linhas, inclusive.

### Critério de saída

- [x] Pipeline bounded-memory em pelo menos um workload — filter + groupby + agregações
- [x] Leitura por faixa: o arquivo nunca é carregado inteiro
- [x] Pico medido: 467 KiB sobre arquivo de 72 MB
- [x] Equivalência fluxo × execução inteira verificada em teste
- [x] Escrita em múltiplos row groups, com interop confirmada
- [x] 162 testes verdes
- [ ] Spill-to-disk para ordenação — **fora por ora**

> Ordenação em memória limitada exige mesclagem externa com escrita temporária em disco. É um marco por si só, e ordenar não é o gargalo dos workloads que motivam out-of-core — agregar é. Entra quando houver demanda concreta.

---

## M10 — Interoperabilidade ✅

### SQL sobre o mesmo planner

Não há um segundo motor. O `SELECT` vira exatamente as mesmas etapas que a API fluente produz:

```sql
SELECT grupo, SUM(valor) AS total
FROM 'vendas.parquet'
WHERE valor > 100
GROUP BY grupo
ORDER BY total DESC
```

```
LOGICO     SCAN -> FILTER (coluna(valor) > lit(100)) -> AGGREGATE [grupo] -> [soma(valor)]
                -> PROJECT [grupo, total] -> SORT [total desc] -> RESULT
COLUNAS    2 de 3 [grupo, valor]
REGRAS     poda de colunas (3 -> 2)
```

**Isso é um teste da arquitetura, não só um recurso.** Se o plano não fosse um valor manipulável, SQL exigiria um interpretador separado. Como é, o SQL ganha de graça a poda de colunas, o empurrão de filtro e a varredura adiada de Parquet.

Suportado: `SELECT` com colunas e agregações (`SUM`, `AVG`, `COUNT`, `COUNT(DISTINCT)`, `MIN`, `MAX`) e `AS`; `FROM` arquivo ou tabela registrada num `Catalogo`; `JOIN` / `LEFT JOIN` com `USING (colunas)`; `WHERE` com comparações, `AND`/`OR`/`NOT` e parênteses; `GROUP BY`; `HAVING`; `ORDER BY` com `ASC`/`DESC`; `LIMIT`. Erros apontam a posição no texto.

Dois cuidados de semântica: `ORDER BY` por apelido ordena depois da projeção, e por coluna descartada ordena antes — as duas formas funcionam sem o usuário saber a ordem interna das etapas. E coluna no `SELECT` fora do `GROUP BY` é recusada com a explicação, em vez de escolher um valor arbitrário do grupo.

### Arrow IPC, nos dois sentidos

O Parquet já dava interoperabilidade, mas em disco e comprimido. O Arrow é a forma **em memória**: os buffers do arquivo IPC têm exatamente o layout que outra implementação usa em RAM, então a leitura do outro lado é um mapeamento, não uma conversão.

Escrever um arquivo Arrow exige escrever um FlatBuffer primeiro — `tucano/flatbuf.mojo` faz isso, construindo o buffer de trás para frente como o formato manda.

**A verificação é dos dois lados**, e é o que dá sentido ao marco:

| | verificação |
|---|---|
| escrita | `pixi run -e fixtures interop-arrow` lê com outra implementação tudo que o Tucano escreveu |
| leitura | as fixtures `.arrow` são **escritas por outra implementação** — ler o próprio arquivo não prova nada |

Cobertos: inteiro, real, lógico, texto, `date32[day]`, `timestamp[us]`, ausentes, e lotes de 3 mil linhas.

> **A validade é invertida.** No Arrow, bit 1 significa *presente*; no Tucano, o bitmap marca o *ausente*. Trocar isso é uma linha, e esquecer disso é um arquivo em que todo valor vira nulo — sem erro nenhum, só dados errados.

Três armadilhas de FlatBuffer que custaram tempo e ficam registradas: o `soffset` da vtable mora no **início** da tabela (escrevê-lo no fim põe os bytes antes da vtable); o alinhamento da string tem de contar o terminador; e o `finish` alinha pelo maior alinhamento usado, não por 4.

### Critério de saída

- [x] Export/import Arrow, com interoperabilidade verificada nos dois sentidos
- [x] Dialeto SQL mínimo sobre o mesmo planner
- [x] 184 testes verdes
- [ ] Zero-copy de verdade (Arrow C Data Interface) — **fora por ora**

> O C Data Interface passa ponteiros entre bibliotecas no mesmo processo. Não há como verificá-lo aqui: exigiria um consumidor C ou Python vivo no mesmo processo, e o princípio de Zero Python fecha essa porta. O IPC entrega a interoperabilidade; o zero-copy entra quando houver um consumidor real para provar contra.

---

## M10.5 — Leitura de Parquet: tirar o desperdício ✅

Medir contra Polars e DuckDB (M10) produziu o primeiro número desconfortável do
projeto: ler 5 milhões de linhas × 5 colunas — 245 MiB — custava **1112 ms**,
contra 84 ms da biblioteca tabular mais usada em Python e 33 ms do Polars. Treze
vezes mais lento que o alvo que o projeto se propõe a substituir.

A tentação era responder com "falta paralelismo". Não faltava: a máquina é a
mesma, o arquivo é o mesmo, e o número mede uma thread contra uma thread. O que
havia era desperdício — e paralelizar código que copia o arquivo três vezes só
faz oito núcleos desperdiçarem juntos.

### O piso físico, medido antes de qualquer mudança

Antes de otimizar, medir o que a máquina cobra. Nos mesmos 244 MiB:

| | |
|---|---|
| `pread` do arquivo inteiro | 78 ms (3,2 GB/s, em cache) |
| `memcpy` de 244 MiB | 46 ms (5,5 GB/s) |

Isso fecha a pergunta "dá para chegar a 9 ms como o DuckDB?": não, não numa
thread que materializa os dados. Mas mostra que **1112 ms eram 14× o piso**, e
essa distância é desperdício, não física.

### As seis fontes, e o que cada uma custava

| | efeito |
|---|---|
| `Path.read_bytes()` lia o arquivo **inteiro**, mesmo com column pruning | 1112 → 721 |
| páginas sem compressão copiadas **byte a byte** em vez de `memcpy` | (junto com a anterior) |
| níveis de definição expandidos a um `Int` por linha para descobrir "nenhum ausente" | 721 → 690 |
| PLAIN de INT64/DOUBLE montado com **oito deslocamentos por valor** | 690 → 496 |
| dicionário de bytes num `Dict` de listas encadeadas, consultado uma vez por linha | (junto com a anterior) |
| slab da coluna **copiado** do acumulador em vez de assumido | 496 → 286 |

E, depois, duas afiações no que sobrou: hash e comparação de bytes de 8 em 8, já
que essas são as operações feitas exatamente uma vez por linha do arquivo.

### Resultado

| 5M linhas × 5 colunas, 245 MiB | antes | depois | |
|---|---|---|---|
| ler tudo | 1112 ms | **230 ms** | 4,8× |
| ler 2 de 5 colunas | 568 ms | **103 ms** | 5,5× |

A distância para a biblioteca de referência caiu de **13,9× para 2,7×**; no caso
podado, de 16× para 2,9×. Do que resta, 78 ms são o `pread` — 34% do total é a
leitura física, não o decodificador.

### `resize` não é `reserve`

O primeiro `memcpy` deixou a leitura **duas vezes mais lenta** (831 → 1519 ms).
`resize` para o tamanho exato a cada row group realoca a cada grupo, e a cópia
acumulada vira quadrática no número deles: 50 grupos moveram 10 GiB à toa. O
rodapé do Parquet já diz quantas linhas o arquivo tem — reservar uma vez elimina
toda realocação. Fica registrado porque a lição é geral: trocar `append` por
cópia em bloco só ganha se a capacidade estiver garantida antes.

O mesmo vale para `resize(n, 0)` antes de um `memcpy`: escreve 40 MiB de zeros
para sobrescrevê-los. `resize(unsafe_uninit_length=n)` é o par certo da cópia.

### Um bug que só aparecia lendo por faixa

Tornar os deslocamentos relativos ao pedaço de coluna revelou que
`tem_dicionario()` usava `offset > 0` como sentinela de ausência. Quando a página
de dicionário abre o pedaço, o deslocamento relativo é exatamente **zero** — e a
coluna passava a ser lida como se não tivesse dicionário.

O defeito já existia na `VarreduraParquet` desde o M9, latente: nenhum teste lia
um arquivo dicionarizado **por faixa**. O caso está coberto agora
(`test_m8_varredura_le_dicionarizado`), e a sentinela virou `-1`.

### O que ficou de fora, e por quê

Na época, o escritor ainda emitia texto em **PLAIN**, não `RLE_DICTIONARY`. São 5 milhões de
cópias de 24 valores distintos no arquivo — o leitor precisava dicionarizar todos
de volta, e era isso que fazia as colunas de texto custarem 152 dos 230 ms. Ficou
de fora de propósito: mudança de escritor, com risco de formato próprio, não entra
junto com mudança de leitor. **Feito no M10.6.**

Paralelismo continua fora: `pthread_create` funciona via FFI, mas a regra de
posse do Mojo (`struct fields cannot expose AnyOrigin in their type`) impede
carregar as estruturas do Tucano por thread. `fork()` foi testado e funciona,
com custo de ~9,4 ms por processo em espaço de 320 MB — mas uma biblioteca que
bifurca processo sem o usuário pedir é surpresa, não recurso.

### Critério de saída

- [x] leitura lê só as faixas das colunas pedidas, nunca o arquivo inteiro
- [x] nenhuma cópia byte a byte no caminho quente
- [x] slab da coluna assumido, não copiado
- [x] 185 testes verdes, ida e volta e interoperabilidade nos dois formatos
- [x] ganho medido, não estimado: 4,8× em leitura completa, 5,5× com poda

---

## M10.6 — Passar o pandas, no mesmo arquivo ✅

O M10.5 tirou desperdício do leitor e deixou o Tucano 2,7× atrás do pandas na
leitura. O que restava não era mais cópia byte a byte: era o arquivo gordo que
nós mesmos escrevíamos (texto em PLAIN) e o filtro/groupby ainda copiando
linha a linha.

### Conceitos que entram no caminho quente

**Escritor `RLE_DICTIONARY`.** Coluna de texto já dicionarizada emite página de
dicionário (PLAIN dos distintos) e página de dados com índices em RLE/bit-packing
híbrido. Alta cardinalidade continua PLAIN. O arquivo de 5M caiu de 245 MiB para
124 MiB, e qualquer leitor ganha — pyarrow lê e concorda valor a valor.

**`pread` sem zerar.** `LeitorArquivo` fazia `append(0)` em cada byte e só depois
chamava `pread64`. `resize(unsafe_uninit_length=n)` é o par do `pread`, como já
era o par do `memcpy`.

**RLE em `Int32`.** O decoder antigo devolvia `List[Int]` (8 bytes por índice) e
um segundo laço estreitava. `preencher_rle_i32` escreve no slab da coluna;
`remapeia_i32` troca o índice local da página pelo código global, in-place.

**Gather numérico.** Arquivo bem encodado (o do mundo) deixava o Tucano *mais
lento* que o PLAIN gordo, porque `_valores_do_dicionario` + `_emitir` expandiam
valor a valor. Agora o dicionário é uma tabela pequena e cada linha é um gather
para o slab.

**Filtro sem `append` por linha.** Sem ausentes, compacta o slab por ponteiro.
Groupby dicionarizado e agregação real sem nulo escrevem no destino reservado —
saem `eh_ausente` por linha e `extrair_coluna` (uma cópia inteira por agregação).

### Resultado, uma thread, medido

| 5M linhas | Tucano | pandas 3.0.5 | |
|---|---|---|---|
| ler 5 colunas | **62 ms** | 108 ms | **1,7×** |
| pipeline (filtro + groupby + 3 agregações) | **97 ms** | 228 ms | **2,4×** |

> Medido no arquivo **sem compressão** de 124 MiB, que era o padrão da escrita
> quando o M10.6 fechou. O M10.10 ligou Snappy por padrão e a leitura mudou de
> lado — ver M10.12, que é o conserto e a medição refeita.

No mesmo pipeline, Polars em uma thread faz 109 ms. DuckDB em uma thread faz
58 ms; em 16 threads, 15 ms — essa distância é paralelismo.

Critério de saída:

- [x] escritor emite `RLE_DICTIONARY` em texto com repetição
- [x] pyarrow lê os arquivos novos e concorda
- [x] 187 testes verdes
- [x] Tucano mais rápido que pandas na leitura e no pipeline, medido

---

## M10.7 — Predicate pushdown por min/max ✅

O M8 empurra o filtro para cima do plano e poda colunas. O I/O ainda lia **todo**
row group das colunas pedidas, mesmo quando nenhum valor do grupo podia
satisfazer `valor > 150`. O rodapé do Parquet já reserva campo para isso
(`Statistics` no `ColumnMetaData`); o Tucano não emitia nem lia.

### Conceitos

**Escritor emite min/max.** Cada pedaço numérico (inteiro, real, data, datahora)
grava `max_value` / `min_value` em PLAIN no encoding do tipo físico. Ausente não
entra na faixa. Texto e lógico ficam sem estatística — pular exigiria ordem de
bytes, e o ganho não paga o risco.

**Leitor interpreta o campo 12.** Arquivo nosso ou de outro escritor. Sem
estatística, o grupo é lido: a regra é conservadora, nunca muda o resultado.

**Poda de row group.** Predicado `coluna op literal` (e `E`/`OU` disso) contra
min/max. `max <= lit` descarta o grupo em `>`; o restante é simétrico. `!=` só
descarta quando min = max = lit. Qualquer outra forma (aritmética, extrator,
coluna derivada) não pula. O operador de filtro **continua no plano**: pular
grupo é I/O, não substitui a seleção.

O banco de 5M do comparativo **não** pula grupo (`valor > 1000` com
`(i%9973)*1.5` mistura a faixa em cada um). A vitória é arquivo real com
clustering — e a mesma leitura que a reordenação de junção passou a usar no M10.8.

### Critério de saída

- [x] escritor emite min/max em coluna numérica
- [x] leitor parseia estatística própria e de terceiros
- [x] `coletar()` e `coletar_em_fluxo()` pulam o grupo impossível
- [x] sem estatística ou predicado complexo, lê o grupo
- [x] resultado idêntico ao de ler tudo
- [x] 189 testes verdes

---

## M10.8 — `distinct_count` e reordenação de junção ✅

O M8 deixou a reordenação de junção de fora: sem cardinalidade da chave, escolher
qual lado hashear seria adivinhar. Min/max (M10.7) não responde isso. O Parquet
já reserva o campo (`Statistics.distinct_count`); o Tucano não emitia nem lia.

### Conceitos

**Escritor emite NDV do row group.** Coluna de texto dicionarizada grava o número
de códigos **presentes no pedaço**, não o tamanho do dicionário herdado da fatia
(que pode ter valores que este grupo não usa). Numérico e texto PLAIN ficam sem
`distinct_count`.

**Leitor interpreta o campo 4.** Arquivo nosso ou de outro escritor. `-1` é
ausência, não zero distintos.

**Hash join interno escolhe o lado.** Custo = cardinalidade da chave dicionarizada
quando ela é menor que `n_linhas`; senão, `n_linhas`. `pequena.unir(grande)` hasheia
a pequena. Junção à esquerda **não** inverte: toda linha da esquerda precisa ser
sondada para sobreviver sem par. A ordem das colunas no resultado continua
esquerda-depois-direita.

### Critério de saída

- [x] escritor emite `distinct_count` em coluna dicionarizada
- [x] NDV é o do row group, não o do dicionário herdado
- [x] join interno hasheia o lado mais barato; resultado equivalente
- [x] join à esquerda não perde linha sem par
- [x] 192 testes verdes

---

## M10.9 — SQL JOIN ✅

O dialeto SQL do M10 cobria filtro, agregação e ordenação. `unir` já era operador
de primeira classe; o `SELECT` não juntava. Uma forma só, a mesma do `unir`: chaves
com o mesmo nome nos dois lados.

```sql
SELECT cidade, estado
FROM vendas
JOIN cidades USING (cidade)

SELECT cidade, estado
FROM vendas
LEFT JOIN cidades USING (cidade)
```

`ON expressao` é recusado: o Tucano não junta por predicado arbitrário. `RIGHT JOIN`
também — inverta as tabelas ou use `LEFT JOIN`. O plano é o mesmo `JOIN interno por
[cidade]` da API fluente, então o hash no lado mais barato (M10.8) vale aqui também.

### Critério de saída

- [x] `JOIN` / `INNER JOIN` / `LEFT JOIN` com `USING (colunas)`
- [x] vira `unir`; o plano mostra a junção
- [x] `ON` e `RIGHT JOIN` recusados com explicação
- [x] 197 testes verdes

---

## M10.10 — Snappy na escrita ✅

O leitor já descomprimia Snappy (arquivo de terceiro). O escritor emitia página
crua: o arquivo nosso saía maior do que o mesmo dado escrito por outro engine, e
a ida e volta com compressão não era nossa.

Uma forma: Snappy por padrão, o codec que o Parquet usa na prática. `compressao="nenhuma"`
desliga. Encoder e decoder são o mesmo formato cru (varint + literais/copias), em
`tucano/codecs.mojo`. Cabeçalho da página leva tamanho descomprimido e comprimido;
o chunk no rodapé também.

### Critério de saída

- [x] encoder round-trip com o decoder próprio
- [x] `para_parquet` emite Snappy por padrão; `"nenhuma"` continua
- [x] pyarrow lê o arquivo comprimido
- [x] 199 testes verdes

---

## M10.11 — SQL HAVING e COUNT(DISTINCT) ✅

O executor já filtrava depois de agregar (`agrupar.agregar.onde`) e já contava
distintos (`distintos(coluna)`). O dialeto SQL parava no `GROUP BY`. `HAVING` e
`COUNT(DISTINCT)` são o mesmo plano, não um segundo interpretador.

```sql
SELECT cidade, SUM(valor) AS total
FROM vendas
GROUP BY cidade
HAVING SUM(valor) > 1000
```

`HAVING SUM(valor)` reescreve para a coluna de saída (`total` se houver `AS`, senão
`soma_valor`). Agregação só no `HAVING` entra como extra, filtra, e a projeção descarta.
`SELECT grupo FROM t GROUP BY grupo HAVING COUNT(*) > 1` é válido. `HAVING` sem agregação
e sem `GROUP BY` é recusado. `COUNT(DISTINCT *)` também.

### Critério de saída

- [x] `HAVING` depois de `GROUP BY` (ou sobre agregação total)
- [x] `COUNT(DISTINCT coluna)` no SELECT e no HAVING
- [x] extra do HAVING não vaza na projeção
- [x] 205 testes verdes

---

## M10.12 — Snappy: o padrão não estava medido ✅

O M10.10 ligou Snappy por padrão na escrita. A mensagem do commit dizia, com
razão, que "o leitor já descomprimia" — e ninguém remediu a leitura depois.

| mesmo dado, 5M × 5 colunas | arquivo | ler tudo |
|---|---|---|
| `compressao="nenhuma"` | 124 MiB | 62 ms |
| `compressao="snappy"` (padrão) | 43 MiB | **264 ms** |

Os 62 ms do M10.6 reproduzem exatos — mas só no arquivo sem compressão. Com o
padrão de hoje a leitura custava 4,3× mais, e a afirmação publicada de "1,7× à
frente do pandas" tinha deixado de valer sem que nenhum teste reclamasse: testes
verificam correção, e o arquivo estava correto.

### O mesmo desperdício, de novo

`descomprimir_snappy` montava a saída com `out.append(bytes[pos + i])` — um byte
por iteração, com verificação de capacidade junto. É o mesmo laço que o M10.5
tirou de `_descomprimir`, sobrevivendo no codec ao lado.

O tamanho descomprimido vem no preâmbulo do próprio formato, então a saída é
alocada **uma vez** e escrita por ponteiro. Literal vira cópia em bloco.

### A cópia para trás não é um `memcpy`

E não pode ser: quando as faixas se sobrepõem, a leitura tem de enxergar o que
ela mesma acabou de escrever — é dessa sobreposição que sai a repetição. Mas a
partir de 16 bytes de distância um bloco de 16 nunca lê byte que ele próprio vai
escrever, e aí a cópia anda larga. Abaixo disso, byte a byte, porque a semântica
exige.

A análise de exclusividade do Mojo recusa o mesmo ponteiro nos dois lados de um
`memcpy`, o que fecha a porta para a saída errada por acidente.

`test_pq_snappy_copia_larga` monta fluxos Snappy **à mão** — o compressor não
deixa escolher a distância, e a distância é justamente o que separa os dois
caminhos. Cobre 15 contra 16 e comprimentos que não fecham em 16.

### Resultado

| 5M × 5 colunas, 44 MiB | antes | depois |
|---|---|---|
| ler tudo | 264 ms | **102 ms** |
| ler 2 de 5 colunas | 97 ms | **46 ms** |
| pipeline (filtro + groupby + 3 agregações) | 220 ms | **117 ms** |

Contra pandas em uma thread: pipeline **1,9×** mais rápido; leitura pura **1,1×
mais lenta** — descomprimir 124 MiB de saída custa ~40 ms, e é isso que separa
os 102 ms dos 60 ms do arquivo cru. O número desfavorável fica publicado.

### O que isso ensina sobre a suíte

Mudar um **padrão** é mudar o que todo usuário mede. A suíte comparativa roda por
tarefa separada e ninguém a rodou depois do M10.10; a régua de correção passou
verde o tempo todo, porque o arquivo estava certo — só era lido devagar.

Tentei ainda 32 bytes de folga no fim do buffer para eliminar os laços de resto:
102 → 99 ms. Três por cento por uma folga a justificar, uma guarda na entrada e
um laço que escreve de propósito além do necessário. Recusado — quando a medição
diz que o ganho é ruído, a forma simples ganha.

### Critério de saída

- [x] nenhuma cópia byte a byte fora do caso que a semântica exige
- [x] fronteira da cópia larga coberta por teste que falha se ela se mover
- [x] 213 testes verdes, interoperabilidade nos dois formatos
- [x] números do README e do ROADMAP refeitos no padrão atual

---

## M10.13 — SELECT DISTINCT ✅

O operador já existia: `unicos` é `agrupar` + `contar` + ficar só com a chave. O
dialeto é que não chegava lá. `SELECT DISTINCT` **é** um `GROUP BY` sem
agregação — escrever assim não trouxe operador novo, nem caso novo no otimizador,
nem no executor. O `explicar()` mostra a composição, sem inventar um verbo.

### A linha, não a coluna

`SELECT DISTINCT cidade, uf` devolve as **combinações** distintas, não os valores
distintos de cada coluna lado a lado. É a leitura do SQL e é a única que faz
sentido: colunas destiladas separadamente não teriam como formar linhas.

### Ausência é um valor que já apareceu

Duas linhas ausentes viram uma só. É onde `DISTINCT` diverge do `=` do próprio
Tucano: `NA = NA` é DESCONHECIDO na lógica de três valores, mas o distinto trata
ausência como valor visto. É o que o SQL manda e o que o `agrupar` já fazia — a
divergência está documentada no contrato em vez de escondida.

### `ORDER BY` com `DISTINCT` é recusado quando a coluna sumiu

Ordenar antes de destilar ordena linhas que vão desaparecer; ordenar depois exige
uma coluna que a projeção já descartou. Não há resposta certa a dar, então a
pergunta é recusada — mesmo motivo pelo qual o SQL padrão a recusa.

```
> SELECT DISTINCT cidade FROM v ORDER BY valor
com SELECT DISTINCT, ORDER BY so aceita coluna do SELECT — 'valor' nao esta na
lista. Acrescente-a ao SELECT ou tire-a do ORDER BY
```

### `DISTINCT *` exigiu o esquema previsto de valer para arquivo

Para agrupar por todas as colunas é preciso saber quais são, antes de executar.
`esquema_previsto()` existia para isso desde o M8, mas partia do lote em memória
— e num plano que lê de arquivo o lote está vazio até o `coletar()`. Devolvia um
esquema **vazio**: resposta errada com cara de resposta. Agora a base vem do
rodapé do Parquet, sem tocar em dado.

### Um bug achado no caminho

`SELECT cidade AS c` nunca funcionou. O apelido de coluna simples era lido pelo
analisador e nunca aplicado: a projeção ia procurar uma coluna com o nome novo,
que só existia na descrição da consulta. Falhava depois, dizendo que a coluna não
existia — mensagem correta sobre a causa errada.

Como não há operação de renomear, a coluna apelidada passa a ser criada como
derivada da original. Apelido que colide com uma coluna existente é recusado, em
vez de sobrescrevê-la em silêncio.

### Critério de saída

- [x] `SELECT DISTINCT` sobre lista de colunas e sobre `*`
- [x] combinação, não coluna a coluna; ausência agrupa
- [x] `ORDER BY` fora do `SELECT` recusado com a correção
- [x] `AS` em coluna simples funciona; apelido ambíguo recusado
- [x] 220 testes verdes, interoperabilidade nos dois formatos

---

## M12 — Ler .xlsx ✅

Abrir a planilha é o que o analista pede. `.xlsx` é ZIP de XML; o Tucano passa a
descomprimir DEFLATE cru, achar o membro e montar uma `Tabela`. Uma forma:
`ler_xlsx(caminho)` é a primeira aba; `planilha="Nome"` escolhe. Cabeçalho na
primeira linha, como no CSV. Serial de data do Excel vira `data` quando o estilo
da célula é data.

`.xls` antigo (BIFF) é recusado com a correção. Não há escritor — isso continua
compatibilidade tardia, não o caminho do engine.

### Critério de saída

- [x] `ler_xlsx` lê a primeira planilha; `planilha=` escolhe a aba
- [x] tipos inferidos; data pelo estilo; ausente vira NA
- [x] `.xls` recusado
- [x] 212 testes verdes

---

## M11 — GPU [experimental]

Trilha paralela, **fora** do caminho crítico. Só depois de Filter / GroupBy / Aggregate / Sort estarem maduros na CPU, e só onde o workload justificar.

---

## Escrita Excel [baixa]

Último. Compatibilidade, não inovação. A leitura já existe; gravar `.xlsx` não é o engine.

---

## Tucano 1.0 — definição de pronto

**Core** — Tabela, Coluna, schema, Int/Float/Bool/String/Data, NA de três valores, memória columnar

**Expressions** — coluna, literais, comparação, aritmética, booleanos, coluna derivada

**Execution** — filter, projection, expression, sort, aggregation

**Analytics** — groupby, join, concat, resumo, estatísticas básicas

**I/O** — CSV, Parquet (column pruning + predicate pushdown + distinct_count + Snappy na escrita), leitura `.xlsx`

**SQL** — SELECT/WHERE/GROUP BY/HAVING/ORDER BY/LIMIT, JOIN (`USING`) e COUNT(DISTINCT), sobre o mesmo planner

**Performance** — SIMD, dictionary encoding (leitura e escrita), streaming, predicate pushdown, benchmarks públicos. Multithreading quando o Mojo 1.0 expuser primitiva.

**Distribuição** — pacote instalável, README, documentação de API

**Fora do 1.0** — Python, escrita Excel, clonagem de API alheia, GPU obrigatória, servidor HTTP / dashboard nativo

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
```

Por baixo: Expression → Logical Plan → Optimizer → Physical Plan → SIMD/Parallel/Streaming → Memory Engine.

---

## Suíte de benchmarks

Tucano × Polars × DuckDB × a biblioteca tabular mais usada em Python, de 1M a 1B linhas:

tempo, RAM, throughput, **startup**, scaling por cores, I/O

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
10. ~~**Escritor**: emitir texto em `RLE_DICTIONARY`~~ — 245 → 124 MiB; leitura 230 → 62 ms
11. ~~Reavaliar paralelismo~~ — reavaliado: continua bloqueado (`struct fields cannot expose AnyOrigin`). Entra quando o stdlib expuser primitiva.
12. Quando houver canal conda: publicar com `recipe.yaml` e fechar o último item do M2.5
13. ~~**Próximo com retorno:** estatísticas de row group + predicate pushdown~~ — M10.7
14. ~~**Próximo com retorno:** `distinct_count` em coluna dicionarizada + reordenação de junção~~ — M10.8
15. ~~**Próximo com retorno:** `JOIN` no SQL (`USING`)~~ — M10.9
16. Painel HTTP — **fora por ora.** Reavalia quando o Mojo expuser `std.net`.
17. ~~**Próximo com retorno:** Snappy na escrita~~ — M10.10
18. ~~**Próximo com retorno:** `HAVING` + `COUNT(DISTINCT)` no SQL~~ — M10.11
19. ~~**Próximo com retorno:** abrir `.xlsx`~~ — M12
20. ~~**Próximo com retorno:** decodificador Snappy~~ — M10.12
21. ~~**Próximo com retorno:** `SELECT DISTINCT`~~ — M10.13
