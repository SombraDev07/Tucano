"""Tucano — biblioteca tabular nativa em Mojo.

Superficie publica. O layout interno dos slabs (`buffer.mojo`) nao faz parte
dela: pode mudar entre versoes menores.
"""

from .dtype import DType
from .schema import Campo, Schema, Shape
from .buffer import Validity, StringStore
from .coluna import Coluna
from .tabela import Tabela
from .csv import ler_csv, para_csv
from .tipos import Tipo
from .datas import (
    DataCivil,
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
    ano,
    mes,
    dia,
)
from .consulta import Consulta, Tri, lazy
