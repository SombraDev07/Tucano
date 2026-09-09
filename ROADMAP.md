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

**M0 → M31 fechados.** Testes verdes, interoperabilidade verificada nos dois formatos e nos dois sentidos. Uma thread do Tucano está à frente do pandas no pipeline (1,9×) e do Polars em uma thread; na leitura pura está 1,1× atrás do pandas, custo da descompressão. SQL junta com `USING`, filtra grupos com `HAVING` e conta distintos. O escritor comprime páginas com Snappy. Planilha `.xlsx` abre como `Tabela`. O servidor HTTP do painel está estacionado.

Falta para o 1.0, e nada disso é questão de escopo:

| O que falta | Por quê |
|---|---|
| ~~**Escrita `.xlsx`**~~ | Feito no M14: `para_xlsx`, uma aba, verificado contra o openpyxl. |
| ~~**Paralelismo por thread**~~ | Feito no M13: leitura usa uma thread por coluna, 105 → 69 ms. Os operadores de execução ainda são de uma thread — é o que separa o Tucano do DuckDB em 16 núcleos. |
| **Publicação em canal conda** | `recipe.yaml` está pronto; falta um canal (prefix.dev ou equivalente). Decisão de projeto. |
| ~~**Slab de data em Int32**~~ | Feito no M28: o slab carrega a própria largura. 38 → 19 MiB por 5M datas, leitura no mesmo tempo. |

GPU (M11) e o servidor HTTP do painel (M7) seguem fora do caminho crítico. Do que falta para o 1.0, **sobrou um item, e ele não é código**: o canal conda, que é decisão de projeto — `recipe.yaml` está pronto e esperando um canal.

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
| Escrita `.csv` | ✅ M5 — `para_csv` |
| Escrita `.xlsx` | ✅ M14 — `para_xlsx`, verificada contra o openpyxl |
| SQL `SELECT DISTINCT` / `SELECT ALL` | ✅ M10.13 |
| Paralelismo na leitura (uma thread por coluna) | ✅ M13 |
| Paralelismo nos operadores de execução | ❌ **medido e recusado** — banda de memória, não CPU (M15) |
| Junção e ordenação mais baratas | ✅ M16 — 74 e 100 ns/linha |
| Escritor com `DELTA_BINARY_PACKED` | ✅ M24 — arquivo 42% menor |
| Chave de grupo composta | ✅ M17 — 34 ns/linha |
| Slab de data em Int32 | ✅ M28 — o slab passou a carregar a própria largura |
| Publicação em canal conda | ❌ exige canal próprio |

### Dívidas concretas identificadas

**1. ~~`Tabela.indice` era um índice implícito nascendo.~~** ✅ Removido em M2.5. `linhas()` vem de `_colunas[0].tamanho()`.

**2. ~~`Consulta.coletar()` é quadrático.~~** ✅ Resolvido em M3. O executor lê cada coluna **uma vez** para um `Vetor` contíguo (com `ref` sobre o lote, sem cópia) e opera sobre ele. `bench/bench_m3.mojo` mede ns/linha praticamente constante de 25k a 200k linhas — escala linear.

**3. ~~Lógica de NA sob negação.~~** ✅ Corrigido em M2.5 — ver Decisão 2. Regressão coberta por `test_na_tres_valores_negacao`.

**4. Slab de data em Int32 — dívida rastreada.** Já foi adiada duas vezes, então deixa de ser "herdada do marco anterior" e passa a ter gatilho explícito. Datas e datahoras vivem hoje no slab `Int64` da `Coluna`. O motivo original — velocidade de cálculo — foi resolvido no M4: o kernel de calendário converte para Int32 justamente porque Int64 não vetoriza divisão no AVX2. O que resta é memória: 4 bytes contra 8 por linha de data.

Adicionar agora um sexto `List` paralelo à `Coluna` piora a estrutura em vez de melhorá-la. **Gatilho original:** entrava junto do redesenho de `Coluna` para um buffer de bytes tipado (largura + tipo lógico, em vez de um `List` por tipo) — que é a forma certa e a que o M9 ia precisar para spill em disco.

**Reavaliada e medida (2026-09-09).** Três coisas mudaram, e nenhuma na direção esperada:

*O prêmio, medido.* Uma coluna de 5 milhões de datas ocupa **38 MiB** em `Int64` e ocuparia
19 em `Int32`; lê-la custa 14 ms e custaria uns 10. Nos benchmarks do projeto o ganho é
**zero** — nenhum deles tem coluna de data. Numa tabela analítica típica, com uma coluna de
data entre dez, são ~5% da memória.

*A objeção técnica caiu.* Media-se o receio de que um buffer de bytes com largura em tempo de
execução fosse mais lento que um `List` tipado. Não é: somar 20 milhões de inteiros custa
**7 ms dos dois jeitos**, com a largura decidida fora do laço. A forma certa não custa nada
no caminho comum.

*Mas a segunda justificativa do gatilho evaporou.* O M9 fechou **sem precisar de spill** — a
execução em fluxo troca os dados pelo estado dos grupos, e o pico fica num row group. O
redesenho tinha duas razões; sobrou uma.

*E as três implementações limpas têm custo real:* um sexto `List` é o que este parágrafo já
recusa; sobrecarregar o slab de `codigos` piora os dois significados; e tornar o slab inteiro
ciente da largura toca ~40 pontos nos caminhos mais quentes — ordenação, junção, agrupamento,
compactação — além de exigir variante de largura em quatro kernels.

~~**Decisão pendente do dono do projeto**~~ — **decidida em 2026-09-09**: fazer o slab ciente
da largura, que era a terceira opção. Feito no M28. O número da refatoração estava certo em
ordem de grandeza (11 arquivos, ~40 pontos), e o do prêmio também: 38 → 19 MiB por 5 milhões
de datas, com a leitura no mesmo tempo. A dívida sai da lista.

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
| M13 | Paralelismo por thread | crítica | ✅ feito | leitura 105 → 69 ms |
| M15 | Operadores | crítica | ✅ feito | filtro 47 → 16 ms; paralelizar operador medido e recusado |
| M16 | Junção e ordenação | crítica | ✅ feito | 470 → 66 e 335 → 98 ns/linha |
| M17 | Chave de grupo composta | crítica | ✅ feito | 221 → 30 ns/linha |
| M18 | Chave de grupo inteira | crítica | ✅ feito | 22 → 11 ns/linha |
| M19 | Execução em fluxo | crítica | ✅ feito | 900 → 93 ms, mesmo pico de memória |
| M20 | Leitura em faixas | crítica | ✅ feito | 75 → 50 ms; pipeline 88 → 69 |
| M21 | Leitura de poucas colunas | crítica | ✅ feito | uma coluna 33 → 16 ms |
| M22 | Medir a distância para o Polars | crítica | ✅ feito | Snappy é 23 dos 28 ms; duas tentativas recusadas |
| M23 | As três técnicas dos maduros | crítica | ✅ feito | as três mais lentas; o alvo é o escritor |
| M24 | Escritor com DELTA_BINARY_PACKED | crítica | ✅ feito | arquivo 43 → 25 MiB; coluna inteira 28 → 7 ms |
| M25 | Dicionário em coluna numérica | crítica | ✅ feito | arquivo 25 → 12 MiB; leitura passa o pyarrow |
| M26 | Remover a divisão em faixas | crítica | ✅ feito | 285 linhas a menos, e mais rápido |
| M27 | A escrita, medida | crítica | ✅ feito | perfil por fase; as codificações pagam a si mesmas |
| M28 | Slab de data em Int32 | crítica | ✅ feito | 38 → 19 MiB por 5M datas; leitura igual |
| M29 | Escrita paralela por coluna | crítica | ✅ feito | 1227 → 594 ms; encosta no pyarrow |
| M30 | A escrita, em ondas | crítica | ✅ feito | 594 → 430 ms; empata com o pyarrow |
| M31 | A pergunta feita por linha | crítica | ✅ feito | 430 → 241 ms; 1,8× o pyarrow |
| M10.12 | Snappy sem cópia byte a byte | crítica | ✅ feito | leitura 259 → 102 ms |
| M10.13 | SQL SELECT DISTINCT / ALL | crítica | ✅ feito | o mesmo `agrupar`, sem operador novo |
| M14 | Excel (escrita) | crítica | ✅ feito | `para_xlsx` — ZIP com método 0, sem compressor |
| M11 | GPU | experimental | não iniciado | aceleradores selecionados |

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
M13 Paralelismo na leitura
 ↓
M14 Excel escrita (`para_xlsx`)
 ↓
Tucano 1.0
   └── M11 GPU [experimental]
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

## M4 — SIMD ✅ (+ Parallel: conclusão errada, ver M13)

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

### Paralelismo — a conclusão de bloqueio estava errada

> **Esta seção ficou errada por vários marcos, e o erro está preservado aqui de
> propósito.** A conclusão era que paralelismo de dados estava "fechado por
> construção no Mojo 1.0". Não estava. O conserto e a medição estão no M13.

O que se mediu na época era verdade: o stdlib não expõe `parallelize`, e
`pthread_create` aceita um ponteiro de função do Mojo e devolve 0. O erro foi na
inferência a partir do erro seguinte:

```
error: struct fields cannot expose AnyOrigin in their type
```

Daí se concluiu que "marshalar parâmetros para uma thread exige guardar um
ponteiro de origem apagada num campo de struct". **Não exige.** O ponteiro de
origem apagada aparece uma vez só, como o **tipo do parâmetro da função
trabalhadora** — `UnsafePointer[T, origin=AnyOrigin[mut=True]]` — e ali é
permitido. A struct de tarefa guarda dados comuns: `String`, `Int`, a lista onde
a resposta volta. Nenhum campo precisa de `AnyOrigin`.

