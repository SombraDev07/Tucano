#!/usr/bin/env bash
# So compila os benchmarks — nao roda. E barato e pega o que a suite nao pega.
#
# O `bench-m4` ficou sem compilar por varios marcos: `Coluna.de_reais` passou a
# exigir posse da lista, o benchmark continuou passando por referencia, e
# ninguem viu porque a verificacao nunca tocava nos benchmarks. Quem for citar
# um numero descobre na hora de citar, que e tarde.
set -euo pipefail
cd "$(dirname "$0")/.."

falhou=0
for arquivo in bench/*.mojo; do
  if saida=$(./pixi run mojo build -I . -o /dev/null "$arquivo" 2>&1); then
    printf '   ok    %s\n' "$arquivo"
  else
    printf '   FALHA %s\n' "$arquivo"
    printf '%s\n' "$saida" | grep "error:" | head -3 | sed 's/^/         /'
    falhou=1
  fi
done
exit "$falhou"
