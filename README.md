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

- **Armazenamento columnar tipado** — slabs contíguos por coluna, sem
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
- **Leitura de CSV rápida e correta** — `bytes → scanner → parser tipado → buffers`, sem
  alocar por célula. 715 ns/linha, com aspas RFC 4180 na leitura e na escrita.
- **Parquet nativo, leitura e escrita** — sem ponte, sem dependência externa. Column pruning,
  predicate pushdown e Snappy de verdade: coluna não pedida e row group impossível não saem
  do disco; o que sai vai comprimido. Lê `PLAIN`, `RLE_DICTIONARY` e `DELTA_BINARY_PACKED`,
  sem compressão, Snappy e GZIP, e o carimbo legado `INT96`; **recusa com erro explícito**
  Zstd, Brotli, LZ4, `DECIMAL` e `FIXED_LEN_BYTE_ARRAY` — ver [o contrato](tucano/CONTRATO.md).
- **Agrupamento e junção como operadores** — não funções soltas. Chave de texto repetida
  agrupa por indexação direta de array, sem hash: 14,7× mais rápido que chave composta.
  Junção interna hasheia o lado de menor custo (NDV ou número de linhas).
- **Otimizador de consultas** — o filtro sobe no plano, constantes dobram, a coluna que
  ninguém usa não sai do disco, e o row group cujo min/max não casa com o predicado
  também não. `explicar()` mostra o plano antes e depois.
- **Execução em memória limitada** — agregar não exige ter tudo em RAM. Sobre Parquet, o
  arquivo é lido row group por row group e nunca entra inteiro em memória.
- **SQL sobre o mesmo motor** — `SELECT` vira as mesmas etapas da API fluente e passa pelo
  mesmo otimizador. `JOIN ... USING` é o `unir`; `HAVING` é o `onde` depois de agregar;
  `SELECT DISTINCT` é o `agrupar` sem agregação. Não há um segundo interpretador.
- **Excel `.xlsx`** — `ler_xlsx` abre a planilha como `Tabela` e `para_xlsx` grava. Sem
  `.xls` antigo. Leitura verificada contra o openpyxl, nos dois sentidos.
- **Leitura em várias threads** — uma por coluna, acima de 10 mil linhas. `TUCANO_THREADS`
  fixa quantas, para quem embute o Tucano onde já existe um conjunto de threads.
- **Filtro sem materializar** — `coluna > literal` compara o slab contra o escalar difundido
  no registrador, sem copiar a coluna nem repetir o literal por linha.
- **Junção e ordenação por código** — texto vira posto ou código do dicionário, resolvido uma
  vez por valor distinto e não por linha. Ordenar por texto era 1320 ms no milhão; são 98.
- **Zero Python** — sem interpretador, sem pontes, sem dependência de runtime.

## Instalação

Mojo 1.0 ou superior é o único requisito. **Não há `pip` no mundo Mojo** — o gerenciador é o
`pixi` (conda), e é por ele que a distribuição acontece.

### Pelo canal conda

```bash
pixi add tucano -c https://sombradev07.github.io/Tucano
```

O `-c` some pondo o canal no `pixi.toml` do seu projeto, ou uma vez por máquina com
`pixi config append default-channels https://sombradev07.github.io/Tucano`. Sem `-c` **nenhum**
só quando o Mojo estiver no conda-forge — hoje ele não está, e o conda-forge exige que as
dependências estejam lá.

### Sem canal: duas linhas

Quem já tem Mojo instalado não precisa de mais nada:

```bash
git clone https://github.com/SombraDev07/Tucano.git
mojo precompile Tucano/tucano -o "$(dirname "$(which mojo)")/../lib/mojo/tucano.mojoc"
```

Pronto. `from tucano import ...` passa a funcionar em **qualquer diretório**, sem `-I` e sem
copiar arquivo para dentro do projeto:

```python
from tucano import ler_csv, coluna, lit

def main() raises:
    var t = ler_csv("vendas.csv")
    t.onde(coluna("valor").gt(lit(100.0))).coletar().mostrar()
```