A lição não é sobre threads. É que **"a linguagem proíbe" é uma afirmação forte,
e uma mensagem de erro sozinha não a sustenta.** O erro dizia o que não se pode
pôr num campo de struct; a conclusão foi sobre o que não se pode fazer com
threads. Entre uma coisa e outra faltou o passo que só se dá tentando.

- [x] ~~Paralelismo por chunks — **bloqueado**~~ — a conclusão estava errada; ver M13
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

Paralelismo ficou fora deste marco. A justificativa registrada aqui na época —
que a regra de posse do Mojo impediria carregar as estruturas do Tucano por
thread — **estava errada**, e o conserto veio no M13.

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

## M10.13 — SELECT DISTINCT (e o `ALL` do outro lado) ✅

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

### `ALL`, o outro lado, e a decisão travada que quase o barrou

`SELECT ALL` é o oposto explícito de `DISTINCT` e não muda nada — repetir já é o
padrão. Antes da correção, `ALL` era engolido como nome de coluna e o erro
apontava o lugar errado: *"esperava 'FROM', achei 'cidade'"*, quando o problema
estava três tokens atrás.

A decisão travada de **uma forma por operação** pede recusar sinônimos, e a
primeira leitura foi que `ALL` era exatamente isso. Não é: sinônimo é um segundo
verbo nosso para a mesma operação. `ALL` é a mesma única forma escrita como o SQL
padrão permite escrever — o dialeto já fazia isso com o `OUTER` de `LEFT OUTER
JOIN`. A regra vale para a API do Tucano, não para o vocabulário de um formato
que existe para receber consulta escrita em outro lugar.

`ALL` com `DISTINCT` é recusado nas duas ordens, e dentro de `COUNT` também.

### `ALL` só é reservada quando vem alvo depois

O dialeto não tem identificador entre aspas, então `SELECT all FROM v` é a única
forma de pedir uma coluna chamada `all`. Aceitar `ALL` como modificador sem olhar
adiante tornaria essa coluna inalcançável — o analisador espia um token e só
trata `ALL` como palavra reservada quando vem um nome ou `*` depois dele.

`SELECT ALL all FROM v` funciona, e é o teste que prova que a regra está certa.

### Critério de saída

- [x] `SELECT DISTINCT` sobre lista de colunas e sobre `*`
- [x] combinação, não coluna a coluna; ausência agrupa
- [x] `ORDER BY` fora do `SELECT` recusado com a correção
- [x] `AS` em coluna simples funciona; apelido ambíguo recusado
- [x] `SELECT ALL` e `COUNT(ALL c)` aceitos; junto com `DISTINCT`, recusados
- [x] coluna chamada `all` continua acessível
- [x] 223 testes verdes, interoperabilidade nos dois formatos

---

## M12 — Ler .xlsx ✅

Abrir a planilha é o que o analista pede. `.xlsx` é ZIP de XML; o Tucano passa a
descomprimir DEFLATE cru, achar o membro e montar uma `Tabela`. Uma forma:
`ler_xlsx(caminho)` é a primeira aba; `planilha="Nome"` escolhe. Cabeçalho na
primeira linha, como no CSV. Serial de data do Excel vira `data` quando o estilo
da célula é data.

`.xls` antigo (BIFF) é recusado com a correção. A escrita simétrica é o M14.

### Critério de saída

- [x] `ler_xlsx` lê a primeira planilha; `planilha=` escolhe a aba
- [x] tipos inferidos; data pelo estilo; ausente vira NA
- [x] `.xls` recusado
- [x] 212 testes verdes

---

## M13 — Paralelismo por thread ✅

Registrado como bloqueado desde o M4, com a justificativa de que a linguagem
proibia. Não proibia. Tudo o que segue foi verificado nesta máquina, no Mojo
1.0.0 (`ed45d567`), antes de escrever uma linha de biblioteca.

### O que o Mojo permite, medido em vez de suposto

- `pthread_create` aceita uma `def` comum do Mojo como rotina de entrada. Sem
  `@export`, sem `abi("C")`.
- O parâmetro precisa ser um ponteiro com a origem **fixada**:
  `UnsafePointer[T, origin=AnyOrigin[mut=True]]`. Deixá-la solta com `_` torna a
  função paramétrica, e função paramétrica não tem endereço:
  *"cannot use parametric function as a runtime closure"*.
- O alocador aguenta. Oito threads criando `List` e `String` sem parar
  devolveram todos os resultados corretos.
- Escala de verdade: carga aritmética idêntica em oito threads mediu **7,75×**.
  Não há lock global no runtime.
- `try`/`except` dentro do trabalhador funciona, e é por ali que o erro volta —
  a rotina de entrada não pode propagar exceção para quem deu `join`.

### Onde o raciocínio antigo errou

O erro `struct fields cannot expose AnyOrigin in their type` é real, e a
conclusão tirada dele foi que passar dados para uma thread exigiria justamente
isso. Não exige. A struct de tarefa guarda dados comuns — `String`, `Int`, a
lista onde a resposta volta. O ponteiro de origem apagada aparece **uma vez**,
como tipo do parâmetro da função trabalhadora, e ali é permitido.

### Uma coluna por thread

Colunas não dependem umas das outras, então o desenho não precisa de nenhum
mutex — precisa que **nenhuma tarefa escreva onde outra lê**. Cada tarefa abre
o próprio descritor, lê o próprio rodapé e escreve no próprio destino. O
encontro é depois do `join`.

Reler o rodapé por tarefa custa ~130 µs contra dezenas de milissegundos de
decodificação, e em troca não sobra nada compartilhado para proteger. Foi a
troca deliberada: 0,3% do tempo por zero estado comum.

`pread` é o que torna isso simples. Ler por faixa não usa o cursor do arquivo,
então duas threads no mesmo descritor não disputam nada. O Tucano já lia assim
desde o M9, por causa de memória — o paralelismo veio de graça em cima disso.

### O limiar foi chutado, e o chute estava errado

A primeira versão exigia 50 mil linhas por tarefa para valer uma thread. Número
inventado. Medindo com o limiar desligado, num Parquet de 4 colunas:

| linhas | sequencial | paralelo | ganho |
|---|---|---|---|
| 1.000 | 64 µs | 110 µs | 0,58× |
| 5.000 | 104 µs | 113 µs | 0,92× |
| 10.000 | 172 µs | 140 µs | **1,23×** |
| 25.000 | 392 µs | 256 µs | 1,53× |
| 100.000 | 1498 µs | 868 µs | 1,73× |

A virada é entre 5 e 10 mil, não em 50 mil — o chute errou por cinco vezes. O
limiar é 10.000, e o ganho satura perto de 1,7× com 4 colunas, **não 4×**: as
colunas custam coisas diferentes, e o total é o da mais cara, não a média.

### Resultado

| 5M linhas × 5 colunas, 44 MiB | uma thread | com threads | |
|---|---|---|---|
| ler tudo | 105 ms | **69 ms** | 1,5× |
| ler 2 de 5 colunas | 48 ms | 42 ms | 1,1× |
| pipeline completo | 117 ms | 110 ms | 1,06× |

Contra o pandas em uma thread, a leitura completa passa de 98 ms para 70 — e o
pyarrow, que fazia 54, fica ao alcance.

O caso podado ganha pouco porque duas colunas só dão duas threads. O pipeline
ganha 6% porque a leitura é parte dele e o resto — filtro, groupby, junção —
continua em uma thread. **Paralelizar os operadores é a próxima peça**, e ela é
maior: exige que tarefas escrevam em fatias do mesmo destino, que é exatamente o
que este desenho evitou de propósito.

### `TUCANO_THREADS`

Quem embute o Tucano num servidor que já tem o próprio conjunto de threads
precisa poder dizer "uma só". A variável de ambiente é o lugar certo: não
acrescenta parâmetro em toda função de leitura, e é onde quem opera o processo
já procura esse tipo de ajuste. Valor inválido ou ausente cai nos núcleos do
sistema.

### Critério de saída

- [x] leitura usa uma thread por coluna acima do limiar medido
- [x] paralelo e sequencial conferidos **valor a valor**: 25 milhões de valores,
      zero divergências
- [x] o caminho de thread é exercitado por teste — as fixtures do resto da suíte
      ficam abaixo do limiar e não o alcançariam
- [x] `TUCANO_THREADS` desliga; a suíte passa igual com ela em 1
- [x] 226 testes verdes, interoperabilidade nos dois formatos

---

## M14 — Escrever .xlsx ✅

A leitura existia desde o M12. A saída que o analista pede é a planilha:
`para_xlsx(tabela, caminho)`, uma aba, valores, sem fórmula. Uma tabela, um
arquivo.

### ZIP sem compressor

`.xlsx` é ZIP de XML, e o ZIP tem o método 0 — **armazenado**. Escrever com ele
dispensa um compressor DEFLATE inteiro, que seria um módulo a manter para
economizar bytes que o Excel abre igual. Quem quiser o arquivo menor comprime por
fora; ele continua um ZIP válido.

O que entrou foi um CRC-32 e o enquadramento: cabeçalho local por membro,
diretório central, e o registro de fim. O leitor de ZIP do M12 lê o que o
escritor produz, o que fecha a primeira volta.

### O único estilo que existe

`numFmtId` 14 e 22 — data e datahora. Sem eles a célula apareceria como o número
de série cru, e nem o Excel nem o `ler_xlsx` saberiam que aquilo é uma data. É o
mínimo que o formato exige para não mentir, e nada além.

### A hora estava sendo perdida na volta

Escrever datahora expôs um buraco da leitura do M12: a grade só tinha `_DATA`, e
truncava a hora. Round-trip que perde informação não fecha marco.

A correção não precisou de estilo novo. **Na planilha, data e datahora são o mesmo
número — a hora é a fração do dia.** Quem distingue é a parte fracionária, não o
`numFmtId`, que cada escritor escolhe como quer. A leitura passou a decidir pela
fração, e a hora sobrevive à volta, inclusive antes da epoch.

### Dois defeitos que os testes acharam

