"""Reexport de `Consulta` (M3).

`Tabela` e `Consulta` sao mutuamente recursivas — `Tabela.onde()` devolve
`Consulta`, `Consulta.coletar()` devolve `Tabela` — e o Mojo nao aceita ciclo
entre modulos. As duas vivem em `tucano.tabela`. Este modulo existe para nao
quebrar `from tucano.consulta import Consulta`.
"""

from .tabela import Consulta, lazy
from .executor import Tri
