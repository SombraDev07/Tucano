"""Gera fixtures Parquet para os testes do Tucano.

Roda no ambiente `fixtures` do pixi, que e separado do runtime:

    pixi run fixtures

Nenhum modulo em `tucano/` importa nada daqui. Este script existe porque um
parser de formato binario sem arquivo real para verificar nao e codigo pronto —
e sem ferramenta que escreva Parquet, nao ha arquivo real.

Os .parquet gerados sao commitados, entao rodar isto e necessario apenas quando
as fixtures mudarem.
"""

from datetime import date, datetime, timedelta
from decimal import Decimal
from pathlib import Path

import pyarrow as pa
import pyarrow.feather as feather
import pyarrow.parquet as pq

DESTINO = Path(__file__).resolve().parent.parent / "tests" / "fixtures"


def _escrever(nome, tabela, **kwargs):
    caminho = DESTINO / nome
    pq.write_table(tabela, caminho, **kwargs)
    meta = pq.ParquetFile(caminho).metadata
    print(
        f"  {nome:<28} {meta.num_rows:>6} linhas  "
        f"{meta.num_columns} colunas  {caminho.stat().st_size:>6} bytes  "
        f"{meta.num_row_groups} row group(s)"
    )


def temporal_grande():
    """Carimbos dos dois lados da epoch, e um texto para exercitar o dicionario.

    Antes de 1970 importa: o INT96 conta dia juliano e nanossegundos dentro do
    dia, e a conta de quem so testou com data futura passa despercebida.
    """
    n = 400
    return pa.table(
        {
            "quando": pa.array(
                [
                    datetime(2024, 1, 1) + timedelta(seconds=i * 37)
                    if i % 2 == 0
                    else datetime(1960, 6, 15) + timedelta(seconds=i * 37)
                    for i in range(n)
                ],
                type=pa.timestamp("us"),
            ),
            "grupo": pa.array([f"g{i % 9}" for i in range(n)]),
            "valor": pa.array([i * 0.25 for i in range(n)], type=pa.float64()),
        }
    )