O nome de aba `Vendas & Cia` sai escapado no XML, como manda o formato — e a
leitura **não desescapava**, então a aba nunca era encontrada pelo nome. Um `&`
num nome de aba é comum o bastante para isso ser um bug de verdade.

E a checagem de "tabela sem colunas" em `para_xlsx` era código morto: a própria
`Tabela` já recusa. Saiu, junto com o teste que afirmava a mensagem errada.

### Verificação cruzada

O ambiente de fixtures ganhou `openpyxl`, e `verificar_tudo.sh` ganhou dois
passos: a ida e volta pelo próprio Tucano, e a leitura por outra implementação.
Round-trip próprio não prova nada — um leitor e um escritor com o mesmo
mal-entendido concordam entre si.

O openpyxl lê os arquivos e confere valor a valor, incluindo `bru & co`,
`<carlos>`, a célula ausente como vazia, e `2024-01-15 08:30:00` com a hora
exata.

### Critério de saída

- [x] `para_xlsx(tabela, caminho)`; `planilha="Nome"` nomeia a aba
- [x] texto, inteiro, real, lógico, data e datahora; ausente vira célula vazia
- [x] `&`, `<` e `>` escapados no conteúdo e no nome da aba
- [x] mais de 26 colunas — a 27ª é `AA`
- [x] openpyxl lê o que o Tucano escreve, dentro do `verificar_tudo.sh`
- [x] 243 testes verdes

---

## M15 — Operadores: o desperdício primeiro, o paralelismo medido ✅

Pedido: paralelizar os operadores de execução. O que se mediu primeiro mudou o
que valia fazer.

### O filtro gastava 10× o necessário

`avaliar_tri` sobre `valor > 1000.0` custava 32 ms em 5 milhões de linhas. A
comparação em si custa 5. Os outros 27 eram materialização:

| | |
|---|---|
| `extrair_coluna` copia a coluna inteira para um `Vetor` | 16 ms |
| `constante_numerica` materializa 5 milhões de cópias do literal | 10 ms |
| a comparação SIMD de verdade | 5 ms |

O avaliador é uma árvore que materializa em cada nó, e para `coluna OP literal`
isso significa três passagens de memória onde uma bastava. Já existia o atalho
para texto dicionarizado (`_cmp_dicionario`, do M4); faltava o numérico.

`cmp_f64_escalar` lê o slab no lugar e difunde o escalar no registrador SIMD.
Coluna sem nenhum ausente tem variante própria — sem ausentes o resultado nunca
é DESCONHECIDO, então some a leitura da máscara de validade, como já era o caso
em `soma_f64_densa`.

**`avaliar_tri`: 32 → 3 ms.** O pipeline completo foi de 110 para 88.

Só vale para coluna REAL. Em INTEIRO o caminho geral converte para f64, e
reproduzir essa conversão no atalho seria uma segunda regra de coerção — o
contrário da Decisão 4. Inteiro cai no caminho geral, e um teste garante que
continua certo.

Atalho que discorda do caminho geral é resposta errada em silêncio, então a
conferência é contra um **oráculo escrito à parte** — não contra `avaliar_tri`,
que passou a usar o próprio atalho e responderia a si mesmo. Seis operadores,
duas ordens de operandos, com e sem ausentes.

### Paralelizar a compactação: medido, e é pior

Construída e medida antes de entrar na biblioteca. Três colunas, três threads,
resultado conferido valor a valor:

| | |
|---|---|
| compactar 3 colunas, sequencial | **13 ms** |
| compactar 3 colunas, em 3 threads | 20–22 ms |

Zero divergências e mais lento. A compactação lê e escreve dezenas de MiB por
coluna: é limitada por **banda de memória**, e nessa máquina oito threads
entregam só ~1,75× mais banda que uma (medido no M13). O que sobra do ganho não
paga a criação da thread mais a disputa no alocador, que precisa servir três
slabs novos de dezenas de MiB ao mesmo tempo.

O mesmo raciocínio vale para o resto do pipeline depois do desperdício removido:
agregação com 24 grupos sobre 4,6 milhões de linhas faz 15 ms lendo ~120 MiB —
também banda, não cálculo.

**Resultado negativo, e fica registrado como resultado.** Custou uma tarde
descobrir; sem o registro, custaria outra.

### O que isso exigiu descobrir sobre o Mojo

Ao contrário da leitura — onde cada tarefa é dona do que precisa — um operador
precisa **compartilhar a entrada**. E aí o erro do M4 morde de verdade:

```
error: struct fields cannot expose AnyOrigin in their type
```

A saída é o endereço viajar como `Int` e o ponteiro ser reconstruído dentro da
thread (`unsafe_from_address` com a origem fixada). Funciona, e foi assim que a
medição acima foi feita — mas é tráfego de ponteiro cru, sem verificação de
tempo de vida, no meio do executor. **Não entrou na biblioteca**, porque a
medição disse que não haveria o que ganhar em troca do risco.

### Onde o custo realmente está agora

Depois deste marco, o pipeline de 88 ms se divide em ~40 de leitura (já em
várias threads) e ~48 de execução. Dentro da execução, o filtro caiu para 16 ms
e a agregação está em 22.

Os operadores caros de verdade são outros, e `pixi run bench-m6` os mostra em
1 milhão de linhas: **junção a 459 ns/linha e ordenação a 321 ns/linha**, contra
14 ns/linha para formar grupos por chave dicionarizada. Uma junção por hash a
459 ns/linha não está limitada por banda — está fazendo trabalho demais. É onde
a próxima medição deve começar, e a lição deste marco é que ela vem antes de
qualquer thread.

### Resultado

| 5M linhas, uma thread | Tucano | pandas | Polars | DuckDB |
|---|---|---|---|---|
| pipeline (filtro + groupby + 3 agregações) | **88 ms** | 242 ms | 146 ms | 94 ms |

Contra uma thread, o Tucano passa o pandas em 2,7×, o Polars em 1,7× — e o
DuckDB, pela primeira vez, por pouco.

### Critério de saída

- [x] `coluna OP literal` em coluna real não materializa nem coluna nem literal
- [x] atalho conferido contra oráculo independente, não contra o próprio motor
- [x] paralelismo de operador medido antes de construído — e recusado com número
- [x] 227 testes verdes, interoperabilidade nos dois formatos

---

## M16 — Junção e ordenação: o valor vira código ✅

O M15 terminou apontando: junção a 470 ns/linha e ordenação a 335, contra 14 para
formar grupos por chave dicionarizada. Não era banda de memória — era trabalho
demais. As duas tinham a mesma doença, e é a mesma de todo este ciclo:
**materializar por linha o que se resolve uma vez por valor distinto.**

### Ordenação: 20 milhões de comparações, cada uma relendo a coluna

O comparador roda O(n log n) vezes. Cada chamada fazia dois `eh_ausente` que
lançam e extraem bit, um desvio por tipo, e — em coluna de texto — **duas
`String` alocadas**. Ordenar um milhão de linhas por texto alocava quarenta
milhões de `String` para responder "qual vem antes".

Três mudanças, cada uma medida:

**Chave extraída antes do laço.** A coluna é lida uma vez e vira vetor plano.
342 → 211 ms.

**Texto vira posto.** Os valores distintos são ordenados uma vez — cinquenta,
não um milhão — e cada linha guarda a posição do seu valor nessa ordem.
Comparar texto passa a ser comparar inteiro, e a ordem é a mesma por construção.
1320 → 210 ms, e texto passou a custar o mesmo que número.

**A chave viaja ao lado do índice.** `chave[indice[i]]` é acesso aleatório a um
vetor de dezenas de MiB, vinte milhões de vezes. Carregar a chave junto do
índice torna as leituras sequenciais. 211 → 70 ms.

E ausente sai da comparação: como vai sempre para o fim nas duas direções, é
separado antes, e o comparador vira uma comparação de número e nada mais.

> Um erro meu no caminho, e vale registrar: a primeira versão ordenava ao
> contrário **invertendo o vetor no fim**. Isso põe os empates na ordem inversa
> da original — a ordenação deixa de ser estável, e nenhum teste existente
> pegava. Descendente vira a comparação, não o resultado. O teste que faltava
> existe agora.

### Junção: duas buscas no `Dict` por linha, e uma `String` por linha de saída

| | |
|---|---|
| `Dict` consultado uma vez por **valor distinto**, não por linha sondada | |
| baldes viram duas listas planas — `inicio[c]` e `linhas` | 470 → 493 ms |
| `coletar_linhas_opcional` ganha o atalho de dicionário que já existia na versão não-opcional | 493 → 207 ms |
| chave de texto dicionarizada não materializa `String` por linha | 207 → **74 ms** |

A primeira mudança **não melhorou nada** — 470 para 493. Foi o que obrigou a
medir por fase em vez de continuar adivinhando, e aí apareceu o real: a junção à
esquerda alocava uma `String` por linha de saída para redicionarizar tudo no
fim. O atalho já existia em `coletar_linhas` desde sempre; faltava na versão que
trata o índice -1.

### Resultado

| 1M linhas, chave de 50 valores | antes | depois | |
|---|---|---|---|
| junção à esquerda | 470 ns/linha | **74 ns/linha** | 6,4× |
| ordenação estável | 335 ns/linha | **100 ns/linha** | 3,4× |
| ordenação por texto | 1320 ms | **98 ms** | 13,5× |

### Como se prova que continua certo

Junção e ordenação são operadores em que o erro não aparece: a linha errada
casa, o empate troca de lugar, e o resultado parece plausível. As duas ganharam
conferência contra referência **externa ao motor**:

- `test_juncao_bate_com_forca_bruta` — laço duplo, que é obviamente certo, com
  chave repetida nos dois lados, chave só de um lado, e ausente que nunca casa
  nem com outro ausente. Nas duas direções de junção e nos dois ramos da
  sondagem (texto e inteiro).
