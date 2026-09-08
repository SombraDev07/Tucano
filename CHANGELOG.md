# Changelog

Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/).
Versionamento semantico a partir da 1.0; ate la, `0.MARCO.PATCH`.

## [0.5.0] — M4: SIMD + dictionary encoding

Ganhos medidos contra o laco escalar equivalente (n = 5M, AVX2, `pixi run bench-m4`):
soma 2,33x | comparacao 3,07x | mes(data) 4,70x | `cidade == "SP"` 4,21x |
`a + b` 1,29x (memory-bound).

### Adicionado

- **`tucano/kernels.mojo`** — kernels SIMD sobre slabs contiguos. Isolado de proposito:
  o `DType` la e o **do Mojo** (parametro de `SIMD`), nao o tipo logico do Tucano.
  Aritmetica, comparacao, logica de tres valores, selecao, reducoes e calendario.
- **Dictionary encoding** em coluna de texto com repeticao: valores distintos em
  `textos` + um `Int32` por linha em `codigos`. `cidade == "SP"` resolve o literal
  para um codigo UMA vez e o filtro vira comparacao de inteiros vetorizada.
  `Coluna.eh_dicionarizada()`, `.cardinalidade()`, `.codigo_de()`, `.texto_bruto()`.
- **Kernel de calendario** (`calendario_f64`): `ano/mes/dia` vetorizados.
- `Validity.n_ausentes` mantido na construcao (`contar_ausentes()` virou O(1)),
  `tem_ausentes()` e `para_bytes()` para desempacotar o bitmap.
- Kernels densos (`soma_f64_densa`, `minimo_f64_densa`, ...) para coluna sem ausentes.
- `bench/bench_m4.mojo` + tarefa `pixi run bench-m4`.

### Alterado

- **Ordem do `Tri`**: agora `FALSO = 0 < DESCONHECIDO = 1 < VERDADEIRO = 2`, a ordem do
  reticulado de Kleene. Com ela `E` vira `min`, `OU` vira `max` e `NAO` vira `2 - x` —
  cada conectivo e uma unica instrucao SIMD. A semantica e identica; so a numeracao
  mudou. **Quebra** codigo que dependia dos valores numericos antigos.
- `Vetor.na` passou de `List[Bool]` para `List[UInt8]` (0 presente, 1 ausente), que e
  sobre o que os kernels operam. Use `Vetor.eh_na(i)` em vez de indexar direto.
- Mascaras de tres valores passaram de `List[Int]` para `List[UInt8]`.
- `Coluna.soma/media/minimo/maximo` passam por kernel SIMD.
- `avisos()` nao aponta mais extrator de data nem texto dicionarizado. Sobra o texto
  **nao** dicionarizado — cardinalidade alta ou coluna derivada.

### Achados registrados

- **Int64 nao vetoriza divisao no AVX2.** `civil_de_dias` so divide por constantes, que
  o compilador troca por multiplicacao e deslocamento — mas em Int64 isso exige
  multiplicacao 64x64->128, que o AVX2 nao tem. Ganho medido: 1,00x. O mesmo algoritmo
  em Int32 da 4,70x, e ainda dobra as pistas.
- **Desempacotar o bitmap custava mais que a reducao.** A primeira `soma()` SIMD dava
  1,12x porque desempacotava a validade antes de reduzir. Com a contagem O(1) e um
  kernel denso para o caso sem ausentes, foi para 2,33x.

### Bloqueado

- **Paralelismo por chunk.** O stdlib do Mojo 1.0 nao expoe `parallelize`. `TaskGroup` e
  `create_task` existem em `std.runtime.asyncrt`, mas um `TaskGroup()` destruido sem uso
  ja aborta o processo, e passar ponteiros para uma `async def` exige apagar a origem —
  `unsafe_ptr()` devolve `Pointer` com origem amarrada, sem `origin_cast` nem
  `MutableAnyOrigin` acessiveis. Vira trilha propria.
- **Slab de data em Int32** adiado para o M5. O motivo que fazia isso urgente era o
  calculo, e o kernel de calendario ja resolve convertendo para Int32; o que resta e
  economia de memoria, que cabe na reescrita de storage do scanner.

## [0.4.0] — M3: Execution Engine

### Adicionado

- **Executor coluna-a-coluna** (`tucano/executor.mojo`). Cada coluna referenciada e
  lida **uma vez** para um `Vetor` contiguo (`ref` sobre o lote, sem copia) e todo o
  resto opera sobre esse vetor.
- **Operadores fisicos sobre lotes**: `op_filtro` (FilterExec), `op_projecao`
  (ProjectionExec), `op_com_coluna` (ExpressionExec). O executor recebe e devolve
  `List[Coluna]` — **nao conhece `Tabela`**. E a separacao logical/physical de verdade,
  e a forma que o M6 precisa para join e groupby.
- **`Vetor`** (`tucano/vetor.mojo`): slab contiguo + mascara de ausentes. O laco interno
  ja tem a forma que o M4 vetoriza — tipo da operacao decidido fora do laco.
- **Plano logico e fisico** (`tucano/plano.mojo`): `Etapa` / `TipoEtapa`,
  `descrever_logico`, `descrever_fisico` (indentado, de baixo para cima).