def main():
    DESTINO.mkdir(parents=True, exist_ok=True)
    print("gerando fixtures Parquet em", DESTINO)

    # 1. tipos basicos, sem compressao, sem dicionario: o caminho PLAIN puro
    simples = pa.table(
        {
            "id": pa.array([1, 2, 3, 4, 5], type=pa.int64()),
            "valor": pa.array([10.5, 20.25, 30.0, 40.75, 50.125], type=pa.float64()),
            "ativo": pa.array([True, False, True, True, False], type=pa.bool_()),
            "cidade": pa.array(["SP", "RJ", "SP", "BH", "SP"], type=pa.string()),
        }
    )
    _escrever(
        "simples.parquet", simples, compression="none", use_dictionary=False
    )

    # 2. com ausentes, para exercitar os niveis de definicao
    com_na = pa.table(
        {
            "id": pa.array([1, None, 3, None, 5], type=pa.int64()),
            "valor": pa.array([10.5, 20.25, None, 40.75, None], type=pa.float64()),
            "cidade": pa.array(["SP", None, "SP", "BH", None], type=pa.string()),
        }
    )
    _escrever("com_na.parquet", com_na, compression="none", use_dictionary=False)

    # 3. dicionario ligado: paginas RLE_DICTIONARY
    dicionario = pa.table(
        {
            "cidade": pa.array(["SP", "RJ", "SP", "BH", "SP", "RJ", "SP"] * 20),
            "n": pa.array(list(range(140)), type=pa.int64()),
        }
    )
    _escrever(
        "dicionario.parquet", dicionario, compression="none", use_dictionary=True
    )

    # 4. temporais
    temporal = pa.table(
        {
            "quando": pa.array(
                [date(2024, 1, 15), date(2024, 2, 29), date(2023, 12, 1)],
                type=pa.date32(),
            ),
            "carimbo": pa.array(
                [
                    datetime(2024, 1, 15, 8, 30, 0),
                    datetime(2024, 2, 29, 23, 59, 59, 500000),
                    datetime(1969, 12, 31, 23, 59, 59),
                ],
                type=pa.timestamp("us"),
            ),
        }
    )
    _escrever("temporal.parquet", temporal, compression="none", use_dictionary=False)

    # 4b. datas em quantidade: e aqui que o escritor escolhe codificacao.
    # A fixture `temporal` tem tres linhas, o que e pouco para dicionarizar e
    # pouco para o delta — e por isso ela nao pegou o dicionario de datas
    # escrito com oito bytes por valor num tipo fisico de quatro. Interop so
    # prova o que o arquivo exercita.
    dias = 400
    datas = pa.table(
        {
            # poucos valores distintos: o escritor dicionariza
            "repetida": pa.array(
                [date(2024, 1, 1 + i % 7) for i in range(dias)], type=pa.date32()
            ),
            # crescente: o escritor manda em DELTA_BINARY_PACKED
            "crescente": pa.array(
                [date(2000, 1, 1) + timedelta(days=i * 3) for i in range(dias)],
                type=pa.date32(),
            ),
            # espalhada e com buracos, para o delta conviver com nivel de definicao
            "espalhada": pa.array(
                [
                    None
                    if i % 5 == 0
                    else date(1970, 1, 1) + timedelta(days=(i * 7919) % 20000)
                    for i in range(dias)
                ],
                type=pa.date32(),
            ),
            "carimbo": pa.array(
                [datetime(2024, 1, 1) + timedelta(seconds=i * 37) for i in range(dias)],
                type=pa.timestamp("us"),
            ),
        }
    )
    _escrever("datas.parquet", datas, compression="none", use_dictionary=False)

    # 4c. decimal: o Tucano nao tem tipo decimal, e um DECIMAL(9,2) guardado
    # como INT32 seria lido como o inteiro sem escala — 123,45 viraria 12345,
    # sem aviso. A fixture existe para o leitor **recusar**, nao para ler.
    decimal = pa.table(
        {
            "preco": pa.array(
                [Decimal("123.45"), Decimal("-67.89"), Decimal("0.01")],
                type=pa.decimal128(9, 2),
            )
        }
    )
    _escrever(
        "decimal.parquet",
        decimal,
        compression="none",
        use_dictionary=False,
        store_decimal_as_integer=True,
    )

    # 4d. gzip e INT96: o que outras implementacoes escrevem e o Tucano
    # precisa abrir. O Polars grava zstd por padrao e o Spark grava gzip; o
    # INT96 e o carimbo de tempo que Hive e Impala antigos deixaram por ai.
    _escrever("gzip.parquet", temporal_grande(), compression="gzip")
    _escrever(
        "int96.parquet",
        temporal_grande(),
        compression="none",
        use_deprecated_int96_timestamps=True,
    )

    # 4e. inteiros sem sinal: o Parquet e o Arrow guardam UINT32 nos mesmos 32
    # bits de um INT32, e quem le com sinal transforma 4294967295 em -1. Duas
    # fixtures: uma que cabe no Int64 e tem de ser lida certa, e uma acima de
    # 2^63 que tem de ser recusada.
    sem_sinal = pa.table(
        {
            "u8": pa.array([0, 200, 255], type=pa.uint8()),
            "u16": pa.array([0, 40000, 65535], type=pa.uint16()),
            "u32": pa.array([0, 2**31 + 7, 2**32 - 1], type=pa.uint32()),
            "u64": pa.array([0, 5, 2**62], type=pa.uint64()),
            "i64": pa.array([-3, 0, 2**62], type=pa.int64()),
        }
    )
    _escrever("sem_sinal.parquet", sem_sinal, compression="none", use_dictionary=False)
    grande_demais = pa.table(
        {"u64": pa.array([0, 2**64 - 1], type=pa.uint64())}
    )
    _escrever(
        "u64_grande.parquet", grande_demais, compression="none", use_dictionary=False
    )

    # 4f. zstd: o codec que o Polars grava por padrao. E vetores crus do codec,
    # para testar o descompressor sem passar pelo Parquet — cada um exercita um
    # caminho: bloco cru, RLE, literais em Huffman, quadro com varios blocos.
    _escrever("zstd.parquet", temporal_grande(), compression="zstd")

    import random as _r
    _r.seed(99)
    vetores = [
        ("um byte", b"x"),
        ("tudo igual", b"a" * 1000),
        ("aleatorio (bloco cru)", bytes(_r.getrandbits(8) for _ in range(1000))),
        ("repetido curto", b"abcabcabc" * 200),
        ("texto tabular", b"".join(
            ("registro %d;valor %d\n" % (i, i * 7)).encode() for i in range(2000))),
        ("json-ish", b"".join(
            ('{"id":%d,"nome":"item %d","ok":true}\n' % (i, i)).encode()
            for i in range(3000))),
        ("varios blocos", b"".join(
            ("linha %d com conteudo variado %s\n" % (i, "xyz"[i % 3] * (i % 40))).encode()
            for i in range(9000))),
        ("zeros", bytes(200000)),
        ("vazio", b""),
    ]
    def _fnv(dados):
        """FNV-1a de 64 bits: o vetor guarda o resumo do original, nao o
        original. Guardar os bytes crus faria a fixture ter megabytes para
        provar o que um numero de oito bytes ja prova."""
        h = 0xCBF29CE484222325
        for x in dados:
            h = ((h ^ x) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
        return h

    caminho = DESTINO / "zstd_vetores.bin"
    with open(caminho, "wb") as f:
        for _, cru in vetores:
            comp = bytes(pa.compress(cru, codec="zstd"))
            f.write(len(comp).to_bytes(4, "little"))
            f.write(len(cru).to_bytes(4, "little"))
            f.write(_fnv(cru).to_bytes(8, "little"))
            f.write(comp)
        f.write(b"\x00" * 16)
    print(
        f"  {'zstd_vetores.bin':<28} {len(vetores):>6} vetores"
        f"           {caminho.stat().st_size:>6} bytes"
    )

    # 5. snappy, a compressao padrao na pratica
    _escrever("snappy.parquet", simples, compression="snappy", use_dictionary=False)

    # 6. varios row groups, para exercitar pruning por grupo
    grande = pa.table(
        {
            "id": pa.array(list(range(3000)), type=pa.int64()),
            "grupo": pa.array([["a", "b", "c"][i % 3] for i in range(3000)]),
            "valor": pa.array([i * 0.5 for i in range(3000)], type=pa.float64()),
        }
    )
    _escrever(
        "grupos.parquet",
        grande,
        compression="none",
        use_dictionary=False,
        row_group_size=1000,
    )

    # Arrow IPC escrito por outra implementacao: e contra estes que o leitor
    # do Tucano e verificado. Ler o que a gente mesmo escreveu nao prova nada.
    print("gerando fixtures Arrow IPC")
    for nome, tabela in [
        ("simples", simples),
        ("com_na", com_na),
        ("temporal", temporal),
        ("sem_sinal", sem_sinal),
    ]:
        caminho = DESTINO / f"{nome}.arrow"
        feather.write_feather(tabela, caminho, compression="uncompressed")
        lido = pa.ipc.open_file(caminho).read_all()
        print(
            f"  {nome + '.arrow':<28} {lido.num_rows:>6} linhas  "
            f"{lido.num_columns} colunas  {caminho.stat().st_size:>6} bytes"
        )

    # Arrow com tipos que o Tucano nao le: a fixture existe para o leitor
    # **levantar** em vez de abortar. Indexar buffer que nao existe nao da erro
    # em Mojo — mata o processo, e `try` nao pega.
    estranhos = pa.table(
        {
            "so_nulos": pa.array([None, None], type=pa.null()),
            "categoria": pa.array(["a", "b"]).dictionary_encode(),
        }
    )
    caminho = DESTINO / "arrow_estranho.arrow"
    feather.write_feather(estranhos, caminho, compression="uncompressed")
    print(
        f"  {'arrow_estranho.arrow':<28} {estranhos.num_rows:>6} linhas  "
        f"{estranhos.num_columns} colunas  {caminho.stat().st_size:>6} bytes"
    )

    print("pronto — as fixtures sao commitadas; rode de novo so se mudarem")


if __name__ == "__main__":
    main()