- `test_ordenar_uma_chave_bate_com_o_caminho_geral` — ordenar por `[c]` usa o
  caminho novo, por `[c, c]` usa o geral; a mesma pergunta feita aos dois.
- `test_ordenar_estavel_e_ausente_no_fim` — o teste que teria pegado o erro do
  vetor invertido.

### O próximo, com número

`grupos por chave composta` está em **221 ns/linha**, contra 12 pela chave
dicionarizada. `_chave_composta` monta uma `String` por linha para representar a
combinação — a mesma doença, no último lugar onde ela ainda mora.

### Critério de saída

- [x] chave de ordenação extraída uma vez; texto comparado por posto
- [x] estabilidade preservada no descendente, com teste que a exige
- [x] junção sem `Dict` no laço de sondagem e sem `String` por linha de saída
- [x] os dois conferidos contra referência externa ao motor
- [x] 232 testes verdes, interoperabilidade nos dois formatos

---

## M17 — Chave composta: o último lugar onde a `String` morava ✅

O M16 terminou apontando o número: `grupos por chave composta` em 221 ns/linha,
contra 12 pela chave dicionarizada. Dezoito vezes mais caro para fazer a mesma
coisa com duas colunas em vez de uma.

A causa era a mesma de todo o ciclo, no último lugar onde ainda morava: uma
`String` montada por linha. E o pior caso era pior do que parecia — para coluna
real, `_chave_texto` **formatava o float como texto**, uma vez por linha.

### Código denso por coluna, número em base mista

Cada coluna vira código denso `0..d-1`. Texto dicionarizado já vem pronto: o
código do dicionário **é** o código denso, custo zero. As outras passam por um
`Dict` uma vez por linha, mas sobre inteiro — para real, os bits, não o texto.

A combinação é um número em base mista: `k = k * quantos_j + codigo_j`. Duas
colunas de cinquenta valores dão 2.500 combinações possíveis — cabe num vetor, e
aí não há hash nenhum, só indexação direta.

| | |
|---|---|
| produto ≤ 4 milhões | vetor de indexação direta |
| produto cabe em 64 bits | `Dict` na chave em base mista, **exata** |
| nem isso | volta ao texto: lento, e exato |

### O hash que eu quase deixei passar

A primeira versão usava, no caminho de reserva, um **hash** dos códigos como
chave do `Dict`. Duas combinações diferentes com o mesmo hash viram um grupo só,
e o resultado não denuncia — a soma sai errada e parece plausível.

O caminho antigo, com `String`, não tinha esse defeito: `Dict[String, Int]`
compara o texto inteiro. Trocar exatidão por velocidade num agrupamento é o tipo
de regressão que nenhum benchmark mostra.

A chave em base mista é **exata** enquanto o produto couber no inteiro, e é por
isso que ela substitui o hash em vez de acompanhá-lo. Onde não couber, volta ao
texto. Grupo errado não vale ganho de tempo.

### Resultado

| 1M linhas | antes | depois | |
|---|---|---|---|
| grupos por chave composta | 221 ns/linha | **34 ns/linha** | 6,5× |

E o quadro dos operadores, fechado o ciclo:

| | início do ciclo | agora |
|---|---|---|
| grupos por chave dicionarizada | 11 | 13 |
| grupos por chave inteira | 16 | 22 |
| grupos por chave composta | 221 | **34** |
| `agrupar` + 3 agregações | 43 | 18 |
| junção à esquerda | 470 | **66** |
| ordenação estável | 335 | **98** |

### Critério de saída

- [x] chave composta sem `String` por linha e sem formatar float por linha
- [x] os três caminhos exatos — nenhum agrupa por hash
- [x] conferido contra implementação própria do teste, e o caminho de muitas
      combinações tem teste que o alcança
- [x] 234 testes verdes, interoperabilidade nos dois formatos

---

## M18 — Chave inteira: o hash diz onde procurar, não a resposta ✅

Último operador acima do piso. `grupos por chave inteira` fazia 22 ns/linha
contra 11 da chave dicionarizada — pela mesma pergunta, com uma coluna mais
simples.

Três coisas, e nenhuma é o algoritmo:

- `col.eh_ausente(i)` por linha, que lança e extrai bit
- o teste de tipo (`é LÓGICO?`) **dentro** do laço
- `chave in mapa` e depois `mapa[chave]` — **duas buscas** no `Dict` por linha

### Faixa estreita não precisa de hash

O valor é lido uma vez, a máscara de ausência de uma vez, e uma passada acha o
menor e o maior. Se a faixa couber num vetor, o grupo é o próprio valor
deslocado — indexação direta, o mesmo que a coluna dicionarizada já fazia.

| 1M linhas | antes | depois |
|---|---|---|
| 50 valores em 0..49 | 10 ms | **3 ms** |
| 200 mil valores em 0..199.999 | 23 ms | **3 ms** |
| 50 valores espalhados por bilhões | 10 ms | **5 ms** |

O caso de 200 mil grupos é o que mostra o ponto: não é a quantidade de grupos
que pesava, era o `Dict`.

### E quando a faixa é larga

Tabela de endereçamento aberto com a chave **guardada e conferida**. Vale
insistir no porquê, porque é o mesmo erro que quase entrou no M17: um hash sem a
chave ao lado juntaria dois valores diferentes que caíssem no mesmo balde, e o
resultado não denuncia — a soma sai errada e parece plausível.

**O hash diz onde procurar. Quem responde é a comparação da chave.**

### Resultado, e o ciclo dos operadores fechado

| ns/linha, 1M linhas | início do ciclo | agora |
|---|---|---|
| grupos por chave dicionarizada | 11 | 11 |
| grupos por chave inteira | 16 | **11** |
| grupos por chave composta | 221 | **30** |
| `agrupar` + 3 agregações | 43 | **13** |
| junção à esquerda | 470 | **67** |
| ordenação estável | 335 | **91** |

Nenhum operador acima de 100 ns/linha. O que era 470 e 335 hoje são 67 e 91, e
o que era 221 são 30.

### Critério de saída

- [x] chave inteira sem `Dict` no caminho comum e sem decidir tipo por linha
- [x] endereçamento aberto guarda a chave e confere — nunca agrupa por hash
- [x] os dois caminhos cobertos por teste, inclusive o esparso, que não existia
- [x] 236 testes verdes, interoperabilidade nos dois formatos

---

## M19 — Execução em fluxo: 900 ms para fazer o que o normal faz em 88 ✅

O modo em fluxo existe desde o M9 e cumpria o que prometia — pico de memória de
um row group em vez do arquivo inteiro. Só que custava **dez vezes** o modo
normal, e ninguém tinha perguntado por quê. Um número desses no benchmark
público sem explicação é uma dívida.

### Onde estavam os 900 ms

Ler os cinquenta row groups um a um: 62 ms. Filtrar os cinquenta: 38 ms. Cem dos
novecentos. Os outros oitocentos estavam no estado de agregação.

**Uma `String` por linha para identificar o grupo.** Exatamente o que o M17 tirou
do `calcular_grupos`, sobrevivendo aqui. E aqui a `String` não é gratuita de
remover: o estado tem de reconhecer o mesmo grupo em **fatias diferentes**, e o
código de dicionário de um row group não quer dizer nada no seguinte. A
identidade entre fatias é o valor.

A saída não é trocar a chave — é mudar quantas vezes ela é montada. A fatia é
agrupada primeiro pelo mesmo `calcular_grupos` do caminho normal, que já não usa
texto; só depois cada **grupo local** procura o seu global. Cem mil linhas viram
vinte e quatro consultas em vez de cem mil.

**`extrair_coluna` por fatia e por agregação.** A cópia inteira da coluna, uma
vez para cada agregação de cada fatia — três agregações sobre cinquenta row
groups são cento e cinquenta cópias. Agora lê o slab no lugar, com o tipo de
agregação decidido fora do laço.

### Resultado

| 5M linhas, pipeline completo | antes | depois |
|---|---|---|
| `coletar()` | 88 ms | 88 ms |
| `coletar_em_fluxo()` | **900 ms** | **93 ms** |

O modo em fluxo passou a custar o que devia custar desde o começo: praticamente o
mesmo do normal, com pico de memória de um row group. A diferença de 5 ms é o
preço honesto de processar por fatia.

E ele passa a caber na comparação: 93 ms contra 254 do pandas e 138 do Polars,
ambos carregando tudo em memória.

### O que o teste precisava dizer

A mudança altera **como** o grupo é reencontrado entre fatias, então o teste que
faltava é o do grupo que some no meio e volta — com chave ausente junto, que é
onde a identidade é mais fácil de perder. `coletar_em_fluxo(2)` contra
`coletar()`, valor a valor.

### Critério de saída

- [x] fluxo sem `String` por linha e sem cópia de coluna por agregação
- [x] pico de memória inalterado — 13 KiB contra o arquivo inteiro, no bench-m9
- [x] grupo que reaparece em fatia posterior coberto por teste, com ausente
- [x] 237 testes verdes, interoperabilidade nos dois formatos

---

## M20 — Leitura: faixas de row group, e uma cópia que estava lá desde o M13 ✅

Último número desfavorável publicado: a leitura fazia 75 ms contra 54 do pyarrow.

### A ideia era dividir a coluna; o ganho veio de outro lugar

A unidade de trabalho desde o M13 é a coluna. O tempo total é o da coluna mais
cara — e ela costuma ser a de **maior entropia**, que é justamente a que menos
comprime e mais custa a decodificar. No arquivo de 5 milhões, `id` (todos os
valores distintos) levava 51 ms sozinha; `peso` (41 valores repetidos) levava 7.

Então a coluna passou a poder ser dividida em faixas de row group, cada faixa
uma tarefa que continua dona do que precisa. E a medição disse que **quase não
adiantava**: 72–81 ms contra 67–69 sem dividir.

