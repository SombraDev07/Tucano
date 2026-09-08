# Changelog

Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/).
Versionamento semantico a partir da 1.0; ate la, `0.MARCO.PATCH`.

## [0.16.0] — distinct_count e reordenacao de juncao

O escritor passa a gravar `distinct_count` (campo 4 de `Statistics`) em coluna
de texto dicionarizada: o NDV **do row group**, nao o tamanho do dicionario
que a fatia herdou. O hash join interno hasheia o lado mais barato — cardinalidade
da chave dicionarizada, ou numero de linhas. Juncao a esquerda continua sondando
a esquerda, senao a linha sem par desaparece.

### Adicionado

- **`distinct_count` no rodape Parquet** de coluna dicionarizada. Leitor aceita
  o campo em arquivo nosso ou de terceiro. `ColunaMeta.n_distintos` / `.tem_distintos()`.
- **Hash join interno escolhe o lado da hash.** `pequena.unir(grande)` deixa de
  hashear o lado grande so porque veio a direita.

## [0.15.0] — Predicate pushdown por min/max

O escritor passa a gravar min/max de cada row group numerico no rodape. O
leitor, no `coletar()` e no fluxo, nao le o grupo cujo intervalo nao pode
satisfazer um `coluna op literal` (e `E`/`OU` disso). Sem estatistica, ou com
predicado que nao e essa forma, o grupo e lido — a regra e conservadora.

O filtro do plano continua rodando. Pular grupo e I/O, nao substitui a selecao.

### Adicionado

- **Estatisticas de row group** (`Statistics` no `ColumnMetaData`): min/max em
  PLAIN para inteiro, real, data e datahora. Ausente nao entra na faixa.
- **Predicate pushdown:** row group impossivel nao sai do disco, em `coletar()`
  e em `coletar_em_fluxo()`.

## [0.14.0] — Mais rapido que pandas, medido

O escritor passou a emitir texto repetido em `RLE_DICTIONARY`, o leitor
parou de zerar o que ia sobrescrever, e o filtro/groupby deixou de copiar
linha a linha quando nao ha ausente. Mesmo arquivo, mesma pergunta, uma thread.

| 5M linhas, uma thread | Tucano | pandas 3.0.5 | |
|---|---|---|---|
| ler 5 colunas (124 MiB) | **62 ms** | 108 ms | **1,7× mais rapido** |
| ler 2 de 5 colunas | **24 ms** | 31 ms | **1,3×** |
| Parquet → filtro → groupby → 3 agregacoes | **97 ms** | 228 ms | **2,4×** |

No pipeline, uma thread do Tucano tambem fica a frente do Polars em uma thread
(109 ms).

### Adicionado

- **Escritor emite `RLE_DICTIONARY` em coluna de texto ja dicionarizada.** Pagina
  de dicionario + indices em RLE/bit-packing. Coluna de alta cardinalidade
  continua PLAIN. Interoperabilidade verificada com pyarrow: o arquivo encolhe
  (245 MiB → 124 MiB no banco de 5M) e qualquer leitor ganha, nao so o nosso.

### Alterado

- **`LeitorArquivo` nao zera o buffer antes do `pread`.** O mesmo defeito do
  `resize(n, 0)`: 40 MiB de zeros por coluna numerica, so para serem
  sobrescritos.
- **Mascara de ausentes so materializa se aparecer um nulo.** O caso comum
  (ninguem ausente) vai direto a `Validity.todos_presentes`.
- **Indices de dicionario decodificam em `Int32`**, no slab, com remap in-place.
  O `List[Int]` de 8 bytes por linha saiu do caminho quente.
- **Dicionario numerico faz gather**, nao `_emitir` por linha. Arquivo bem
  encodado (o do mundo) deixava de ser o caminho rapido.
- **Filtro compacta o slab por ponteiro** quando nao ha ausente, em vez de
  `append` + `eh_ausente` por linha.
- **Groupby dicionarizado e agregacao real sem ausentes** escrevem no destino
  reservado, sem `extrair_coluna` intermediario.

## [0.13.2] — Leitura de Parquet 4,8x mais rapida

Sem mudanca de API. So desperdicio removido do caminho de leitura, depois que a
suite comparativa do M10 mostrou 1112 ms onde a referencia fazia 84.

| 5M linhas x 5 colunas, 245 MiB | antes | depois | |
|---|---|---|---|
| ler tudo | 1112 ms | **230 ms** | 4,8x |
| ler 2 de 5 colunas | 568 ms | **103 ms** | 5,5x |

### Corrigido

- **`tem_dicionario()` usava `offset > 0` como sentinela de ausencia.** Com os
  deslocamentos relativos ao pedaco de coluna, uma pagina de dicionario no inicio
  do pedaco cai no offset zero e a coluna era lida como se nao tivesse dicionario.
  O defeito estava latente na `VarreduraParquet` desde o M9 — nenhum teste lia um
  arquivo dicionarizado por faixa. Sentinela agora e `-1`, e o caso esta coberto
  por `test_m8_varredura_le_dicionarizado`.