```bash
mojo analise.mojo
```

O que a segunda linha faz: o Mojo procura pacotes na pasta onde a própria `std` mora —
`lib/mojo/`, ao lado do binário — e `mojo precompile` escreve o Tucano direto lá.

Para **desinstalar**, apague o arquivo:

```bash
rm "$(dirname "$(which mojo)")/../lib/mojo/tucano.mojoc"
```

### As outras formas

Sem instalar, apontando o `-I` para o clone — é o modo de quem vai mexer no Tucano:

```bash
mojo -I /caminho/para/Tucano meu_script.mojo
```

Ou instalando a **fonte** em vez do pacote, que é portátil entre versões do compilador:

```bash
cp -r tucano "$(dirname "$(which mojo)")/../lib/mojo/tucano"
```

A diferença entre as duas últimas e o pacote precompilado é grande — rodar um script de três
linhas que importa o Tucano, menor de cinco execuções:

| forma | primeira execução | depois |
|---|---|---|
| fonte (`-I` ou instalada) | ~12 s | 3,4 s |
| pacote `.mojoc` instalado | ~12 s | **0,99 s** |

A fonte é recompilada a cada execução; o `.mojoc` já vem compilado. Em troca, ele é **ligado
à versão exata do compilador** — trocou de Mojo, roda `pixi run build` de novo. Se os dois
estiverem instalados, a fonte ganha.

### Pelo canal conda (quando publicado)

Aí o uso vira o equivalente Mojo do `pip install pandas`, e o Tucano entra como dependência
declarada do projeto de quem usa:

```bash
pixi add tucano -c https://sombradev07.github.io/Tucano
```

**Um canal conda é só uma árvore de arquivos estática servida por HTTP** — `noarch/` com os
`.conda` e um `repodata.json` ao lado. Não há nada de especial nele, e o GitHub Pages serve
essa árvore tão bem quanto qualquer outro host. Verificado ponta a ponta: com o canal servido
por um `python -m http.server` qualquer, `pixi install` busca o `repodata.json`, baixa o
pacote e o instala em `lib/mojo/` — o script do usuário roda sem `-I`.

Para publicar (dono do projeto):

```bash
./tools/publicar_canal.sh            # empacota e deixa o commit pronto em gh-pages
git -C .publicacao push origin gh-pages
```

Uma vez só, antes da primeira publicação: **Settings → Pages → Source = "Deploy from a
branch", branch `gh-pages`, pasta `/ (root)`**. O script acumula versões — quem fixou uma
versão antiga continua resolvendo.

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

`inteiro` · `real` · `logico` · `texto` · `data` · `datahora`

```mojo
var idade = Coluna.de_inteiros("idade", [Int64(25), Int64(30)])
var valor = Coluna.de_reais("valor", [1200.0, 800.0])
var ativo = Coluna.de_logicos("ativo", [True, False])
var cidade = Coluna.de_textos("cidade", ["SP", "RJ"])
var quando = Coluna.de_datas_texto("quando", ["2024-01-15", "2024-02-20"])
var visto = Coluna.de_datahoras_texto("visto", ["2024-01-15T08:30:00"])
```

`data` são dias desde 1970-01-01; `datahora` são microssegundos desde a epoch. Ambos vivem
no slab de inteiros — fisicamente inteiros, com o tipo lógico decidindo a semântica. Somar
datas continua sendo erro.

Fuso horário não é suportado: um `Z` final é aceito e ignorado, deslocamentos são recusados.

## API

### Tabela

| Operação | Método |
|---|---|
| ler coluna | `pegar(nome)` |
| adicionar / remover | `adicionar(coluna)` · `remover(nome)` |
| projetar | `selecionar([nomes])` |
| filtrar | `onde(expr)` |
| coluna derivada | `com_coluna(nome, expr)` |
| agrupar | `agrupar([chaves]).agregar([...])` |
| juntar | `unir(outra, [chaves], "interno" \| "esquerda")` |
| ordenar | `ordenar([chaves], descendente)` |
| empilhar | `concatenar(outra)` |
| ausentes | `remover_na([nomes])` · `preencher_na(nome, valor)` |
| descrever | `resumo()` · `contar_valores(nome)` · `unicos(nome)` |
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
| datas | `ano() mes() dia()` — servem para `data` e `datahora` |
| horas | `hora() minuto() segundo()` — exigem `datahora` |
| literais | `lit lit_int lit_texto lit_bool lit_data lit_datahora` |

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

