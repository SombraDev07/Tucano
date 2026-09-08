# Roadmap Tucano

**Tese:** biblioteca tabular nativa em Mojo — **ergonomia de pandas, semântica de banco de dados, motor moderno de ponta a ponta**.

**Não é:** clone da API do pandas.
**É:** usável no primeiro dia por quem vem do pandas, sem herdar nenhum dos erros dele.

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

## Por que existir: a autópsia do pandas

Isto não é decoração. Cada linha abaixo é uma decisão de design do Tucano.

| Pecado do pandas | Custo real | Resposta do Tucano | Marco |
|---|---|---|---|
| **Index implícito com alinhamento automático** | `a + b` vira NaN silencioso; `reset_index()` em todo lugar | Sem index de rótulo. Join é sempre explícito | M2.5 |
| **NaN como único missing** | Int com 1 nulo vira `float64` e perde precisão | Validity bitmap separado do valor: Int64 continua Int64 com NA | ✅ M1 |
| **String = `object` dtype** | Um ponteiro Python por célula, zero vetorização | `StringStore` (offsets + bytes) + dictionary encoding | ✅ M1 / M4 |
| **View vs. copy indecidível** | `SettingWithCopyWarning`; ninguém sabe se mutou | Ownership do Mojo (`var` / `^` / `ref`) resolve em compile-time | ✅ grátis |
| **Eager sem plano** | `df[df.a>5][['b','c']]` materializa o intermediário | Lazy por padrão + pushdown | ✅ M2 / M8 |
| **`apply(lambda)` 100x lento em silêncio** | O usuário nunca sabe que caiu do caminho rápido | Plano inspecionável + **aviso explícito ao sair do kernel vetorizado** | M3 |
| **~600 métodos, 5 formas de indexar** | `.loc`/`.iloc`/`.at`/`.iat`/`[]`, `apply`/`map`/`agg`/`transform` | **Uma forma por operação.** Sinônimos são recusados | permanente |
| **Coerção silenciosa de tipo** | Concat de tipos diferentes → `object` | Erro, nunca coerção implícita | ✅ prática atual |
| **Single-threaded (GIL)** | 1 core de 16 | Paralelismo automático por chunk | M4 |
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

Antes de adicionar um método, a pergunta é: *já existe um jeito de fazer isso?* Se existe, o novo é recusado. A explosão de API do pandas começou com conveniências.

### 5. Erros ensinam

Toda mensagem de erro diz o que aconteceu, onde, e qual é a correção provável. Nome de coluna errado sugere o mais próximo.

### 6. Zero Python

Sem `std.python`, sem pandas, sem pyarrow como runtime.

### 7. Frontend não é Mojo

Mojo faz dado e execução. Navegador faz gráfico, layout e interação. O painel troca **JSON agregado**, nunca o dataset.

---

## Métrica de sucesso

**Não é** "80% da API do pandas". **Nem** "ganhar do DuckDB em TPC-H" — isso levaria anos e não é onde o Tucano é diferente.

São três provas, em ordem de honestidade:

1. **Usabilidade** — um analista que sabe pandas resolve uma tarefa real (ler, filtrar, derivar coluna, agrupar, exportar) sem consultar documentação além do README.
2. **Query interativa** — filtro de painel sobre 10M linhas responde em tempo de interação. Aqui pesam startup e replanejamento, onde binário AOT bate stack Python de verdade.
3. **Escala** — suíte pública vs. Pandas / Polars / DuckDB (1M → 1B linhas): tempo, RAM, throughput, startup, scaling por cores.

---

## Estado atual do código (honestidade)

**M0, M1, M2 e M2.5 fechados.** Próximo: **M3 — Execution Engine**. 33 testes verdes.

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
| `ler_csv` / `para_csv` | ponte — refazer em M5 |
| Publicação em canal conda | ❌ exige canal próprio |
| `DType.DATAHORA` | ❌ adiado para M5 |
| Coluna derivada (`com_coluna`) | ❌ M3 |
| `agrupar` / `unir` / `ordenar` | ❌ M6 |
| Painel | ❌ M7 |

### Dívidas concretas identificadas

**1. ~~`Tabela.indice` é o Index do pandas nascendo.~~** ✅ Removido em M2.5. `linhas()` vem de `_colunas[0].tamanho()`.

**2. `Consulta.coletar()` é quadrático.** A avaliação é linha a linha e cada referência a coluna chama `Tabela.pegar()`, que faz busca linear **e retorna `.copy()`** — cópia profunda dos slabs. Numa tabela de 200k linhas, um filtro faz centenas de milhares de cópias de colunas de 200k elementos. É exatamente o que o M3 existe para consertar, e é pré-requisito do M4: não há kernel SIMD sobre um laço que copia a coluna a cada iteração.

**3. ~~Lógica de NA sob negação.~~** ✅ Corrigido em M2.5 — ver Decisão 2. Regressão coberta por `test_na_tres_valores_negacao`.

---

## Linha do tempo

| Marco | Nome | Prioridade | Status | Resultado |
|-------|------|------------|--------|-----------|
| M0 | Fundação | crítica | ✅ feito | `Tabela`/`Coluna` estáveis + Schema |
| M1 | Memory Engine | crítica | ✅ feito | columnar + validity + buffers |
| M2 | Expression Engine | crítica | ✅ feito | expressões + plano lógico |
| M2.5 | Biblioteca + Correções | crítica | ✅ feito | instalável, sem dívidas de fundação |
| **M3** | **Execution Engine** | **crítica** | **próximo** | executor coluna-a-coluna |
| M4 | SIMD + Parallel | crítica | não iniciado | kernels vetorizados/paralelos |
| M5 | I/O + Streaming | crítica | parcial (CSV ponte) | scanner tipado + Parquet |
| M6 | Aggregation + Join | crítica | não iniciado | group/join como operadores |
| M7 | Painel | alta | não iniciado | dashboard nativo |
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

