"""Tucano — biblioteca tabular nativa em Mojo.

Superficie publica. O layout interno dos slabs (`buffer.mojo`) nao faz parte
dela: pode mudar entre versoes menores.
"""

from .dtype import DType
from .schema import Campo, Schema, Shape
from .buffer import Validity, StringStore
from .coluna import Coluna
from .tabela import Tabela
from .csv import ler_csv, ler_csv_tipado, LeitorCSV, para_csv
from .tipos import Tipo
from .datas import (
    DataCivil,
    DataHoraCivil,
    micros_desde_epoch,
    civil_de_micros,
    eh_datahora_iso,
    parse_datahora_iso,
    datahora_para_texto,
    dias_desde_epoch,
    civil_de_dias,
    eh_data_iso,
    parse_data_iso,
    data_para_texto,
)
from .erros import sugerir_nome
from .expr import (
    Expr,
    coluna,
    lit,
    lit_int,
    lit_texto,
    lit_bool,
    lit_data,
    lit_datahora,
    ano,
    mes,
    dia,
    hora,
    minuto,
    segundo,
)
from .vetor import Vetor, Unidade
from .plano import Etapa, TipoEtapa
from .executor import Tri
from .parquet import (
    ler_parquet,
    para_parquet,
    esquema_parquet,
    metadados_parquet,
    MetadadosParquet,
    PTipo,
    PCodificacao,
    PCompressao,
)
from .agregacao import (
    Agregacao,
    TipoAgregacao,
    soma,
    media,
    contar,
    contar_de,
    minimo,
    maximo,
    primeiro,
    distintos,
)
from .painel import Painel, Widget, TipoWidget
from .consulta import Consulta, lazy
