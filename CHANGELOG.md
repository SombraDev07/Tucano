# Changelog

Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/).
Versionamento semantico a partir da 1.0; ate la, `0.MARCO.PATCH`.

## [0.24.0] — Juncao e ordenacao: o valor vira codigo

As duas tinham a mesma doenca, e e a mesma de todo este ciclo: materializar por
linha o que se resolve uma vez por valor distinto.

| 1M linhas, chave de 50 valores | antes | depois | |
|---|---|---|---|
| juncao a esquerda | 470 ns/linha | **74 ns/linha** | 6,4x |
| ordenacao estavel | 335 ns/linha | **100 ns/linha** | 3,4x |
| ordenacao por texto | 1320 ms | **98 ms** | 13,5x |

### Alterado — ordenacao

- **Chave extraida uma vez, antes do laco.** O comparador roda O(n log n) vezes;
  ler a coluna por dentro a cada chamada custava dois `eh_ausente` que lancam,
  um desvio por tipo e — em texto — duas `String` alocadas. 342 -> 211 ms.
- **Texto vira posto.** Os distintos sao ordenados uma vez (cinquenta, nao um
  milhao) e cada linha guarda a posicao do seu valor. 1320 -> 210 ms.
- **A chave viaja ao lado do indice.** `chave[indice[i]]` e acesso aleatorio a
  dezenas de MiB, vinte milhoes de vezes. 211 -> 70 ms.
- Ausente sai da comparacao: vai sempre para o fim, entao e separado antes.

### Alterado — juncao

- **`Dict` consultado uma vez por valor distinto**, nao por linha sondada. Os
  baldes viram duas listas planas.
- **`coletar_linhas_opcional` ganhou o atalho de dicionario** que a versao
  nao-opcional ja tinha. Sem ele, a juncao a esquerda alocava uma `String` por
  linha de saida so para redicionarizar tudo de novo no fim. **Este era o custo
  principal** — a mudanca anterior sozinha nao melhorou nada (470 -> 493 ms).
- **Chave de texto dicionarizada nao materializa `String` por linha**: a
  traducao para o espaco de codigos comum acontece por valor distinto.

### Corrigido

- **Ordenacao descendente deixava de ser estavel.** A primeira versao do caminho
  de uma chave ordenava ao contrario invertendo o vetor no fim, o que poe os
  empates na ordem inversa da original. Descendente vira a comparacao, nao o
  resultado. Nenhum teste existente pegava; o que faltava existe agora.

### Adicionado

- `test_juncao_bate_com_forca_bruta` e a variante de chave inteira: laco duplo
  como referencia, com chave repetida nos dois lados, chave so de um lado e
  ausente que nunca casa nem com outro ausente.
- `test_ordenar_uma_chave_bate_com_o_caminho_geral`: `[c]` usa o caminho novo,
  `[c, c]` usa o geral, e a resposta tem de ser a mesma.
- `test_ordenar_estavel_e_ausente_no_fim` e `test_ordenar_texto_por_posto`.

## [0.23.0] — Filtro sem materializar; paralelismo de operador medido e recusado

Pedido: paralelizar os operadores. O que se mediu primeiro mudou o que valia
fazer.

| 5M linhas, uma thread | antes | depois |
|---|---|---|
| avaliar `valor > 1000.0` | 32 ms | **3 ms** |
| pipeline completo | 110 ms | **88 ms** |

Contra uma thread: 2,7x o pandas, 1,7x o Polars, e — pela primeira vez — a
frente do DuckDB (88 contra 94 ms).

### Alterado

- **`coluna OP literal` em coluna REAL nao materializa nada.** O avaliador copiava
  a coluna inteira para um `Vetor` (16 ms) e fazia 5 milhoes de copias do literal
  (10 ms) para uma comparacao que custa 5. Agora o slab e lido no lugar e o
  escalar entra por difusao no registrador SIMD. Ja existia o atalho para texto
  dicionarizado desde o M4; faltava o numerico.
- Coluna sem nenhum ausente usa variante densa: sem ausentes o resultado nunca e
  DESCONHECIDO, entao some a leitura da mascara de validade.

Coluna INTEIRO continua no caminho geral de proposito: ali a conversao para f64
e do caminho geral, e reproduzi-la no atalho seria uma segunda regra de coercao.

### Adicionado

- **`test_filtro_escalar_bate_com_oraculo`** confere o atalho contra um oraculo
  escrito a parte — nao contra `avaliar_tri`, que passou a usar o proprio atalho
  e responderia a si mesmo. Seis operadores, duas ordens de operandos, com e sem
  ausentes, mais o literal inteiro que cai no caminho geral.

### Medido e recusado

Paralelizar a compactacao do filtro foi **construido e medido antes** de entrar
na biblioteca: tres colunas em tres threads, resultado conferido valor a valor.

| | |
|---|---|
| compactar 3 colunas, sequencial | **13 ms** |
| compactar 3 colunas, em 3 threads | 20-22 ms |

Zero divergencias e mais lento. Compactacao le e escreve dezenas de MiB por
coluna: e limitada por banda de memoria, e nesta maquina oito threads entregam
so ~1,75x mais banda que uma. Nao entrou. O resultado negativo esta no ROADMAP
como resultado.