> Empacotar cedo força a decisão de superfície pública. Foi a ausência dessa disciplina que produziu os 600 métodos do pandas.

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

## M3 — Execution Engine

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

O `df['x'] = ...` do pandas é metade do uso real e hoje não existe:

```mojo
var t = tabela.com_coluna("total", coluna("preco").vezes(coluna("qtd")))
```

### Critério de saída

- [ ] Scan / Filter / Project físicos, coluna-a-coluna
- [ ] Separação clara logical vs. physical
- [ ] `com_coluna()` sobre o Expression Engine
- [ ] `Tabela.onde()` lazy por padrão, materialização automática na exibição
- [ ] Fim da cópia por linha em `pegar()` (dívida 2)
- [ ] `descrever()` mostra o plano físico
- [ ] Aviso quando uma operação cai fora do caminho vetorizado
- [ ] Mesmos resultados da API eager antiga nos testes de regressão

---

## M4 — SIMD + Parallel

A justificativa de usar Mojo: kernels especializados que o pandas não pode ter.

- filter, sum, min, max, mean, comparação, aritmética
- SIMD chunks + mask + reduce
- multithreading por chunk, cache-aware
- seleção automática de kernel — o usuário nunca escreve paralelo

### Dictionary encoding

Colunas de texto de baixa cardinalidade (cidade, estado, categoria) viram códigos `Int32`:

- `cidade == "Curitiba"` vira comparação de inteiros → SIMD puro
- groupby por chave dicionarizada vira **indexação direta de array**, sem hash
- sort vira **radix sort paralelo**, não comparação

Pandas compara ponteiros de objeto Python, um por vez. Esta é a diferença algorítmica, não só de linguagem.

### Critério de saída

- [ ] Kernels SIMD nas ops numéricas críticas
- [ ] Paralelismo por chunks
- [ ] Dictionary encoding automático por cardinalidade
- [ ] Speedup mensurável vs. baseline M3 em 10M+ linhas

---

## M5 — I/O + Streaming

### CSV (refazer)

Não: arquivo → String → split → objetos.
Sim: `bytes → scanner → typed parser → column buffers`.

Parser próprio em Mojo, paralelo quando fizer sentido. Inferência de tipo **com override explícito de schema** — o `read_csv` do pandas tem ~50 parâmetros porque a inferência nunca foi controlável.

### Parquet (prioridade alta)

```
Parquet → metadata → column pruning → predicate pushdown → Tucano
```

Pushdown nasce no design, não como afterthought.

### Critério de saída

- [ ] `ler_csv` / `para_csv` sobre o Memory Engine, sem `String.split`
- [ ] Schema explícito opcional na leitura
- [ ] `DType.DATAHORA` (Int64) com parsing ISO-8601 completo — herdado do M2.5
- [ ] `ler_parquet` / `para_parquet` com pruning básico
- [ ] Caminho de streaming por chunks

---

## M6 — Aggregation + Join

Operadores do engine, não funções soltas: `HashAggregate`, `HashJoin`, `Sort`, `Projection`, `Filter`, `Scan`.

### API

```mojo
tabela.agrupar(["cidade"]).agregar([soma("valor"), media("idade"), contar()])
tabela.unir(outra, por="id", tipo="esquerda")
```

Uma única forma de agregar. Nada de `agg`/`transform`/`apply` como sinônimos, e nada de `groupby.apply` com shape imprevisível.

### Algoritmos

- **groupby**: hash agregado particionado por radix, paralelo; chave dicionarizada usa indexação direta
- **join**: hash join particionado, paralelo, com pré-filtro tipo Bloom no lado de sondagem
- **sort**: radix paralelo para inteiros e chaves dicionarizadas

### Também neste marco

`ordenar`, `concatenar`, `resumo()`, `contar_valores()`, `unicos()`, `preencher_na()`, `remover_na()`.

### Critério de saída

- [ ] GroupBy + agregações (soma, média, contagem, min, max)
- [ ] Join hash inner/left
- [ ] Verbos de análise acima cobertos por teste
- [ ] Benchmarks vs. Polars/DuckDB em workloads médios

---

## M7 — Painel

O dashboard como camada da biblioteca. A arquitetura vem direto da crítica ao pandas: `df.plot()` gera PNG estático, Streamlit re-executa o script inteiro, Dash reenvia o DataFrame. Todos tratam o painel como consumidor de **dados**.

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

**Fora do 1.0** — Python, Excel, clonagem da API do pandas, GPU obrigatória

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

Tucano × Pandas × Polars × DuckDB em 1M / 10M / 100M / 1B linhas:

tempo, RAM, throughput, **startup**, scaling por cores, I/O

E, a partir do M7, a métrica que é nossa: **latência de filtro de painel** e **bytes de payload por interação**.

---

## Próximo passo

1. ~~Fechar **M0**~~
2. ~~**M1**: storage columnar (buffers + validity + strings)~~
3. ~~**M2**: Expression Engine (`coluna` / `lit` / plano lógico / `coletar`)~~
4. ~~**M2.5**: empacotar a biblioteca, remover `Tabela.indice`, NA de três valores, `DType.DATA`~~
5. **M3**: executor coluna-a-coluna, `com_coluna()`, lazy por padrão
6. Manter o CSV atual só como ponte — não investir em features List-based novas
7. Quando houver canal conda: publicar com `recipe.yaml` e fechar o último item do M2.5