### Alterado

- **`ler_parquet` le so as faixas das colunas pedidas.** Era
  `Path.read_bytes()` do arquivo inteiro; o column pruning existia no
  decodificador mas nao no disco. Agora usa `LeitorArquivo` por pedaco de coluna,
  a mesma tecnica que a `VarreduraParquet` ja usava.
- **PLAIN de INT64/DOUBLE decodificado por copia em bloco.** A representacao no
  arquivo e identica a da memoria; montar cada valor com oito deslocamentos era
  trabalho puro. `memcpy` trata o desalinhamento que impedia a carga larga.
- **`DicionarioBytes` passou a enderecamento aberto** num vetor plano, no lugar
  de um `Dict` de listas por balde. E a pergunta feita uma vez por linha em
  coluna de texto PLAIN. Hash e comparacao consomem 8 bytes por rodada.
- **`slab_int64`/`slab_float64` assumem a lista em vez de copia-la.** Um `List`
  do Mojo ja e um slab contiguo; a copia so tocava 40 MiB de paginas novas por
  coluna para chegar aos mesmos bytes.
- **`Validity.de_lista` monta o byte inteiro antes de escrever**, no lugar de
  ler e reescrever o mesmo byte uma vez por bit: 14 ms -> 2 ms em 5M linhas.
- **Niveis de definicao nao sao mais expandidos** quando a pagina e um unico
  trecho RLE dizendo "todos presentes" — o caso normal. `rle_valor_unico` le o
  cabecalho e responde sem materializar um `Int` por linha.
- **`desempacotar_bits` confere os limites uma vez**, na entrada, em vez de a
  cada byte: um trecho empacotado tem tamanho fechado.

### Nota de desempenho

`resize` para o tamanho exato a cada row group realoca a cada grupo — a primeira
versao com `memcpy` ficou **duas vezes mais lenta** que a que substituia. O
rodape ja diz quantas linhas o arquivo tem: reservar uma vez elimina o problema.
E `resize(n, 0)` antes de um `memcpy` escreve os mesmos bytes duas vezes;
`resize(unsafe_uninit_length=n)` e o par correto.

## [0.7.0] — Parquet: leitura, escrita e column pruning

Fecha o unico item que faltava do M5. Interoperabilidade verificada lendo com outra
implementacao os arquivos escritos pelo Tucano.

| | ns/linha | |
|---|---|---|
| `ler_parquet` (6 colunas) | 215 | 3,6x mais rapido que CSV |
| `ler_parquet` com pruning (2 de 6) | 76 | 2,8x mais rapido que ler tudo |
| `para_parquet` | 232 | 2,4x mais rapido que escrever CSV |
| so o rodape (esquema + contagem) | — | 2,2 ms, sem tocar em dado |

### Adicionado

- **`tucano/thrift.mojo`** — protocolo Thrift compact, leitura e escrita. Varint,
  zigzag, delta de id de campo, booleano codificado no proprio tipo, e `pular_valor`
  para atravessar os dezenas de campos opcionais que nao interessam.
- **`tucano/codecs.mojo`** — Snappy cru (o formato das paginas, sem enquadramento de
  stream) e RLE/bit-packing hibrido, que carrega niveis de definicao e indices de
  dicionario.
- **`tucano/parquet.mojo`** — metadados, paginas e montagem de coluna.
  - `ler_parquet(caminho)` e `ler_parquet(caminho, [nomes])` com **column pruning**:
    as colunas nao pedidas nunca saem do disco. Nasceu no design, nao como
    otimizacao posterior — os metadados ficam no rodape justamente para isso.
  - `para_parquet(tabela, caminho)`.
  - `esquema_parquet` e `metadados_parquet`: esquema, contagem, codificacoes e
    compressao **sem tocar em um byte de dado**.
  - Cobre esquema plano, PLAIN e RLE_DICTIONARY, niveis de definicao RLE/bit-packed,
    paginas V1 e V2, sem compressao e Snappy, multiplos row groups, e tipos logicos
    tanto por `ConvertedType` quanto por `LogicalType`.
- **`tools/verificar_interop_parquet.py`** + `pixi run -e fixtures interop`: le com
  outra implementacao os arquivos que o Tucano escreveu e compara valor a valor.
- `bench/bench_parquet.mojo` + `pixi run bench-parquet`.

### Notas

- **Round-trip proprio nao prova nada.** Um leitor e um escritor com o mesmo
  mal-entendido concordam entre si. Foi a verificacao cruzada que pegou o unico erro
  de semantica que o round-trip proprio nao pegaria: sem emitir `LogicalType`, um
  carimbo de tempo ingenuo volta marcado como UTC, porque o `ConvertedType` legado
  nao distingue os dois casos.
- Cada tipo de pagina tem seu proprio mapa de campos, e eles nao coincidem: o campo 3
  e `definition_level_encoding` numa pagina de dados e `is_sorted` numa pagina de
  dicionario. `is_sorted` e booleano, e no Thrift compact booleano nao gasta byte de
  valor — le-lo como varint desalinha o cabecalho inteiro e faz o offset dos dados
  apontar para lixo.