### Agrupamento e junção

```mojo
vendas
    .unir(cidades, ["cidade"], "esquerda")
    .agrupar(["estado"])
    .agregar([soma("valor"), media("valor"), contar()])
    .ordenar(["soma_valor"], True)
    .mostrar()
```

`soma` · `media` · `contar` · `contar_de` · `minimo` · `maximo` · `primeiro` · `distintos`,
com `.como("apelido")` para renomear a saída. `minimo`/`maximo` preservam o tipo: o máximo de
uma coluna `data` é uma `data`.

Na junção, **chave ausente não casa com nada**, nem com outra ausente. E nome que colide fora
das chaves é recusado com erro, não renomeado em silêncio com um sufixo.

A ordenação é **estável**, com ausente sempre por último. Direções mistas saem de dois
passos: `ordenar(["b"], True).ordenar(["a"])` — por isso não existe uma segunda forma de
ordenar.

## SQL

```mojo
consultar_sql(
    "SELECT grupo, SUM(valor) AS total FROM 'vendas.parquet'"
    " WHERE valor > 100 GROUP BY grupo HAVING SUM(valor) > 1000"
    " ORDER BY total DESC LIMIT 10"
).mostrar()
```

Não há um segundo motor. O `SELECT` vira exatamente as mesmas etapas que a API fluente
produz, e ganha de graça a poda de colunas, o empurrão de filtro e a varredura adiada:

```
LOGICO   SCAN -> FILTER (coluna(valor) > lit(100)) -> AGGREGATE [grupo] -> [soma(valor)]
              -> PROJECT [grupo, total] -> SORT [total desc] -> RESULT
COLUNAS  2 de 3 [grupo, valor]
REGRAS   poda de colunas (3 -> 2)
```

`SELECT DISTINCT` destila a linha inteira da projeção — é um `GROUP BY` sem agregação, e
por isso não trouxe operador novo nem caso novo no otimizador:

```mojo
consultar_sql("SELECT DISTINCT cidade, uf FROM 'vendas.parquet'").mostrar()
consultar_sql("SELECT DISTINCT * FROM 'vendas.parquet'").mostrar()
```

`SELECT ALL` também é aceito: é o padrão dito por extenso, e não muda nada. As duas juntas
são recusadas, porque pedem o contrário uma da outra.

`FROM` aceita `'arquivo.parquet'`, `'arquivo.csv'` ou um nome registrado num `Catalogo`.
Erros apontam a posição no texto.

## Otimizador

`coletar()` otimiza antes de executar, e `explicar()` mostra o que mudou:

```mojo
varredura_parquet("vendas.parquet")
    .onde(coluna("valor").gt(lit(1000.0)))
    .agrupar(["cidade"])
    .agregar([soma("valor")])
    .explicar()
```

```
LOGICO     SCAN -> FILTER (coluna(valor) > lit(1000.0)) -> AGGREGATE [cidade] -> RESULT
OTIMIZADO  SCAN -> FILTER (coluna(valor) > lit(1000.0)) -> AGGREGATE [cidade] -> RESULT
FONTE      parquet vendas.parquet
COLUNAS    2 de 5 [valor, cidade]
REGRAS     poda de colunas (5 -> 2)
```

`varredura_parquet` adia a leitura: o arquivo só é aberto depois que o otimizador decidiu
quais colunas o plano usa. As outras nunca saem do disco.

`coletar_sem_otimizar()` executa o plano como escrito — serve para medir o ganho e para
provar que o otimizador não mudou a resposta.

## Memória limitada