Juntar as faixas custa fixo — alocar e escrever o slab da coluna inteira outra
vez. Com cinco colunas já há threads de sobra, e a junção só atrapalha. Com
duas, é o único jeito de usar os núcleos que sobraram:

| | dividindo | sem dividir |
|---|---|---|
| 5 colunas, 3 faixas cada | 72–81 ms | **67–69 ms** |
| 2 colunas, 8 faixas cada | **35–36 ms** | 42–44 ms |

Daí a regra, que é a medida virada em código: divide-se só quando houver faixas
o bastante — quatro — para a decodificação cair bem abaixo do custo da junção.

### E a cópia que ninguém tinha visto

Investigando por que a versão com faixas ficava *pior* do que devia, apareceu o
que estava errado desde o M13: a coluna pronta era entregue com `.copy()`.
Quarenta MiB copiados por coluna, uma vez por leitura, sem que nada precisasse
disso — o dono anterior morria logo em seguida.

Trocar por mover é uma palavra. Vale mais que toda a divisão em faixas:

| 5M linhas × 5 colunas | antes | depois |
|---|---|---|
| ler tudo | 75 ms | **50 ms** |
| ler 2 de 5 colunas | 42 ms | **27 ms** |
| pipeline completo | 88 ms | **69 ms** |

Fica registrado porque a lição não é sobre `copy()`: **a otimização que não
funcionou foi o que fez a cópia aparecer.** Ela estava escondida atrás de um
número que parecia razoável.

### Onde o Tucano está agora

| 5M linhas, uma thread | Tucano | pandas | Polars | DuckDB |
|---|---|---|---|---|
| ler 5 colunas | 50 ms | 90 ms | 32 ms | 4 ms |
| ler 2 de 5 | 27 ms | 37 ms | 13 ms | 3 ms |
| pipeline completo | **69 ms** | 222 ms | 137 ms | 91 ms |

Na leitura o Tucano encostou no pyarrow (50 contra 48) e passou o pandas por
1,8×. No pipeline completo passa o pandas por 3,2×, o Polars por 2× e o DuckDB
por 1,3× — todos em uma thread.

O que separa do Polars e do DuckDB na leitura pura é decodificação madura, e do
DuckDB em dezesseis núcleos é paralelismo além do que a leitura já usa.

### Critério de saída

- [x] coluna divisível em faixas de row group, com a regra vinda da medição
- [x] nenhuma cópia de coluna inteira no caminho de leitura
- [x] o caminho dividido é exercitado por teste — antes nenhuma fixture chegava
      ao limiar — e conferido contra a fórmula que gerou os dados
- [x] 237 testes verdes, interoperabilidade nos dois formatos

---

## M21 — Leitura: a decisão de paralelizar olhava a coisa errada ✅

Alvo: fechar a distância para o Polars na leitura pura, 50 ms contra 32.
**Não fechou.** O que se achou no caminho vale mais que a tentativa.

### A decisão contava colunas, não tarefas

Desde o M20 uma coluna pode virar várias faixas de row group. Mas a decisão de
usar thread continuou sendo tomada **antes das faixas existirem**, pelo número
de colunas — e `threads_para(1, ...)` devolve 1 por definição. Ler **uma** coluna
dividida em dezesseis faixas mandava as dezesseis para o caminho sequencial.

| ler `id` sozinha, 5M linhas | antes | depois |
|---|---|---|
| | 29–36 ms | **16–17 ms** |

Column pruning é a razão de o Parquet existir, e ler poucas colunas é o caso
comum de verdade. Ele estava sem paralelismo nenhum.

### O `join` em série virou escrita em paralelo

Juntar as faixas depois do `join` custava 18–20 ms: alocar e escrever os quarenta
MiB do slab em série, com a falha de página inteira num núcleo só. Agora o pai
aloca o slab uma vez e **cada faixa escreve na sua parte** — trechos de linha
contíguos e disjuntos, dados pelo rodapé. A falha de página se divide junto.

E mais duas cópias de coluna inteira saíram do caminho de coleta, irmãs da que o
M20 achou. Elas continuam aparecendo pelo mesmo motivo: `copy()` é curto de
escrever e não parece custar nada.

### O que não cedeu, e por quê

Ler as cinco colunas continua em 48–49 ms. Dividi-las mais **piora**:

| 5 colunas, 5M linhas | |
|---|---|
| sem dividir (5 threads) | **48 ms** |
| 3 faixas por coluna (15 threads) | 63–64 ms |

Lida sozinha, `id` leva 16 ms; junto das outras quatro, o conjunto leva 48. O
limite aqui é banda de memória, não núcleo ocioso — cinco threads expandindo
Snappy ao mesmo tempo já saturam o que a máquina entrega. É o mesmo teto que
recusou o paralelismo dos operadores no M15.

### Onde ficou

| 5M linhas, uma thread | Tucano | pandas | pyarrow | Polars |
|---|---|---|---|---|
| ler 5 colunas | 49 ms | 93 ms | 49 ms | 31 ms |
| ler 2 de 5 | 30 ms | 35 ms | 23 ms | 13 ms |

Empatado com o pyarrow, 1,9× à frente do pandas. A distância para o Polars é
maturidade de decodificação — não é uma cópia esquecida nem um núcleo parado, e
dizer isso exige ter procurado as duas coisas.

### Critério de saída

- [x] a decisão de paralelizar olha o número de tarefas
- [x] faixas escrevem no slab final; não há junção em série
- [x] nenhuma cópia de coluna inteira sobrou no caminho de leitura
- [x] 237 testes verdes, interoperabilidade nos dois formatos

---

## M22 — "Maturidade de decodificação": o que essa frase escondia ✅

O M21 fechou dizendo que a distância para o Polars era *maturidade de
decodificação*. Frase confortável — e do mesmo tipo de "a linguagem proíbe", que
já esteve errada aqui por vários marcos. Este marco não otimizou nada: **mediu o
que a frase escondia e recusou duas tentativas.** É o resultado.

### Onde o tempo está, com número

A mesma coluna de 5 milhões de inteiros, escrita das duas formas:

| | tamanho | ler |
|---|---|---|
| `compressao="nenhuma"` | 38 MiB | **5 ms** |
| `compressao="snappy"` (padrão) | 19 MiB | 28 ms |

Descomprimir custa **23 ms para 38 MiB — 1,6 GB/s**. E no arquivo inteiro de
cinco colunas: 43 MiB em Snappy lêem em 48 ms; os mesmos dados sem compressão,
124 MiB, lêem em **35**.

Ou seja: com o arquivo em cache de página, o nosso Snappy custa mais do que a
E/S que ele poupa. Em disco lento a conta se inverte — 3× menos bytes para ler.
O padrão continua Snappy porque otimizar para cache quente seria otimizar para o
benchmark, não para quem usa.

### O que o fluxo Snappy tem dentro

Instrumentado sobre uma coluna de inteiros sequenciais, que é o que o Snappy mais
comprime:

| | |
|---|---|
| saída vinda de literais | 13% |
| saída vinda de **cópias** | 87% |
| comprimento médio da cópia | **7 bytes** |
| cópias com distância < 16 | **99,99%** |

Quatro milhões e setecentas mil cópias de sete bytes. A 23 ms, são ~12 ciclos por
elemento — o custo é a **quantidade de elementos**, não o laço de bytes dentro de
cada uma.

### Duas tentativas, as duas recusadas pela medição

**Dobrar o padrão** para copiar em bloco quando a distância é curta: implementado,
e estava **errado** — o dobramento não muda a distância de leitura, só reorganiza
o mesmo laço. Os testes pegaram, e ainda ficou mais lento (37 ms contra 28).

**Bloco do tamanho da distância** — com distância 8 e comprimento 7 não há
sobreposição, então cabe um `store` de 8 bytes, com folga no fim do buffer para o
excesso. Correto desta vez, e os testes passaram. Também **mais lento**: 59–66 ms
contra 50 no arquivo completo.

As duas confirmam o mesmo: o gargalo é decodificar seis milhões de elementos, e
mexer no que cada elemento faz com sete bytes não move o número.

### O que a frase realmente quer dizer

Fechar a distância exige o que as implementações maduras de Snappy fazem: leitura
do tag e do deslocamento numa carga de 64 bits só, despacho por tabela em vez de
desvio, e o laço escrito para não ter dependência entre iterações. É trabalho de
verdade, não uma cópia esquecida nem um núcleo parado — e agora está dito com o
número ao lado, em vez de como adjetivo.

### Critério de saída

- [x] o custo da descompressão medido e separado do resto da leitura
- [x] a composição do fluxo Snappy medida, não suposta
- [x] as duas otimizações construídas, medidas e recusadas
- [x] nenhuma linha de código pior entrou; 237 testes verdes

---

## M23 — As três técnicas dos maduros, medidas ✅

O M22 nomeou o que faltava: tag e deslocamento numa carga de 64 bits, despacho
por tabela, laço sem cadeia de desvios. As três foram implementadas. **As três
ficaram mais lentas.**

| ler a coluna `id` (19 MiB Snappy → 38 MiB) | |
|---|---|
| como está | **28 ms** |
| despacho por tabela + carga de 64 bits | 38 ms |
| só a carga de 64 bits, sem tabela | 45 ms |
| bloco do tamanho da distância, com folga (M22) | 29 ms |

E no arquivo de cinco colunas: 50 ms como está, 59–60 com tabela.

### Por que não transfere

Isolando as duas metades, a **carga larga** é a cara. Para a cópia mais comum —
tipo 1, que é 87% dos elementos — o decodificador precisa de exatamente **um**
byte além do tag. Trocar um `load` de um byte por um de oito, mais máscara, mais
um desvio para não passar do fim do buffer, é estritamente mais trabalho.

A técnica existe para eliminar uma cadeia de desvios que aqui já não existe: os
`load` por ponteiro do Tucano não têm checagem de limite, e o compilador já emite
para o caso simples um código que a versão "madura" não melhora. O playbook
pressupõe um gargalo que este decodificador não tem.

