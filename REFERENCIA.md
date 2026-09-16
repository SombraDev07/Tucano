# Referência do Tucano

Toda a API pública, com a assinatura e o que cada coisa faz. Assinaturas
extraídas do código na versão **1.6.0** — se divergirem, o código manda.

Para o *porquê* das decisões (semântica de NA, layout de memória, o que o
Parquet aceita e recusa), veja [tucano/CONTRATO.md](tucano/CONTRATO.md).

---

## Ler arquivos

| assinatura | o que faz |
|---|---|
| `ler_csv(caminho, delimitador=",", tem_cabecalho=True, nrows=-1, pular=0)` | Lê o CSV inteiro para a memória, **inferindo o tipo** de cada coluna. `nrows` limita as linhas lidas; `pular` ignora linhas do começo. |
| `ler_csv_tipado(caminho, schema, ...)` | Igual, mas com os tipos que você der — não infere. |
| `ler_parquet(caminho, colunas=[])` | Lê Parquet. Passando `colunas`, **só elas saem do disco**. |
| `ler_arrow(caminho)` | Lê um arquivo Arrow IPC. |
| `ler_xlsx(caminho, planilha="", tem_cabecalho=True)` | Abre uma planilha `.xlsx`. Sem `planilha`, pega a primeira. |
| `varredura_parquet(caminho)` | **Não lê nada.** Devolve um plano; o disco só é tocado no `coletar()`, e só nas colunas que o plano usar. |
| `esquema_parquet(caminho)` | Só o esquema, lido do rodapé, sem tocar nos dados. |
| `metadados_parquet(caminho)` | Linhas, row groups, codificações e compressão do arquivo. |

## Gravar arquivos

| assinatura | o que faz |
|---|---|
| `para_csv(tabela, caminho, delimitador=",")` | Grava CSV, com aspas RFC 4180 onde precisa. |
| `para_parquet(tabela, caminho, linhas_por_grupo=500_000, compressao="snappy")` | Grava Parquet escolhendo a codificação que **medir** menor para cada coluna. `0` em `linhas_por_grupo` grava tudo num row group. |
| `para_arrow(tabela, caminho)` | Grava Arrow IPC. |
| `para_xlsx(tabela, caminho, planilha="Planilha1")` | Grava `.xlsx` de uma aba. |

## Olhar a tabela

| assinatura | o que faz |
|---|---|
| `t.mostrar(n=20)` | Imprime **cortando o meio**: as primeiras e as últimas, com `...` e quantas ficaram de fora. `mostrar(0)` imprime tudo. |
| `t.primeiras(n=5)` | Imprime só as primeiras `n`. |
| `t.resumo()` | Uma linha por coluna: tipo, linhas, válidos, ausentes, média, mínimo, máximo. |
| `t.esquema()` / `t.schema()` | O esquema. `.descrever()` nele imprime nome e tipo por linha. |
| `t.linhas()` · `t.colunas()` · `t.shape()` | Tamanho. |
| `t.nomes()` | Nomes das colunas. |
| `t.pegar(nome)` | A `Coluna`, para ler valor a valor ou pedir estatística. |
| `t.contar_valores(nome)` | Quantas vezes cada valor aparece. Bom para achar chave duplicada antes de juntar. |
| `t.unicos(nome)` | Os valores distintos. |
| `t.soma(nome)` · `t.media(nome)` | Atalhos para a coluna inteira. |

## Escolher linhas e colunas

| assinatura | o que faz |
|---|---|
| `t.onde(pred)` | Filtra pelas linhas em que `pred` é verdadeiro. Ausente é **Desconhecido**, e Desconhecido não entra — nem na negação. |
| `t.selecionar([nomes])` | Fica só com essas colunas. |
| `t.ordenar([chaves], descendente=False)` | Ordena. Ausente vai sempre para o fim. |
| `t.limite(n)` | As primeiras `n` linhas do resultado. |
| `t.remover(nome)` · `t.adicionar(coluna)` | Tira ou põe uma coluna. |

