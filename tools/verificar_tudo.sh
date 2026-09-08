#!/usr/bin/env bash
# Verificacao completa: testes, exemplos, benchmarks curtos e interoperabilidade.
#
#   ./tools/verificar_tudo.sh
#
# A suite de testes nao cobre as ferramentas de interop — foi assim que um
# rename as quebrou em silencio uma vez. Este script cobre.
set -euo pipefail
cd "$(dirname "$0")/.."

falhou=0
passo() {
  printf '\n\033[1m== %s\033[0m\n' "$1"
  shift
  if "$@"; then
    printf '   ok\n'
  else
    printf '   FALHOU\n'
    falhou=1
  fi
}

passo "testes"            ./pixi run test
passo "exemplo"           ./pixi run exemplo
passo "round-trip parquet" ./pixi run parquet-roundtrip
passo "round-trip arrow"   ./pixi run arrow-roundtrip
passo "interop parquet"    ./pixi run -e fixtures interop
passo "interop arrow"      ./pixi run -e fixtures interop-arrow

if [ "$falhou" -eq 0 ]; then
  printf '\n\033[32mtudo verde\033[0m\n'
else
  printf '\n\033[31mhouve falha\033[0m\n'
fi
exit "$falhou"