Doze ciclos por elemento, para ler o tag, ler o deslocamento e mover sete bytes,
é aproximadamente uma operação de memória por ciclo. Não há folga escondida ali.

### O que a medição aponta em vez disso

O erro é anterior ao Snappy. Uma coluna de inteiros sequenciais em **PLAIN** dá
ao Snappy 40 MiB nos quais só os bytes baixos mudam — e ele responde com seis
milhões de cópias de sete bytes. O decodificador está fazendo bem um trabalho que
não deveria existir.

O Parquet tem `DELTA_BINARY_PACKED` exatamente para isso: a mesma coluna vira
alguns bits por valor, sem elemento Snappy nenhum para decodificar. **O caminho
não é um Snappy mais rápido, é um fluxo mais curto** — e isso é o escritor, não o
leitor.

### Critério de saída

- [x] as três técnicas implementadas e medidas, não descritas
- [x] a metade cara isolada — é a carga larga, não a tabela
- [x] nenhuma linha mais lenta entrou; 237 testes verdes
- [x] o próximo passo nomeado com o motivo, e ele é no escritor

---

## M24 — Escritor com DELTA_BINARY_PACKED ✅

O M23 mediu e concluiu: o erro é anterior ao Snappy. Uma coluna de inteiros
sequenciais em PLAIN entrega 40 MiB nos quais só os bytes baixos mudam, e o
Snappy responde com seis milhões de cópias de sete bytes que o leitor tem de
refazer uma a uma. **O caminho não é um Snappy mais rápido, é um fluxo mais
curto.**

### O que muda

Coluna inteira passa a poder ser escrita em `DELTA_BINARY_PACKED`: guarda a
diferença, não o valor. Cabeçalho com tamanho do bloco, miniblocos, contagem e
primeiro valor; depois, por bloco, a **menor** diferença e a largura de cada
minibloco — subtraindo a menor, o que sobra é não negativo e costuma caber em
pouquíssimos bits.

| | PLAIN | delta |
|---|---|---|
| 1000 inteiros crescentes | 8000 bytes | **46** |
| 333 em progressão | 2664 bytes | **21** |
| 128 iguais | 1024 bytes | **11** |
| 200 ruidosos | 1600 bytes | 582 |

Não entra por regra, entra por medida: o escritor codifica dos dois jeitos e usa
o delta só quando ele encolhe. Escrita se paga uma vez; leitura, sempre.

### Resultado

| 5M linhas × 5 colunas | antes | depois |
|---|---|---|
| arquivo | 43 MiB | **25 MiB** |
| ler a coluna `id` sozinha | 28 ms | **7 ms** |
| ler as 5 colunas | 49 ms | 48 ms |

A leitura de uma coluna inteira ficou **4× mais rápida**, e o arquivo encolheu
42% para qualquer leitor — o pyarrow lê os arquivos novos, verificado, inclusive
com ausentes. As cinco colunas juntas não mudaram: ali o gargalo passou a ser as
duas colunas reais, que o delta não cobre.

### O laço que comia a memória

Escrever o codificador derrubou o processo — e o culpado não era o código novo.

```mojo
while True:
    var b = v & 0x7F
    v >>= 7          # deslocamento ARITMETICO
    if v != 0: ...
```

`_varint_para` existia desde o M5 e só recebia valores não negativos. Com um
negativo, `>>= 7` converge para `-1` **e fica lá**: `v != 0` nunca falha, e o
laço escreve bytes até a memória acabar. O processo morre com SIGKILL, sem dizer
por quê — foi assim que a suíte inteira passou a cair.

O zigzag foi o primeiro a lhe entregar um negativo: `valor << 1` estoura perto
do teto do Int64. Limpar os sete bits do topo depois do deslocamento é o que
transforma o aritmético em lógico — e de quebra faz o valor grande ser escrito
certo em vez de truncado.

`_dezigzag` tinha o mesmo defeito na volta, e valores perto do teto voltavam
errados. `thrift.mojo` tem os dois na mesma forma; não consegui construir um
caso que os alcance hoje — as estatísticas do Parquet vão em binário, e os
campos que usam zigzag são deslocamentos e contagens, sempre pequenos — mas a
armadilha está a um campo de distância, e foi fechada.

### O que o codec recusa

Diferença que não cabe em 64 bits com sinal, e largura acima de 56 bits. Nos
dois casos a coluna vai em PLAIN. Recusar é mais barato que fingir que coube: o
empacotador junta bits num inteiro de 64 antes de despejar bytes, e uma largura
perto de 64 estouraria o acumulador em silêncio.

### Critério de saída

- [x] escritor emite delta quando ele encolhe, medindo em vez de supor
- [x] leitor entende `DELTA_BINARY_PACKED`, com e sem ausentes
- [x] pyarrow lê os arquivos novos — a fixture `grupos` já os exercita
- [x] ida e volta coberta nos extremos: vazio, um valor, constante, bloco
      incompleto, e valores no teto do Int64
- [x] 240 testes verdes

---

## M25 — Dicionário também para coluna numérica ✅

Depois do M24 a leitura das cinco colunas era, quase inteira, uma coluna só:
`valor` ocupava 22 dos 25 MiB e 27 dos 38 ms. São 9973 valores distintos em cinco
milhões de linhas — caso de dicionário, que o escritor só fazia para texto.

O leitor **sempre** soube ler dicionário de qualquer tipo. Faltava o escritor
emitir.

### O critério é o tamanho, calculado

Coluna toda distinta — uma chave, um carimbo de tempo — não dicionariza: o
dicionário seria a coluna inteira mais os códigos. A decisão compara os dois
tamanhos com a conta exata (distintos × 8 + códigos empacotados contra valores em
PLAIN), e é a mesma disciplina do delta no M24: medir, não supor.

### Resultado

| 5M linhas × 5 colunas | M23 | M24 (delta) | agora |
|---|---|---|---|
| arquivo | 43 MiB | 25 MiB | **12 MiB** |
| ler as 5 colunas | 49 ms | 48 ms | **39 ms** |

| ler 5 colunas, uma thread | Tucano | pandas | pyarrow | Polars |
|---|---|---|---|---|
| | **39 ms** | 76 ms | 43 ms | 31 ms |

O arquivo encolheu **72%** desde o M23, e a leitura passou o pyarrow pela
primeira vez. O que separa do Polars caiu de 18 ms para 8.

`id` continua em delta e `valor`/`peso` passam a dicionário — cada coluna recebe
o que a mede melhor. O pyarrow lê tudo, verificado valor a valor.

### Critério de saída

- [x] escritor emite dicionário para coluna numérica quando ele encolhe
- [x] a escolha vem da conta dos dois tamanhos, não de um limiar chutado
- [x] pyarrow lê as colunas novas — `RLE_DICTIONARY` em real e inteiro
- [x] 240 testes verdes, interoperabilidade nos dois formatos

---

## M26 — A divisão em faixas saiu ✅

O M20 dividiu a coluna em faixas de row group, o M21 consertou a decisão que a
mandava para o caminho sequencial, e o M25 tornou as duas coisas inúteis.

Ler **três** colunas custava 58 ms; ler **cinco**, 39. A diferença: com três, a
divisão liga (16 núcleos ÷ 3 = 5 faixas, acima do limiar); com cinco, não liga.
O limiar de quatro faixas foi medido no arquivo de 43 MiB — o de hoje tem 12, e
decodificar ficou tão barato que juntar as faixas nunca se paga.

| ler, 5M linhas | com divisão | sem |
|---|---|---|
| 1 coluna | 13 ms | **8 ms** |
| 2 colunas | 27 ms | **19 ms** |
| 3 colunas | 39 ms | **19 ms** |
| 5 colunas | 21 ms | 20 ms |

Melhor ou igual em todos. **285 linhas a menos**, e são as mais perigosas do
leitor: a divisão era onde as tarefas escreviam num destino compartilhado por
endereço cru, sem verificação de tempo de vida. Saiu junto.

O pipeline completo caiu de 76 para 65–72 ms, porque ele poda para três colunas —
justamente o caso que dividia e perdia.

### E a thread por coluna? Neutra, e fica

Medido no mesmo arquivo, com `TUCANO_THREADS=1` contra o padrão: **idêntico**.
Também num Parquet de 62 MiB escrito pelo pyarrow em PLAIN + Snappy, que é a
forma cara de decodificar: 45 ms dos dois jeitos.

A leitura ficou **limitada por banda de memória**, não por CPU — as codificações
do M24 e do M25 tiraram tanto trabalho do decodificador que sobrou só mover
bytes. Oito threads entregam ~1,75× mais banda que uma nesta máquina, e o resto
do ganho some na alocação.

A divisão saiu porque perde por motivo **estrutural** — uma alocação e uma cópia
da coluna inteira, em qualquer máquina. A thread por coluna fica porque empata
por motivo **desta máquina**: onde houver mais banda por núcleo, o decodificador
volta a ser o limite. Ela não custa complexidade perigosa: cada tarefa é dona de
tudo que usa, e não há um mutex sequer.

### Critério de saída

- [x] a divisão em faixas removida, com a medição que a condena registrada
- [x] nenhuma tarefa escreve em memória de outra — o endereço cru saiu junto
- [x] a thread por coluna medida contra `TUCANO_THREADS=1`, e mantida com o motivo
- [x] 243 testes verdes, oito passos de verificação verdes

---

## M27 — A escrita, medida ✅

Depois do M24 e do M25 o escritor passou a tentar duas codificações por coluna.
Escrever 5M × 5 leva 1,29 s, contra 470 ms do pyarrow — mas o arquivo sai com
12 MiB contra 40. Antes de decidir se isso é dívida, medir onde o tempo está.

### Três palpites errados, e depois o perfil