## Colunas calculadas

| assinatura | o que faz |
|---|---|
| `t.com_coluna(nome, expr)` | Acrescenta uma coluna calculada a partir das que existem. **Não altera a tabela original** — devolve outra. |

A expressão pode ser aritmética, texto, data ou uma comparação (que vira coluna
de marcação, `True`/`False`).

```mojo
t.com_coluna("com_imposto", coluna("valor").vezes(lit(1.10)))
 .com_coluna("mes", mes(coluna("data")))
 .com_coluna("acima_de_mil", coluna("valor").gt(lit(1000.0)))
 .com_coluna("cidade_limpa", normalizar(coluna("cidade")))
```

## Expressões

**Construtores**

| assinatura | o que faz |
|---|---|
| `coluna(nome)` | Referência a uma coluna. |
| `lit(f64)` · `lit_int(i)` · `lit_texto(s)` · `lit_bool(b)` | Valor fixo. |
| `lit_data("2024-01-15")` · `lit_datahora("2024-01-15T10:30:00")` | Data e datahora literais. |

**Comparação** — devolvem verdadeiro/falso/desconhecido

| método | o que faz |
|---|---|
| `.gt(e)` `.ge(e)` `.lt(e)` `.le(e)` | maior, maior-ou-igual, menor, menor-ou-igual |
| `.eq(e)` `.ne(e)` | igual, diferente. Texto compara **literal**: acento e caixa contam. |
| `.contem(lit_texto(trecho))` | O texto contém o trecho. Busca literal, sobre bytes. |
| `.em([lit_texto("SP"), lit_texto("RJ")])` | É um dos valores da lista — o `IN` do SQL. Lista vazia é falso para toda linha. |

**Lógica e aritmética**

| método | o que faz |
|---|---|
| `.e(e)` `.ou(e)` `.nao()` | E, OU, NÃO — de três valores, como no SQL |
| `.mais(e)` `.menos(e)` `.vezes(e)` `.sobre(e)` | + − × ÷ |

## Texto

| assinatura | o que faz |
|---|---|
| `minusculas(expr)` · `maiusculas(expr)` | Troca a caixa, inclusive de vogal acentuada. |
| `aparar(expr)` | Tira espaço das pontas **e junta os do meio**: `"  São   Paulo "` → `"São Paulo"`. |
| `sem_acento(expr)` | `ã`→`a`, `ç`→`c`, `í`→`i`. O que não está na tabela passa intacto. |
| `normalizar(expr)` | Os três acima juntos: `" São  PAULO "` → `"sao paulo"`. É o que se faz **antes de agrupar ou juntar**. |
| `sem_espacos(expr)` | Tira **todo** espaço. Ilegível de propósito: serve como **chave de comparação**, não para mostrar. |

`sem_espacos(normalizar(coluna("cidade")))` faz `"S  AO PAULO"`, `"São  Paulo"`
e `"sao paulo"` virarem a mesma chave — inclusive o caso de espaço enfiado no
meio da palavra, que nenhuma regra que preserve espaço resolve.

Nenhuma delas tira pontuação: decidir que pontuação é ruído depende do dado.

## Datas

| assinatura | o que faz |
|---|---|
| `ano(expr)` · `mes(expr)` · `dia(expr)` | Extrai o componente. Servem para `data` e `datahora`. |
| `hora(expr)` · `minuto(expr)` · `segundo(expr)` | Só para `datahora` — uma coluna `data` não guarda hora. |

Uma coluna temporal compara direto: `coluna("data").ge(lit_data("2024-02-01"))`.

## Agrupar e agregar

| assinatura | o que faz |
|---|---|
| `t.agrupar([chaves])` | Abre o agrupamento pelas colunas dadas. |
| `.agregar([agregacoes])` | Fecha, uma linha por grupo. |
| `t.agregar_total([agregacoes])` | Sem grupo: uma linha para a tabela inteira. |

