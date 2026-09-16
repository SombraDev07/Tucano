#!/usr/bin/env bash
# Verificacao completa: testes, exemplos, benchmarks curtos e interoperabilidade.
#
#   ./tools/verificar_tudo.sh
#
# A suite de testes nao cobre as ferramentas de interop — foi assim que um
# rename as quebrou em silencio uma vez. Este script cobre.
#
# Nem cobria os benchmarks: o `bench-m4` ficou sem compilar por varios marcos,
# e so apareceu quando alguem foi citar um numero dele. Compilar todos custa
# pouco e fecha esse buraco.
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
passo "benchmarks compilam" ./tools/compilar_benches.sh
passo "exemplo"           ./pixi run exemplo
passo "round-trip parquet" ./pixi run parquet-roundtrip
passo "round-trip arrow"   ./pixi run arrow-roundtrip
passo "round-trip xlsx"    ./pixi run xlsx-roundtrip
passo "interop parquet"    ./pixi run -e fixtures interop
passo "interop arrow"      ./pixi run -e fixtures interop-arrow
passo "interop xlsx"       ./pixi run -e fixtures interop-xlsx

if [ "$falhou" -eq 0 ]; then
  printf '\n\033[32mtudo verde\033[0m\n'
else
  printf '\n\033[31mhouve falha\033[0m\n'
fi
exit "$falhou"