## [0.22.0] — Leitura em varias threads

O roadmap registrava paralelismo como **bloqueado pela linguagem** desde o M4. A
conclusao estava errada, e o erro de raciocinio ficou preservado la junto com o
conserto.

| 5M linhas x 5 colunas, 44 MiB | uma thread | com threads | |
|---|---|---|---|
| ler tudo | 105 ms | **69 ms** | 1,5x |
| ler 2 de 5 colunas | 48 ms | 42 ms | 1,1x |
| pipeline completo | 117 ms | 110 ms | 1,06x |

Contra o pandas em uma thread, a leitura completa passa de 98 ms para 70.

### Adicionado

- **Leitura de Parquet com uma thread por coluna**, acima de 10 mil linhas. O
  limiar e medido: abaixo de 5 mil a thread e perda, a virada e entre 5 e 10 mil.
  A primeira versao chutou 50 mil e errou por cinco vezes.
- **`TUCANO_THREADS`** fixa o teto de threads; `=1` desliga. Ausente ou invalido
  usa os nucleos do sistema. E a saida para quem embute o Tucano onde ja existe
  um conjunto de threads.
- **`tucano/paralelo.mojo`** — so a politica: quantas threads, e quando vale.

### Corrigido

- **`esquema_previsto()` em plano que le de arquivo** ja tinha sido corrigido no
  [0.21.0]; aqui ele passou a ser exercitado tambem pelo caminho paralelo.

### O que nao mudou

Filtro, groupby, juncao e ordenacao continuam em uma thread. E por isso que o
pipeline completo ganha 6% e a leitura pura ganha 50%. Paralelizar os operadores
e a proxima peca, e e maior: exige tarefas escrevendo em fatias do mesmo
destino, que e justamente o que este desenho evitou.

### Nota de metodo

O que o Mojo 1.0 permite, verificado antes de escrever biblioteca:
`pthread_create` aceita uma `def` comum como rotina de entrada, sem `@export`;
o parametro precisa de origem fixada (`origin=AnyOrigin[mut=True]`), porque solta
a funcao vira parametrica e nao tem endereco; o alocador aguenta oito threads
alocando sem parar; carga aritmetica em oito threads mede 7,75x, entao nao ha
lock global.

## [0.21.1] — SELECT ALL

Fecha o outro lado do `DISTINCT`. `ALL` era engolido como nome de coluna e o erro
apontava tres tokens adiante: "esperava 'FROM', achei 'cidade'".

### Adicionado

- **`SELECT ALL`** e **`COUNT(ALL coluna)`** — o padrao dito por extenso. Nao
  muda nada, porque repetir ja e o padrao.
- `ALL` junto com `DISTINCT` e recusado nas duas ordens, e dentro de `COUNT`
  tambem: as duas palavras pedem o contrario uma da outra.

### Nota sobre "uma forma por operacao"

A decisao travada manda recusar sinonimo, e a primeira leitura foi que `ALL` era
um. Nao e: sinonimo e um segundo verbo **nosso** para a mesma operacao. `ALL` e a
mesma unica forma escrita como o SQL padrao permite escrever — o dialeto ja fazia
isso com o `OUTER` de `LEFT OUTER JOIN`. A regra vale para a API do Tucano, nao
para o vocabulario de um formato que existe para receber consulta escrita fora.

`ALL` so e palavra reservada quando vem um alvo depois dele. O dialeto nao tem
identificador entre aspas, entao `SELECT all FROM v` e a unica forma de pedir uma
coluna com esse nome, e aceitar `ALL` sem olhar adiante a tornaria inalcancavel.

## [0.21.0] — SELECT DISTINCT

O operador ja existia (`unicos` e `agrupar` + `contar` + so a chave); o dialeto
e que nao chegava la. `SELECT DISTINCT` **e** um GROUP BY sem agregacao, entao
nao entrou operador novo, nem caso novo no otimizador ou no executor.

### Adicionado

- **`SELECT DISTINCT`** sobre lista de colunas e sobre `*`. Destila a **linha
  inteira da projecao**: `SELECT DISTINCT cidade, uf` devolve as combinacoes
  distintas, nao os valores de cada coluna lado a lado.
- Duas linhas ausentes viram uma so. E onde `DISTINCT` diverge do `=` do proprio
  Tucano — `NA = NA` e DESCONHECIDO na logica de tres valores, mas o distinto
  trata ausencia como valor visto. E o que o SQL manda; fica no contrato.
- Com `DISTINCT`, `ORDER BY` por coluna fora do `SELECT` e recusado com a
  correcao: ordenar antes de destilar ordena linhas que vao sumir, e depois a
  coluna ja nao existe.

### Corrigido

- **`SELECT cidade AS c` nunca funcionou.** O apelido de coluna simples era lido
  pelo analisador e nunca aplicado: a projecao procurava uma coluna com o nome
  novo, que so existia na descricao da consulta, e falhava dizendo que a coluna
  nao existia — mensagem correta sobre a causa errada. A coluna apelidada passa
  a ser criada como derivada da original. Apelido que colide com coluna
  existente e recusado, em vez de sobrescreve-la em silencio.