```mojo
varredura_parquet("enorme.parquet")
    .onde(coluna("valor").gt(lit(100.0)))
    .agrupar(["grupo"])
    .agregar([soma("valor"), media("valor"), contar()])
    .coletar_em_fluxo()
```

Agregar não exige ter tudo em memória: exige carregar o **estado dos grupos**, que é
proporcional ao número de grupos e não ao de linhas. Sobre um arquivo de 72 MB em 40 row
groups, o pico foi **467 KiB** — 0,6% do arquivo, por 6% a mais de tempo, com resultado
idêntico. O pico é **um row group**, então ele segue o `linhas_por_grupo` de quem escreveu o
arquivo: no padrão de hoje, 500 mil linhas.

O arquivo nunca é carregado inteiro: a leitura é por faixa, e cada pedaço de coluna sai do
disco na sua própria faixa de bytes.

`pode_fluir()` diz se o plano flui, ou por que não:

```
ordenacao precisa do conjunto inteiro — use coletar()
distintos(x) nao combina entre fatias sem guardar todos os valores vistos
```

Ordenação e junção precisam do conjunto todo, e `distintos` não combina entre fatias. O
plano é recusado com essa explicação, não executado pela metade.

## Painel (protótipo, fora do caminho)

O M7 existe: widget guarda uma **consulta**, não uma tabela, e o payload é JSON
agregado. O servidor HTTP sobre libc **não é o produto** — o Mojo 1.0 não tem
`std.net`. `json_painel()` / `json_dados()` geram o payload sem subir socket.
Reavalia quando o stdlib expuser sockets.

```mojo
var p = Painel("Vendas", vendas)
p.kpi("Faturamento", soma("valor"))
p.grafico("Por cidade", "cidade", soma("valor"), "barra")
p.tabela("Detalhe", ["data", "cidade", "valor"], 50)
p.filtro("cidade")
print(p.json_dados(""))
```

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

### Somar nada não dá zero

Um grupo sem nenhum valor válido sai **ausente**, não `0`. Zero é uma afirmação sobre a soma;
quando não há o que somar, a resposta honesta é Desconhecido. `Coluna.soma()` levanta erro no
mesmo caso, como `media`, `minimo` e `maximo` já faziam.

### Nenhuma coerção implícita

Tipos incompatíveis levantam erro. Comparar texto com número não converte em silêncio.
Coluna derivada tem tipo inferido: `inteiro + inteiro` é `inteiro`, divisão é sempre `real`,
`mes()` é `inteiro`.

### Uma forma por operação

Antes de qualquer método novo, a pergunta é se já existe um jeito de fazer aquilo. Se existe,
o novo é recusado. Bibliotecas de análise costumam crescer para centenas de métodos porque
cada conveniência parecia inofensiva sozinha.

## Leitura de arquivos

```mojo
ler_arrow("vendas.arrow")                   # Arrow IPC
para_arrow(tabela, "saida.arrow")

ler_parquet("vendas.parquet")               # arquivo inteiro
ler_parquet("vendas.parquet", ["mes", "valor"])   # só estas duas colunas saem do disco
esquema_parquet("vendas.parquet")           # esquema, sem tocar nos dados
para_parquet(tabela, "saida.parquet")

ler_csv("vendas.csv")                       # infere o tipo de cada coluna
ler_csv_tipado("vendas.csv", meu_schema)    # schema explícito, sem adivinhação
ler_csv("vendas.csv", nrows=1000, pular=2)  # recorte
para_csv(tabela, "saida.csv")               # cita o que precisar ser citado

ler_xlsx("vendas.xlsx")                     # primeira planilha
ler_xlsx("vendas.xlsx", "Cidades")         # aba pelo nome
para_xlsx(tabela, "saida.xlsx")             # uma tabela, uma aba
para_xlsx(tabela, "saida.xlsx", "Vendas")   # nomeando a aba
```

Aspas RFC 4180 valem na leitura e na escrita: delimitador e quebra de linha dentro do campo,
`""` como aspa escapada.

