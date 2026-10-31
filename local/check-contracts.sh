#!/usr/bin/env bash
# Confere se o pacote pkg/contracts (structs, envelope e JSON Schemas das mensagens) é idêntico nos
# quatro repositórios que trocam mensagens. A fonte canônica é o postech-tc4-os-service; os outros
# carregam uma cópia literal, e uma cópia divergente é um contrato quebrado entre os serviços.
#
#   make contracts            (ou ./check-contracts.sh)
#   ROOT=/outra/pasta ./check-contracts.sh
#
# Sai com 1 e lista os arquivos que diferem da cópia canônica quando há divergência.
set -euo pipefail

ROOT=${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
CANONICAL=postech-tc4-os-service
REPOS=(postech-tc4-os-service postech-tc4-billing-service postech-tc4-execution-service postech-tc4-notification-lambda)

if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$@"; }
else
  sha256() { shasum -a 256 "$@"; }
fi

# manifest REPO → "hash  caminho" de cada arquivo de pkg/contracts, em ordem estável.
manifest() {
  local dir="$ROOT/$1/pkg/contracts"
  [ -d "$dir" ] || { echo "✘ $1: $dir não existe" >&2; return 1; }
  (cd "$dir" && find . -type f ! -name '.DS_Store' | LC_ALL=C sort | while read -r f; do sha256 "$f"; done)
}

want=$(manifest "$CANONICAL")
want_sum=$(printf '%s\n' "$want" | sha256 | cut -c1-16)
status=0
for repo in "${REPOS[@]}"; do
  got=$(manifest "$repo") || { status=1; continue; }
  sum=$(printf '%s\n' "$got" | sha256 | cut -c1-16)
  if [ "$sum" = "$want_sum" ]; then
    printf '  ✔ %-34s %s\n' "$repo" "$sum"
  else
    printf '  ✘ %-34s %s (canônico: %s)\n' "$repo" "$sum" "$want_sum"
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed -n 's/^\([<>]\) [0-9a-f]*  \.\//    \1 /p' | sort -u -k2 || true
    status=1
  fi
done

if [ "$status" -ne 0 ]; then
  echo "pkg/contracts divergiu: copie o pacote do $CANONICAL (< canônico, > cópia) e rode os testes de cada repo." >&2
fi
exit "$status"