- **`esquema_previsto()` devolvia esquema vazio em plano que le de arquivo.**
  Partia do lote em memoria, que so e preenchido no `coletar()`. Agora a base
  vem do rodape do Parquet, sem tocar em dado. E disso que o `DISTINCT *`
  precisa para saber quais colunas agrupar.

## [0.20.1] — Decodificador Snappy sem copia byte a byte

O [0.19.0] ligou Snappy por padrao na escrita e ninguem remediu a leitura depois.
Sem mudanca de API.

| mesmo dado, 5M x 5 colunas | arquivo | ler tudo |
|---|---|---|
| `compressao="nenhuma"` | 124 MiB | 62 ms |
| `compressao="snappy"` (padrao), antes | 43 MiB | 264 ms |
| `compressao="snappy"` (padrao), agora | 43 MiB | **102 ms** |

Pipeline completo (filtro + groupby + 3 agregacoes): 220 -> **117 ms**.

### Alterado

- **`descomprimir_snappy` aloca a saida uma vez e escreve por ponteiro.** O
  tamanho descomprimido vem no preambulo do formato, entao nao ha motivo para
  `append` por byte. Literal e copia em bloco.
- **Copia para tras anda de 16 em 16 quando a distancia permite.** Com faixas
  sobrepostas a leitura precisa enxergar o que acabou de ser escrita — e disso
  que sai a repeticao — mas a partir de 16 bytes de distancia um bloco de 16
  nunca le byte que ele mesmo vai escrever.
- **O laco de tags le por ponteiro.** Roda uma vez por elemento comprimido; ali
  o teste de limite do `List` pesava mais que o trabalho. Os limites da pagina
  continuam conferidos, uma vez por elemento em vez de uma vez por byte.

### Adicionado

- **`test_pq_snappy_copia_larga`** monta fluxos Snappy a mao: o compressor nao
  deixa escolher a distancia da copia, e a distancia e o que separa os dois
  caminhos do decodificador. Cobre 15 contra 16 e comprimentos que nao fecham
  em 16.

### Nota

Os numeros de leitura do [0.14.0] (62 ms, "1,7x mais rapido que pandas") foram
medidos no arquivo sem compressao, que era o padrao da escrita naquele momento.
Com o padrao atual a leitura pura fica **1,1x atras** do pandas; o pipeline
segue 1,9x a frente. README e ROADMAP refeitos.

## [0.20.0] — Ler .xlsx

`ler_xlsx(caminho)` devolve a primeira planilha como `Tabela`. `planilha="Nome"`
escolhe a aba. Primeira linha e cabecalho, como no CSV. Data no formato Excel
(serial) vira `data` quando o estilo da celula e data. `.xls` antigo e recusado.

Nao ha escritor. Formula nao e recalculada: entra o valor em cache no XML.

### Adicionado

- **`ler_xlsx(caminho, planilha="", tem_cabecalho=True)`**
- Inflate DEFLATE cru e leitor ZIP, so o que o Office Open XML precisa.

## [0.19.0] — SQL HAVING e COUNT(DISTINCT)

O dialeto chega no que o executor ja fazia: `HAVING` e o `onde` depois da
agregacao, `COUNT(DISTINCT coluna)` e o `distintos` da API fluente. Agregacao
so no HAVING e calculada, filtra, e some da projecao. `COUNT(DISTINCT *)` e
recusado.

### Adicionado

- **`HAVING`** depois de `GROUP BY` (ou sobre agregacao total). Apelido do
  SELECT vale; funcao que nao esta no SELECT vira extra e e descartada.
- **`COUNT(DISTINCT coluna)`** no SELECT e no HAVING.

## [0.18.0] — Escritor emite Snappy

O leitor ja descomprimia Snappy; o escritor so emitia pagina crua. Agora o
padrao e comprimir cada pagina (dicionario e dados). `compressao="nenhuma"`
desliga. Encoder e decoder de Snappy cru moram em `tucano/codecs.mojo`.

### Adicionado

- **`comprimir_snappy`** — formato cru (varint + literais/copias), o mesmo que
  o Parquet usa nas paginas.
- **`para_parquet(..., compressao="snappy")`** — padrao. `"nenhuma"` grava cru.

## [0.17.0] — SQL JOIN; painel HTTP estacionado

O `SELECT` passa a juntar: `JOIN` / `LEFT JOIN ... USING (colunas)` vira o mesmo
`unir` da API fluente. `ON` e `RIGHT JOIN` sao recusados com explicacao.

O servidor HTTP do painel sai do caminho critico. Sem `std.net` no Mojo 1.0,
continuar nisso e escrever servidor em vez de engine. `json_painel()` /
`json_dados()` continuam gerando o payload sem subir socket.

### Adicionado

- **`JOIN` / `INNER JOIN` / `LEFT JOIN` com `USING`** no dialeto SQL. Uma forma,
  as mesmas chaves do `unir`.

### Alterado

- **Painel HTTP estacionado.** Fora do 1.0. Reavalia quando o stdlib expuser sockets.

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