Para não materializar a tabela inteira de uma vez:

```mojo
var leitor = LeitorCSV("grande.csv")
while not leitor.fim():
    processar(leitor.proximo(50_000))
```

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

`pixi run bench-m5`, sobre leitura de CSV (200 mil linhas × 5 colunas):

| | ns/linha | |
|---|---|---|
| `ler_csv` com inferência | **715** | 42 MiB/s |
| `ler_csv_tipado` | **304** | 2,35× mais rápido que inferir |
| `para_csv` | 365 | |

E `pixi run bench-parquet`, sobre as mesmas 200 mil linhas em 6 colunas:

| | ns/linha | |
|---|---|---|
| `ler_parquet` | **215** | 3,6× mais rápido que CSV |
| `ler_parquet` com pruning (2 de 6) | **76** | 2,8× mais rápido que ler tudo |
| `para_parquet` | 232 | 2,4× mais rápido que escrever CSV |

E `pixi run bench-m6`, sobre 1 milhão de linhas com chave de 50 valores distintos:

| | ns/linha | |
|---|---|---|
| formar grupos por chave **dicionarizada** | **11** | indexação direta, sem hash |
| formar grupos por chave inteira | **11** | era 22: faixa estreita dispensa hash |
| `agrupar` + 3 agregações | **13** | era 43 |
| formar grupos por chave composta | **30** | era 221: base mista, sem `String` por linha |
| `unir` à esquerda | **67** | era 470: a chave vira código, não `String` |
| `ordenar` estável | **91** | era 335; por texto, era 1320 ms e são 98 |

E `pixi run bench-m8`, sobre 500 mil linhas em 5 colunas:

| | sem otimizar | otimizado | ganho |
|---|---|---|---|
| agrupar sobre Parquet (lê 2 de 5 colunas) | 288 ms | **152 ms** | **1,90×** |
| ordenar e filtrar (25k de 500k linhas) | 351 ms | **30 ms** | **11,5×** |

E `pixi run bench-m3` mostra que o executor escala linear — ns/linha praticamente constante
de 25 mil a 200 mil linhas.

## Onde o Tucano está

Os números acima são internos — medem o Tucano contra ele mesmo. A suíte comparativa mede
contra os engines de referência, no mesmo arquivo e com a mesma pergunta:

```bash
pixi run bench-leitura                  # leitura, lado do Tucano
pixi run -e comparativo leitura         # leitura, todos os engines
pixi run bench-escrita                  # escrita, lado do Tucano
pixi run -e comparativo escrita         # escrita, todos os engines
pixi run bench-comparativo              # pipeline completo
pixi run -e comparativo referencia-1t   # pipeline, uma thread
```

**Ler 5 milhões de linhas × 5 colunas de Parquet — 10 MiB — e materializar em memória:**

| | ler tudo | ler 2 de 5 colunas |
|---|---|---|
| Tucano | **39 ms** | 22 ms |
| pandas 3.0.5 | 92 ms | 42 ms |
| pyarrow | 47 ms | 33 ms |
| Polars 1.44 | 43 ms | 14 ms |
| DuckDB 1.5.5 | 4 ms | 3 ms |

O arquivo é o que o próprio Tucano escreve com o padrão de hoje, e cada coluna recebe a
codificação que a mede menor: `id` em `DELTA_BINARY_PACKED`, `valor` e `peso` em dicionário
numérico, os textos em `RLE_DICTIONARY`. São **10 MiB** onde o mesmo dado em PLAIN ocupa 43 —
e escolher a codificação deixa até a **escrita** mais rápida, porque sobra menos byte para o
Snappy comprimir.

**Pipeline completo — Parquet → filtro → groupby → 3 agregações, 5M linhas:**

| | tempo | vs Tucano |
|---|---|---|
| Tucano | **61 ms** | — |
| Tucano **em fluxo** (pico de 1 row group) | 93 ms | era 900 ms |
| pandas 3.0.5 (1 thread) | 237 ms | Tucano **3,9×** mais rápido |
| Polars (1 thread) | 150 ms | Tucano **2,5×** mais rápido |
| DuckDB (1 thread) | 71 ms | Tucano **1,2×** mais rápido |
| Polars (16 threads) | 45 ms | 1,4× |
| DuckDB (16 threads) | 14 ms | 4,4× |