- A escrita usa um subconjunto deliberado (PLAIN, sem compressao, um row group,
  colunas opcionais) que qualquer leitor aceita.

## [0.6.0] — M5: scanner CSV tipado, datahora, leitura em fatias

Leitura de CSV passou de **7226 ns/linha para 715** (10,1x). Com schema explicito,
304 ns/linha. `pixi run bench-m5`.

### Adicionado

- **`tucano/scanner.mojo`** — varredura de bytes que marca as fronteiras dos campos
  (dois inteiros por celula, nenhuma alocacao) e parsers que leem direto do buffer.
  Texto so vira `String` no fim, e so em coluna de texto.
- **Aspas RFC 4180** na leitura e na escrita: delimitador e quebra de linha dentro do
  campo, `""` como aspa escapada. O leitor anterior nao suportava — era limitacao
  documentada que virava corrupcao silenciosa em CSV real.
- **`ler_csv_tipado(caminho, schema, ...)`** — schema explicito, sem inferencia. Alem de
  2,35x mais rapido, e a unica forma de garantir que o tipo de hoje continua o de amanha.
- **`LeitorCSV`** — leitura em fatias: `.proximo(n)`, `.fim()`, `.restantes()`,
  `.total_linhas()`, `.schema()`. Limita a tabela materializada, nao a memoria total.
- **`ler_csv(..., pular=n)`** — descarta linhas fisicas antes de tudo.
- **`DType.DATAHORA`** — microssegundos desde a epoca em Int64, mesma unidade que o Arrow
  usa em timestamp. `Coluna.de_datahoras` / `de_datahoras_texto` / `micros_em`.
- Modulo `tucano.datas` ganhou `DataHoraCivil`, `micros_desde_epoch`, `civil_de_micros`,
  `eh_datahora_iso`, `parse_datahora_iso`, `datahora_para_texto`.
- **`lit_datahora()`, `hora()`, `minuto()`, `segundo()`** nas expressoes.
- **`Vetor.unidade`** (numero / dias / microssegundos): o vetor carrega o que seus numeros
  significam. Com isso `ano()`/`mes()`/`dia()` servem para `data` e `datahora` sem que o
  executor precise consultar o esquema — e `coluna("data").mais(lit_int(7))` continua
  sendo uma data.
- `bench/bench_m5.mojo` + tarefa `pixi run bench-m5`.

### Corrigido

- **`para_csv` nao citava nada.** Campo com delimitador, aspas ou quebra de linha saia
  corrompido e nao voltava na releitura. Agora cita quando precisa, duplicando aspas.
- **`para_csv` copiava a coluna inteira por celula** (`tabela.pegar()` dentro do laco de
  linhas). As colunas sao buscadas uma vez.

### Notas

- Parser de ponto flutuante: decimal simples e convertido direto dos bytes como
  `mantissa / 10^k`, corretamente arredondado enquanto mantissa <= 2^53 e casas <= 22;
  fora disso cai no `atof`. O caminho rapido cobre praticamente todo CSV real sem abrir
  mao da exatidao.
- Inferencia de tipo: `datahora` -> `data` -> `logico` -> `inteiro` -> `real` -> `texto`.
  Formatos ISO nunca colidem com numero ou booleano.
- **Fuso horario nao e suportado**: `Z` final e aceito e ignorado, deslocamentos
  (`+03:00`) sao recusados. Meia implementacao de fuso e pior que nenhuma.

### Bloqueado

- **Parquet.** Nao ha nesta maquina nenhuma ferramenta capaz de gerar um arquivo
  Parquet real para testar contra. Um
  leitor sao 1500+ linhas de parsing binario (Thrift compact, RLE/bit-packed, paginas de
  dicionario, Snappy); escrever isso sem fixture produziria codigo que parece pronto e
  nao e. `pyarrow` esta disponivel no conda-forge: adota-lo como dependencia **de
  fixture** destrava, e nao fere o Zero Python, que e sobre runtime.
- **Slab de data em Int32** adiado para o M6: um sexto `List` paralelo em `Coluna` iria na
  direcao contraria da reescrita de storage que join e groupby vao exigir.

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
- **`com_coluna`** — atribuicao de coluna calculada, com inferencia de tipo derivado sem
  coercao silenciosa. Substitui a coluna se o nome ja existir.
- **Propagacao de esquema** (`esquema_apos`): o planejador raciocina sobre nome+tipo, nao
  sobre dados. Da `Consulta.esquema_previsto()` — tipos do resultado **sem executar** — e
  e a base do otimizador do M8.
- **`avisos()`**: lista as operacoes sem kernel vetorizado (comparacao de texto, extrator
  de data). O normal e a ferramenta nao avisar que voce saiu do caminho rapido.
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

- **`Tabela.indice`** (Decisao 1). Era um indice implicito nascendo: `linhas()`
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