**Agregações**: `soma(col)`, `media(col)`, `minimo(col)`, `maximo(col)`,
`contar()` (linhas), `contar_de(col)` (não-ausentes), `primeiro(col)`,
`distintos(col)`.

```mojo
t.agrupar(["cidade"]).agregar([soma("valor"), media("valor"), contar()])
```

## Juntar e empilhar

| assinatura | o que faz |
|---|---|
| `t.unir(outra, [chaves], tipo="interno")` | O PROCV. `"esquerda"` guarda toda linha da tabela da esquerda e põe `NA` no que não casou; `"interno"` descarta quem não casou. A chave aparece uma vez só. |
| `t.concatenar(outra)` | Empilha as linhas de outra tabela com o mesmo esquema. |

Atenção: se a tabela da direita tiver a chave repetida, a junção **multiplica
linhas** — uma para cada correspondência. O PROCV do Excel esconde isso pegando
a primeira. Confira antes com `contar_valores`.

## Ausentes (NA)

| assinatura | o que faz |
|---|---|
| `t.remover_duplicadas([nomes])` | Guarda a **primeira** linha de cada combinação distinta. Sem `nomes`, a linha inteira é a chave. Ordene antes se quiser escolher qual sobrevive. |
| `t.remover_na([nomes])` | Descarta linhas com ausente. Sem `nomes`, olha todas as colunas. |
| `t.preencher_na(nome, valor)` | Troca ausente por um valor. |
| `t.eh_ausente(nome, i)` | Se aquela célula está ausente. |
| `coluna.contar_ausentes()` | Quantos ausentes na coluna. |

Ausente não é zero nem string vazia: comparar com ausente dá **Desconhecido**, e
Desconhecido não passa no filtro — nem quando você nega.

## SQL

| assinatura | o que faz |
|---|---|
| `consultar_sql(texto)` | `SELECT` sobre arquivo: `FROM 'vendas.parquet'`. Passa pelo mesmo planejador da API fluente. |
| `consultar_sql_em(texto, catalogo)` | Idem, com tabelas já em memória. |

Cobre `SELECT`/`WHERE`/`GROUP BY`/`HAVING`/`ORDER BY`/`LIMIT`, `JOIN ... USING`,
`COUNT(DISTINCT)` e `SELECT DISTINCT`.

## Executar e inspecionar

| assinatura | o que faz |
|---|---|
| `q.coletar()` | Executa o plano e devolve uma `Tabela`. |
| `q.coletar_em_fluxo(linhas_por_fatia=200_000)` | Executa lendo row group por row group — o arquivo nunca entra inteiro na memória. |
| `q.pode_fluir()` | Texto **vazio** se o plano executa em fluxo; a razão, se não executa. |
| `q.descrever()` | O plano lógico. |
| `q.explicar()` | O plano antes e depois do otimizador, com as colunas podadas e as regras aplicadas. |
| `q.descrever_fisico()` | Os operadores físicos. |
| `q.avisos()` | Onde a consulta caiu fora do caminho vetorizado. |
| `q.esquema_previsto()` | Os tipos do resultado **sem executar**. |

## Uma coluna isolada

`t.pegar(nome)` devolve uma `Coluna`:

| assinatura | o que faz |
|---|---|
| `c.tamanho()` · `c.dtype()` | Quantas linhas, qual tipo. |
| `c.texto_em(i)` | O valor da linha `i` como texto (`"NA"` se ausente). |
| `c.soma()` · `c.media()` · `c.minimo()` · `c.maximo()` | Estatística da coluna, ignorando ausentes. |
| `c.contar_ausentes()` · `c.cardinalidade()` | Quantos ausentes; quantos valores distintos. |

## Variável de ambiente

`TUCANO_THREADS=1` fixa o número de threads da leitura — útil para embutir o
Tucano onde já existe um conjunto de threads.