**Escrever as mesmas 5M × 5 linhas em Parquet** — tempo e tamanho andam juntos aqui, porque
escrever PLAIN é rápido e produz um arquivo que todo leitor paga para sempre:

| | ms | MiB |
|---|---|---|
| Tucano | **128** | **10,1** |
| pyarrow | 440 | 31,9 |
| Polars | 95 | 43,6 |

**3,4× mais rápido que o pyarrow, com um arquivo 3,2× menor.** O Polars escreve em 3/4 do
nosso tempo e produz um arquivo **4,3× maior**. A escrita se paga uma vez; a leitura, sempre.
Cada coluna de cada row group é codificada numa thread — ver `bench-escrita`.

Uma thread contra uma thread: o Tucano passa pandas, Polars e o DuckDB neste workload. O que resta para o DuckDB em 16 núcleos é paralelismo, e nos operadores ele foi
**medido e recusado**: compactar três colunas em três threads mediu 20 ms contra 13 da versão
de uma thread. Depois de tirar o desperdício, os operadores ficam limitados por banda de
memória, e oito threads entregam só ~1,75× mais banda que uma. O roadmap registra o número.

Publicar o número desfavorável continua valendo. Foi assim que se descobriu que
ligar Snappy por padrão tinha deixado a leitura 4,3× mais lenta sem que nenhum
teste reclamasse — testes verificam correção, e o arquivo estava correto.

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
| I/O tipado: scanner CSV, datahora, leitura em fatias | ✅ |
| Parquet: leitura, escrita, column pruning, predicate pushdown, Snappy | ✅ |
| Agregação, junção, ordenação e verbos de análise | ✅ |
| Otimizador: dobra, fusão, empurrão, poda de colunas | ✅ |
| Execução em fluxo com memória limitada | ✅ |
| SQL sobre o mesmo planner | ✅ |
| Arrow IPC: leitura e escrita, interop verificada | ✅ |
| Excel `.xlsx`: leitura e escrita, interop verificada | ✅ |
| Painel HTTP | ⏸ estacionado — sem `std.net` não é produto |

251 testes. Roadmap completo em [ROADMAP.md](ROADMAP.md); contrato de API em
[tucano/CONTRATO.md](tucano/CONTRATO.md).

Por muitos marcos o roadmap registrou paralelismo como bloqueado pela linguagem. **Estava
errado** — a leitura passou a usar uma thread por coluna, e o erro de raciocínio está
preservado no roadmap junto com o conserto. Falta paralelizar os operadores de execução.

A interoperabilidade de Parquet e Arrow é verificada **nos dois sentidos**: outra
implementação lê o que o Tucano escreve, e o Tucano lê arquivos que ela escreveu.
Round-trip próprio não prova nada — um leitor e um escritor com o mesmo mal-entendido
concordam entre si.

## Desenvolvimento

```bash
pixi run test      # suíte de testes
pixi run exemplo   # exemplo executável
pixi run bench     # benchmarks de fundação
pixi run bench-m3  # escala do executor
pixi run bench-m4  # SIMD contra o laço escalar
pixi run bench-m5  # leitura de CSV
pixi run bench-m6  # agregação, junção e ordenação
pixi run bench-m8  # o que o otimizador poupa
pixi run bench-m9  # execução em memória limitada
pixi run bench-parquet  # Parquet e column pruning
pixi run build     # precompilar o pacote
```

> **Cuidado com `.mojoc` obsoleto.** Se houver um `tucano.mojoc` precompilado no diretório do
> arquivo que você está compilando, o Mojo o prefere ao fonte — e módulos novos somem com um
> `value has no attribute ...` que não aponta a causa. Apague o `.mojoc`.

## Licença

[Apache-2.0](LICENSE).