- **`Tabela.onde()` / `.com_coluna()` / `.consultar()`** devolvem `Consulta`. Ergonomia
  eager, execucao lazy.
- **Materializacao automatica**: `mostrar`, `primeiras`, `linhas`, `colunas`, `shape`,
  `schema`, `nomes`, `pegar`, `soma`, `media` executam o plano sozinhos.
- **`com_coluna`** — o `df['x'] = ...` do pandas, com inferencia de tipo derivado sem
  coercao silenciosa. Substitui a coluna se o nome ja existir.
- **Propagacao de esquema** (`esquema_apos`): o planejador raciocina sobre nome+tipo, nao
  sobre dados. Da `Consulta.esquema_previsto()` — tipos do resultado **sem executar** — e
  e a base do otimizador do M8.
- **`avisos()`**: lista as operacoes sem kernel vetorizado (comparacao de texto, extrator
  de data). O pandas nunca avisa que voce caiu do caminho rapido.
- Comparacao lexicografica entre textos (`.gt`, `.lt`, ...), alem de igualdade.
- `bench/bench_m3.mojo` + tarefa `pixi run bench-m3`: mede ns/linha em 25k..200k.

### Corrigido

- **Custo quadratico do M2.** A avaliacao era linha a linha e cada referencia a coluna
  chamava `Tabela.pegar()`, que fazia busca linear e devolvia copia profunda do slab. Em
  200k linhas, um filtro fazia centenas de milhares de copias de colunas de 200k
  elementos. Agora e linear: `bench_m3` mede ns/linha praticamente constante em 8x de
  escala.
- Comparacao entre texto e numero levanta erro em vez de comparar como numero.

### Notas

- `Tabela` e `Consulta` vivem no mesmo modulo por serem mutuamente recursivas — o Mojo
  aceita recursao mutua dentro de um modulo, mas nao ciclo entre modulos.
- `tucano.consulta` virou reexport; `Consulta` mora em `tucano.tabela`.
- `tucano.executor`, `tucano.vetor` e `tucano.plano` sao **internos**: mudam no M4/M6.
- Armadilha de ambiente: um `tucano.mojoc` precompilado obsoleto no diretorio do arquivo
  compilado e preferido ao fonte, e metodos novos somem com `value has no attribute` sem
  apontar a causa.

## [0.3.0] — M2.5: biblioteca instalavel + correcoes de fundacao

### Adicionado

- **Tipo `data`** (`DType.DATA`): dias desde 1970-01-01 sobre o slab de inteiros,
  com o tipo logico decidindo a semantica. `soma()` de datas continua sendo erro.
- `Coluna.de_datas` (dias) e `Coluna.de_datas_texto` (AAAA-MM-DD).
- Modulo `tucano.datas`: `dias_desde_epoch`, `civil_de_dias`, `eh_data_iso`,
  `parse_data_iso`, `data_para_texto`, `dias_no_mes`, `eh_bissexto`.
- Literal e extratores de data nas expressoes: `lit_data("2024-01-15")`,
  `ano(...)`, `mes(...)`, `dia(...)`.
- Inferencia de data no `ler_csv`, com round-trip ISO no `para_csv`.
- Coluna logica utilizavel direto como predicado: `onde(coluna("ativo"))`.
- `Tabela.dtype_de` e `Tabela.eh_ausente` — consulta de metadados sem copiar a coluna.
- Modulo `tucano.erros`: sugestao de nome por distancia de edicao.
- `LICENSE` (Apache-2.0), `README.md`, `CHANGELOG.md`, `recipe.yaml`.
- Tarefas `pixi`: `build`, `exemplo`.

### Corrigido

- **NA em logica de tres valores** (Decisao 2 do CONTRATO). `nao(coluna > lit)`
  devolvia `True` para linhas ausentes e as mantinha no resultado, ao contrario
  do filtro sem negacao, que as descartava. Agora comparacao com ausente produz
  Desconhecido, e `onde()` mantem apenas Verdadeiro — com ou sem negacao.
- Erro de coluna inexistente passou de `KeyError` seco a sugestao
  (`Voce quis dizer 'idade'?`) ou lista das colunas disponiveis.

### Removido

- **`Tabela.indice`** (Decisao 1). Era o Index do pandas nascendo: `linhas()`
  vinha de um campo paralelo que podia divergir das colunas. A contagem agora
  vem das proprias colunas.

### Notas

- `mojo package` foi substituido por `mojo precompile`; `.mojopkg` por `.mojoc`.
  O `.mojoc` e ligado a versao do compilador e **nao** e formato de distribuicao:
  a distribuicao de bibliotecas Mojo e por fonte (conda/pixi ou repositorio).

## [0.2.0] — M2: Expression Engine

- `Expr` em arena tipada por `Kind`, `coluna`/`lit`/`lit_int`/`lit_texto`/`lit_bool`.
- API fluente `.gt .ge .lt .le .eq .ne .e .ou .nao` e aritmetica.
- `Consulta` lazy com `onde`, `selecionar`, `descrever`, `coletar`.

## [0.1.0] — M0 + M1: fundacao e Memory Engine

- `DType`, `Campo`, `Schema`, `Shape`.
- `Validity` bitmap, `StringStore`, slabs numericos contiguos.
- `Tabela` / `Coluna` sobre storage columnar.
- `ler_csv` / `para_csv` como ponte.