Tentei, nesta ordem: tirar a codificação delta duplicada, recortar a fatia em
bloco em vez de gather, e trocar o `eh_ausente` por linha por uma leitura da
máscara. As duas primeiras ajudaram pouco; a terceira **piorou** — `para_bytes()`
aloca por chamada, e chamá-la em cinco lugares custou mais que os testes que ela
economizava. Saiu.

> **Corrigido no M31.** A terceira tentativa foi arquivada com a hipótese junto:
> a alocação por chamada era incidental, e a mesma pergunta feita por
> `contar_ausentes()` — que é O(1) — vale 430 → 241 ms.

Só então instrumentei, em vez de continuar adivinhando:

| fase | ms |
|---|---|
| montar o dicionário numérico | **308** |
| montar a página (níveis + valores) | 230 |
| comprimir com Snappy | 163 |
| recortar a fatia | 117 |
| min/max para as estatísticas | 126 |
| codificar em delta | 50 |
| resto (rodapé, buffer, escrita) | ~250 |

Nada disso é desperdício: é o custo de escolher a codificação medindo, que é o
que produz o arquivo três vezes menor. **O escritor não tem gordura — tem
trabalho.**

### E as codificações deixam a escrita mais rápida, não mais lenta

Desligando as duas, o mesmo arquivo leva **2,68 s** e ocupa 43 MiB. PLAIN entrega
ao Snappy três vezes e meia mais bytes para comprimir, e comprimir é o que custa.

Ou seja: escolher a codificação **paga a si mesma na própria escrita**, antes de
o primeiro leitor abrir o arquivo.

### O que ficou

Duas melhorias medidas: o delta deixou de ser codificado duas vezes (368 → 315 ms
na coluna `id`, porque quem decidia jogava fora o resultado) e a fatia contígua
virou dois `memcpy` em vez de um gather com lista de índices (146 → 117 ms).

O resto fica como está, com o perfil registrado. Somos 2,7× mais lentos que o
pyarrow para escrever, e o arquivo é 3,3× menor — a escrita se paga uma vez, a
leitura se paga sempre.

### Critério de saída

- [x] o custo da escrita medido por fase, não estimado
- [x] o que melhorou entrou; o que piorou saiu
- [x] a comparação com o pyarrow publicada com os dois lados: tempo e tamanho
- [x] 243 testes verdes, oito passos de verificação verdes

---

## M28 — Slab de data em Int32 ✅

A dívida nº 4 estava adiada por medida desde o M27, com três implementações
possíveis e nenhuma escolhida. O dono do projeto escolheu a terceira: **o slab
carrega a própria largura**.

### A forma

`SlabInteiro` é `bytes` + `largura` + `n`. Data usa largura 4; inteiro e datahora,
8. A `Coluna` não ganhou campo nenhum — trocou `List[Int64]` por `SlabInteiro` no
campo que já existia, que é exatamente o que o sexto `List` paralelo evitava.

Quem lê no caminho quente decide pela largura **uma vez, fora do laço**:

```mojo
if col.ints.largura == 4:
    var p32 = col.ints.bytes.unsafe_ptr().unsafe_bitcast[Int32]()
    ...
```

Os quatro kernels de inteiro (`soma_i64_densa`, `soma_i64`, `minimo_i64`,
`maximo_i64`) ganharam essa bifurcação, e a compactação do executor também.

### O prêmio, conferido

| | Int64 | Int32 |
|---|---|---|
| 5M datas em memória | 38 MiB | **19 MiB** |
| ler 5M datas do Parquet | 10 ms | **9 ms** |

Metade da memória, mesmo tempo — a bifurcação por largura fora do laço não custa,
como o M27 já tinha medido em separado. Os benchmarks do projeto não têm coluna de
data e não se moveram: leitura 42 ms, pipeline 65 ms, fluxo 88 ms.

### O que ficou mais estrito

`SlabInteiro.de_dias` **recusa** o que não cabe em 32 bits em vez de truncar.
Estreitar em silêncio devolveria uma data errada, e data errada não denuncia —
parece uma data. A faixa cobre uns cinco milhões de anos para cada lado da epoch,
então a guarda nunca dispara em uso real; ela existe para o dia em que alguém
alimentar a coluna com microssegundos por engano.

### O teste novo achou um defeito do M25

Escrever uma coluna de data com poucos valores distintos produzia um arquivo que o
**pyarrow lia errado**: metade das linhas voltava como 1970-01-01. O escritor
emitia a página de dicionário com **oito bytes por valor** numa coluna cujo tipo
físico é INT32 — o leitor de fora via o dobro de entradas, metade delas zero.

O defeito é do M25, não do M28: `_valores_plain_dicionario_numerico` sempre
escreveu oito bytes, e `_tipo_parquet(DATA)` sempre devolveu INT32. Ficou invisível
porque a fixture `temporal` tem **três linhas** — poucas para dicionarizar e poucas
para o delta. Interoperabilidade só prova o que o arquivo exercita.

Três coisas entraram junto:

- o dicionário numérico carrega a própria largura, pela mesma razão que o slab;
- a conta que decide entre dicionário e PLAIN passou a usar 4 bytes por valor em
  data, e não 8 — antes o dicionário parecia barato em casos onde não era;
- o delta em coluna de data é recusado acima de **32 bits** por minibloco, que é o
  teto do tipo físico; a recusa vira PLAIN, que sempre cabe.

E uma fixture nova, `datas.parquet`, com 400 linhas em quatro colunas: repetida
(dicionário), crescente (delta), espalhada com buracos (delta + níveis) e um
carimbo de tempo. Verificada pelo pyarrow no `verificar_tudo.sh`.

### O custo, dito

As factories de inteiro deixaram de **assumir** a `List` recebida: agora copiam uma
vez para dentro do slab de bytes. É o preço da largura variável — um `List[Int64]`
não vira `List[UInt8]` sem copiar. Não apareceu em nenhum benchmark, mas está aqui
porque o CONTRATO prometia o contrário e foi corrigido.

### Critério de saída

- [x] data ocupa 4 bytes por linha; inteiro e datahora, 8
- [x] a largura é decidida fora do laço em todos os kernels
- [x] estreitar fora da faixa levanta erro, não trunca
- [x] data sobrevive a ordenação, agrupamento, filtro e às duas idas e voltas
- [x] o arquivo escrito com data dicionarizada é lido pelo pyarrow
- [x] 246 testes verdes, oito passos de verificação verdes

---

## M29 — Escrita paralela por coluna ✅

O M27 mediu a escrita e concluiu que o escritor **não tem gordura — tem
trabalho**: montar o dicionário, montar a página, comprimir, calcular min/max.
Nenhuma dessas fases é desperdício, e por isso nenhuma some. Mas todas elas são
**por coluna**, e colunas não dependem umas das outras.

É a mesma observação que destravou a leitura no M13, aplicada do outro lado.

### O que mudou

O corpo do laço `for g / for c` virou uma função — `_codificar_pedaco` — que
recebe a fatia e devolve os bytes prontos, com os offsets **relativos ao próprio
pedaço**. Foi isso que permitiu codificar fora de ordem: se cada tarefa
precisasse saber onde vai cair no arquivo, teria de esperar a anterior terminar,
que é exatamente o que se queria evitar.

O row group volta a ser montado em série, na ordem certa, somando a base a cada
offset relativo. Recortar a fatia também ficou em série de propósito: o recorte
já é um `memcpy`, e mandar a thread recortar só mudaria quem paga a mesma cópia.

### Medido

5M × 5 colunas, menor de três, `bench-escrita`:

| | serial | por coluna |
|---|---|---|
| um row group (5 tarefas grandes) | 1568 ms | **925 ms** |
| grupos de 100k (50 × 5 tarefas) | 1227 ms | **594 ms** |

E contra as outras implementações, com o tamanho do arquivo ao lado — que é o
número que falta quando alguém publica só o tempo:

| grupos de 100k | ms | MiB |
|---|---|---|
| Tucano | **594** | **12,0** |
| pyarrow | 474 | 40,8 |
| Polars | 81 | 43,8 |

De 2,6× mais lento que o pyarrow para 1,25×, com um arquivo 3,4× menor. O Polars
escreve em um sétimo do tempo e produz 3,6× mais bytes.

### O pico de memória não subiu

Era a objeção óbvia: cinco threads montando páginas ao mesmo tempo seguram cinco
buffers em vez de um. Medido, o pico **caiu** — 1,29 GiB contra 1,35. O escritor
serial acumulava tudo num `List` único que dobra de tamanho ao crescer; os
pedaços por coluna são menores e o arquivo final recebe cada um por `memcpy`.

### O que não entrou

Uma tarefa por *row group* em vez de por coluna. Com 50 grupos daria mais
paralelismo, mas cada tarefa precisaria do seu pedaço do arquivo em ordem, e a
montagem voltaria a ser o gargalo. A forma por coluna já satura os núcleos que o
workload justifica.

### Critério de saída

- [x] a codificação de uma coluna não olha para nada fora da fatia
- [x] o caminho sequencial e o paralelo passam pela mesma função
- [x] `bench-escrita` no repositório, dos dois lados — o número do M27 era de um
      script solto
- [x] o arquivo escrito em paralelo é byte a byte o mesmo do serial
- [x] 246 testes verdes, oito passos de verificação verdes

---

## M30 — A escrita, em ondas ✅

O M29 pôs uma thread por coluna e parou aí. Com cinco colunas num row group,
isso usa cinco núcleos de dezesseis. Medindo por fase o que sobrou de 626 ms:

| fase | ms |
|---|---|
| recortar as fatias (serial) | 137 |
| codificar (5 threads) | 356 |
| montar o arquivo (serial) | **90** |
| rodapé, buffer, escrita | ~43 |

### Os 90 ms de montagem eram quadráticos

Concatenar os pedaços num `List` que cresce parecia inocente. Não é: o `resize`
realoca para o tamanho pedido, então cada um dos 250 pedaços copiava o arquivo
inteiro de novo. Medido em separado, juntar 12 MiB em 250 pedaços:

