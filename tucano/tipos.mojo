"""Constantes legadas — preferir `DType`."""

from .dtype import DType


struct Tipo:
    comptime INTEIRO = DType.INTEIRO
    comptime REAL = DType.REAL
    comptime LOGICO = DType.LOGICO
    comptime TEXTO = DType.TEXTO
    comptime DATA = DType.DATA
    comptime DATAHORA = DType.DATAHORA

    @staticmethod
    def nome(codigo: Int) raises -> String:
        return DType(codigo).nome()
