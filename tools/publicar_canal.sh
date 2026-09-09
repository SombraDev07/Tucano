#!/usr/bin/env bash
# Publica o canal conda do Tucano no GitHub Pages.
#
# Um canal conda e uma arvore de arquivos estatica servida por HTTP — nada mais
# que isso. Verificado ponta a ponta: com a arvore servida por um `http.server`
# qualquer, `pixi install` busca `<canal>/noarch/repodata.json`, baixa o
# `.conda` e instala em `lib/mojo/`. Se o GitHub Pages serve a arvore, ele e o
# canal; nao ha nada de especial num "canal conda de verdade".
#
#   ./tools/publicar_canal.sh
#
# Na primeira vez a ordem importa: **primeiro** o push da branch, **depois** o
# Settings -> Pages. O GitHub so oferece `gh-pages` na lista de origens depois
# que a branch existe no remoto.
#
#   1. ./tools/publicar_canal.sh
#   2. git -C .publicacao push origin gh-pages
#   3. Settings -> Pages -> Source "Deploy from a branch", gh-pages, / (root)
#
# Depois, o usuario instala assim:
#
#   pixi add tucano -c https://sombradev07.github.io/Tucano
#
# O script **nao empurra nada**: ele deixa o commit pronto na branch e imprime o
# `git push`. Publicar e ato do dono, nao efeito colateral de um script.
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RAIZ"

VERSAO=$(grep -m1 '^version = ' pixi.toml | cut -d'"' -f2)
echo "== publicando a versao $VERSAO"

# A branch gh-pages e uma arvore separada, e o canal precisa **acumular** as
# versoes: quem fixou `tucano ==0.41.0` tem de continuar resolvendo. Por isso o
# pacote novo e construido dentro do que ja esta publicado — o rattler-build
# reindexa a pasta inteira, e o `repodata.json` sai com todas as versoes.
rm -rf .publicacao
if git show-ref --verify --quiet refs/heads/gh-pages; then
  git worktree add .publicacao gh-pages
else
  echo "== criando a branch gh-pages (primeira publicacao)"
  git worktree add --detach .publicacao
  git -C .publicacao checkout --orphan gh-pages
  git -C .publicacao rm -rf . >/dev/null 2>&1 || true
fi

./pixi run -e publicar rattler-build build --recipe recipe.yaml --output-dir .publicacao

if [ ! -f .publicacao/noarch/repodata.json ]; then
  echo "erro: .publicacao/noarch/repodata.json nao existe — o build falhou" >&2
  exit 1
fi

echo "== versoes no canal depois deste build:"
python3 - <<'PY'
import json
d = json.load(open(".publicacao/noarch/repodata.json"))
for nome, v in sorted((p["name"], p["version"]) for p in d.get("packages.conda", {}).values()):
    print(f"   {nome} {v}")
PY

cd .publicacao
git add -A
if git diff --cached --quiet; then
  echo "== nada mudou: esta versao ja esta no canal"
else
  git commit -q -m "canal: tucano $VERSAO"
  echo
  echo "== commit pronto. Para publicar de verdade:"
  echo "     git -C .publicacao push origin gh-pages"
  echo
  echo "   E o usuario passa a instalar com:"
  echo "     pixi add tucano -c https://sombradev07.github.io/Tucano"
fi