| forma | µs |
|---|---|
| `resize` a cada pedaço | 62 502 |
| `reserve` uma vez, `resize` a cada pedaço | 5 979 |
| **uma alocação do tamanho final, `memcpy` no lugar** | **604** |

Os pedaços ficam separados até o fim, o rodapé é montado antes, e o arquivo é
alocado uma vez com o tamanho exato. 626 → 554 ms.

### Ondas: os row groups também são independentes

Como os offsets de cada pedaço são relativos a ele mesmo (M29), row groups
diferentes podem ser codificados ao mesmo tempo — a ordem só importa na
montagem. A onda tem tamanho porque cada grupo em voo segura a sua fatia da
tabela viva; sem teto, codificar em paralelo viraria copiar a tabela inteira.

| grupos por onda | ms |
|---|---|
| 1 (só por coluna) | 554 |
| 2 | 433 |
| 4 | 389 |
| 6 | 371 |
| **8** | **349** |
| 12 | 357 |
| 16 | 394 |

A curva achata perto de oito, e a política ficou em `grupos_por_onda()`: duas
tarefas por núcleo, limitadas por um teto de 2 milhões de linhas em voo.

### O padrão de row group mudou — 500 mil linhas

Um arquivo inteiro num row group só era o padrão antigo, e era o pior dos dois
lados: a leitura em fluxo não tinha granularidade nenhuma (o "pico de um row
group" era o arquivo inteiro) e a escrita não tinha o que paralelizar além das
colunas. Medido, 5M × 5:

| por grupo | escrita | arquivo | leitura |
|---|---|---|---|
| tudo num grupo | 1002 ms | 9,6 MiB | 43 ms |
| 2.000.000 | 798 | 9,7 | 43 |
| 1.000.000 | 584 | 9,8 | 42 |
| **500.000** | **424** | **10,1** | **36** |
| 250.000 | 358 | 10,6 | 38 |
| 100.000 | 321 | 12,0 | 40 |
| 50.000 | 330 | 14,5 | 43 |

Grupo menor escreve mais rápido e ocupa mais: cada grupo carrega o próprio
dicionário, e dicionário repetido é o que engorda o arquivo. Em 500 mil o
arquivo cresce 5% sobre o mínimo, a escrita fica 2,4× mais rápida e a leitura é
a mais rápida da tabela. `0` continua querendo dizer "tudo num grupo".

O que isso custa está dito: a leitura em fluxo passa a segurar 500 mil linhas em
vez de 100 mil por pico, e mede 93 ms contra 90.

### Onde a escrita chegou

5M × 5, no padrão de hoje:

| | ms | MiB |
|---|---|---|
| Tucano | **430** | **10,1** |
| pyarrow | 430 | 31,9 |
| Polars | 92 | 43,6 |

**Mesmo tempo do pyarrow, arquivo 3,2× menor.** Era 2,7× mais lento no M27.

### O que sobrou, medido e não feito

Perfilando de novo no padrão de hoje, dos ~500 ms de uma execução avulsa:

| fase | ms |
|---|---|
| recortar as fatias (**serial**) | 144 |
| codificar (20 tarefas em onda) | 300 |
| montar, rodapé, escrita | ~65 |

Recortar é agora a maior parcela serial — 28% da escrita — e não é trabalho
necessário: a fatia existe só para a tarefa ter o que levar consigo. As duas
saídas conhecidas:

1. **Recortar dentro da tarefa.** Exige que a tarefa alcance a coluna de origem,
   e uma struct de tarefa não pode ter campo com origin apagada — passaria o
   endereço como `Int`, reconstruído dentro do trabalhador (é o que `_do_ambiente`
   já faz com o `getenv`). Só leitura, e o `join` acontece antes de a tabela
   morrer. Ganho estimado: ~100 ms.
2. **Não recortar.** Passar `(coluna, ini, fim)` para as oito funções de
   codificação, que hoje varrem `0..n`. Tira a cópia em vez de paralelizá-la —
   ~144 ms e a memória das fatias — mas mexe em todo o caminho de escrita, e
   depende igualmente do endereço da coluna de origem.

Nenhuma das duas entrou hoje: as duas trocam a invariante que faz o desenho
paralelo ser simples ("a tarefa é dona de tudo que usa") por 20% da escrita, e
essa troca merece ser feita de propósito, não de passagem. Fica medida.

### Critério de saída

- [x] a montagem do arquivo deixou de ser quadrática, com o número medido
- [x] a política de onda mora em `paralelo.mojo`, com a tabela que a escolheu
- [x] o padrão de row group é medido, não herdado
- [x] o arquivo sai byte a byte igual ao da versão serial
- [x] o que sobrou está perfilado, com as saídas descritas e o custo delas
- [x] 246 testes verdes, oito passos de verificação verdes

---

## M31 — A pergunta que se fazia por linha ✅

O M27 tentou tirar o `eh_ausente` por linha do escritor e **mediu pior**: 1285 →
1471 ms. Diagnosticou certo — `para_bytes()` da máscara aloca a cada chamada, e
a versão a chamava em cinco lugares — e parou ali. O diagnóstico apontava para
uma causa **incidental**, não para a ideia, e mesmo assim a ideia foi arquivada
junto com a implementação.

A mesma pergunta tem uma forma que não aloca nada: `contar_ausentes()`, que é
O(1). Perguntada **uma vez por coluna**, fora do laço.

### Três lugares, medidos um a um

| | padrão (500k) | tudo num grupo |
|---|---|---|
| depois do M30 | 430 ms | 1012 ms |
| níveis de definição sem lista | 400 | 895 |
| dicionário, estatísticas e "presentes" | 360 | 776 |
| recorte sem lista de ausentes | **244** | **559** |

**Os níveis.** Uma coluna sem ausentes tem meio milhão de níveis iguais a 1, que
existem só para virar um trecho RLE de três bytes. `codificar_rle_constante()`
escreve esse trecho sem a lista — é o espelho de escrita do `rle_valor_unico()`
que o leitor já usava para a mesma pergunta.

**O recorte.** `_fatiar` montava um `List[Bool]` de n posições para dizer que
nenhuma linha falta. Lista de ausentes vazia já quer dizer "todos presentes" nas
factories da `Coluna`; numa coluna sem ausentes não há o que montar.

**O resto.** `_dicionario_numerico`, `_stats_de_coluna`, `_inteiros_presentes`,
`_indices_presentes` e `_valores_plain` passaram a perguntar uma vez e guardar a
resposta num `Bool` local.

### Onde a escrita ficou

| 5M × 5, row groups de 500k | ms | MiB |
|---|---|---|
| Tucano | **241** | **10,1** |
| pyarrow | 436 | 31,9 |
| Polars | 96 | 43,6 |

**1,8× mais rápido que o pyarrow, com arquivo 3,2× menor.** No M27 era 2,7×
_mais lento_. O arquivo continua saindo byte a byte igual, conferido com `cmp`.

### A lição, que é sobre resultado negativo

O M27 fez a parte difícil — mediu, viu piorar, e achou a razão. Faltou o passo
seguinte: quando a razão de uma medida ruim é **incidental** (uma alocação, um
`copy()`, um buffer temporário), o que morreu foi aquela implementação, não a
hipótese. Arquivar as duas juntas custou aqui 189 ms por escrita durante quatro
marcos.

É primo do erro que o M13 corrigiu no paralelismo, e a regra é a mesma:
o registro de um resultado negativo tem de separar **o que falhou** de **por que
falhou**, e dizer explicitamente se a hipótese continua de pé.

### Critério de saída

- [x] cada um dos três passos medido em separado
- [x] o arquivo sai byte a byte igual ao de antes
- [x] o resultado negativo do M27 corrigido no lugar onde está escrito
- [x] 246 testes verdes, oito passos de verificação verdes

---

## M11 — GPU [experimental]

Trilha paralela, **fora** do caminho crítico. Só depois de Filter / GroupBy / Aggregate / Sort estarem maduros na CPU, e só onde o workload justificar.

---

## Tucano 1.0 — definição de pronto

**Core** — Tabela, Coluna, schema, Int/Float/Bool/String/Data, NA de três valores, memória columnar

**Expressions** — coluna, literais, comparação, aritmética, booleanos, coluna derivada

**Execution** — filter, projection, expression, sort, aggregation

**Analytics** — groupby, join, concat, resumo, estatísticas básicas

**I/O** — CSV (leitura e `para_csv`), Parquet (column pruning + predicate pushdown + distinct_count + Snappy na escrita), `.xlsx` (`ler_xlsx` e `para_xlsx`)

**SQL** — SELECT/WHERE/GROUP BY/HAVING/ORDER BY/LIMIT, JOIN (`USING`) e COUNT(DISTINCT), sobre o mesmo planner

**Performance** — SIMD, dictionary encoding (leitura e escrita), streaming, predicate pushdown, benchmarks públicos, leitura multithread.

**Distribuição** — pacote instalável, README, documentação de API

**Fora do 1.0** — Python, clonagem de API alheia, GPU obrigatória, servidor HTTP / dashboard nativo

---

## API de destino

```mojo
from tucano import ler_parquet, coluna, lit, soma, mes, para_csv, para_xlsx

def main() raises:
    var vendas = ler_parquet("vendas.parquet")

    var resumo = vendas
        .onde(coluna("valor").gt(lit(1000)))
        .com_coluna("mes", mes(coluna("data")))
        .agrupar(["cidade", "mes"])
        .agregar([soma("valor")])

    resumo.mostrar()
    resumo.para_parquet("saida.parquet")
    para_csv(resumo, "saida.csv")
    para_xlsx(resumo, "saida.xlsx")
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
11. ~~Reavaliar paralelismo~~ — reavaliado de novo, e **a conclusão de bloqueio estava errada**: M13
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
22. ~~**Próximo com retorno:** `para_xlsx`~~ — M14
