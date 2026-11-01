#!/usr/bin/env bash
# Roda as collections Postman dos três serviços com newman (em container, sem node local) contra a
# stack e2e, intercaladas no fluxo da OS:
#
#   1. os-service         autenticação, cadastros, token do cliente e abertura das OS
#   2. execution-service  diagnóstico
#   3. billing-service    orçamento, aprovação/recusa do cliente, pagamento simulado e webhook
#   4. execution-service  reparo e compensações
#   5. billing-service    compensações (orçamento cancelado, estorno)
#   6. os-service         entrega, consultas do cliente, compensações e limpeza
#
# As variáveis passam de uma etapa para a outra por um environment compartilhado
# (--export-environment). As pastas "só rodando sozinha" de cada collection ficam de fora.
#
#   make up && make lambdas && make postman
#   ./postman.sh os|billing|execution     # uma collection sozinha, todas as pastas
#
# Sai com código diferente de zero se qualquer asserção falhar. Cada execução gera CPF, placa e
# códigos novos, então pode rodar várias vezes seguidas.
set -uo pipefail
cd "$(dirname "$0")"

IMAGE=${NEWMAN_IMAGE:-postman/newman:6.1.3-alpine}
NETWORK=${E2E_NETWORK:-tc4-e2e_default}
REPOS=${REPOS:-$(cd ../.. && pwd)}

collection_path() { echo "$REPOS/postech-tc4-$1-service/postman_collection.json"; }
base_url() {
  case $1 in
    os) echo http://os-service:8080 ;;
    billing) echo http://billing-service:8082 ;;
    execution) echo http://execution-service:8080 ;;
  esac
}

# Cores só no terminal (a saída também vai para arquivo, como no postman-sample-output.txt).
if [ -t 1 ]; then BOLD=$'\033[1m' BLUE=$'\033[1;34m' GREEN=$'\033[1;32m' RED=$'\033[31m' OFF=$'\033[0m'; else BOLD= BLUE= GREEN= RED= OFF=; fi
die() { printf '%s✘ %s%s\n' "$RED" "$*" "$OFF" >&2; exit 2; }

# ── pré-condições ────────────────────────────────────────────────────────────────────────────
for c in os billing execution; do
  [ -f "$(collection_path "$c")" ] || die "collection não encontrada: $(collection_path "$c")"
done
for svc in e2e-os-service e2e-billing-service e2e-execution-service e2e-localstack; do
  st=$(docker inspect -f '{{.State.Health.Status}}' "$svc" 2>/dev/null) || die "$svc não está rodando (make up && make lambdas)"
  [ "$st" = healthy ] || die "$svc está $st"
done
if [ -z "$(docker ps -q --filter name='^e2e-gateway$')" ]; then
  ./gateway.sh up || die "não consegui subir o gateway (as Lambdas estão publicadas? make lambdas)"
fi
docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull -q "$IMAGE" >/dev/null || die "não consegui baixar $IMAGE"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/tc4-newman.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/out"
for c in os billing execution; do cp "$(collection_path "$c")" "$WORK/$c.json"; done

# URLs vistas de dentro da rede do compose; o resto do environment é preenchido pelos scripts.
cat >"$WORK/env.json" <<'EOF'
{
  "name": "tc4-e2e (newman)",
  "values": [
    { "key": "os_url", "value": "http://os-service:8080", "enabled": true },
    { "key": "billing_url", "value": "http://billing-service:8082", "enabled": true },
    { "key": "exec_url", "value": "http://execution-service:8080", "enabled": true },
    { "key": "gateway_url", "value": "http://e2e-gateway", "enabled": true },
    { "key": "mailpit_url", "value": "http://mailpit:8025", "enabled": true }
  ]
}
EOF

FAILED=0
STAGES=()

# stage "título" collection [pasta...]   (sem pastas: a collection inteira)
stage() {
  local title=$1 col=$2 n=$((${#STAGES[@]} + 1))
  shift 2
  local args=(run "$col.json" -e env.json --export-environment env.json
    --env-var "base_url=$(base_url "$col")" --timeout-request 20000
    --reporters cli,json --reporter-json-export "out/$n.json")
  local f
  for f in "$@"; do args+=(--folder "$f"); done
  printf '\n%s▶ %d. %s%s\n' "$BLUE" "$n" "$title" "$OFF"
  STAGES+=("$title")
  docker run --rm --network "$NETWORK" -v "$WORK:/etc/newman" "$IMAGE" "${args[@]}" || FAILED=1
}

case ${1:-fluxo} in
  fluxo)
    stage "os-service: autenticação, cadastros, token do cliente e abertura das OS" os \
      "0. Health" "1. Autenticação" "2. Cadastros" "3. Token do cliente (gateway)" "4. Abertura da OS"
    stage "execution-service: diagnóstico" execution "1. Health e acesso" "2. Diagnóstico"
    stage "billing-service: orçamento, decisão do cliente, pagamento e webhook" billing \
      "1. Health" "2. Orçamento" "3. Pagamento" "4. Webhook Mercado Pago"
    stage "execution-service: reparo e compensações" execution "4. Reparo" "5. Compensações"
    stage "billing-service: compensações" billing "5. Compensações"
    stage "os-service: entrega, consultas do cliente, compensações e limpeza" os \
      "6. Entrega e consultas" "7. Compensações" "8. Limpeza"
    ;;
  os | billing | execution)
    stage "$1-service sozinha (todas as pastas)" "$1"
    ;;
  *)
    sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac

# ── resumo ───────────────────────────────────────────────────────────────────────────────────
: >"$WORK/rows.jsonl"
i=0
for title in "${STAGES[@]}"; do
  i=$((i + 1))
  f="$WORK/out/$i.json"
  if [ -s "$f" ]; then
    jq -c --arg t "$title" '{t: $t, r: .run.stats.requests.total, a: .run.stats.assertions.total, f: (.run.failures | length)}' \
      "$f" >>"$WORK/rows.jsonl"
    [ "$(jq '.run.failures | length' "$f")" = 0 ] || FAILED=1
  else
    jq -nc --arg t "$title" '{t: $t, r: "-", a: "-", f: "sem relatório"}' >>"$WORK/rows.jsonl"
    FAILED=1
  fi
done
printf '\n%s' "$BOLD"
jq -s -r '
  def pad(n): tostring | if length < n then . + (" " * (n - length)) else . end;
  def lpad(n): tostring | if length < n then (" " * (n - length)) + . else . end;
  def row(a; b; c; d; e): [(a | pad(3)), (b | pad(72)), (c | lpad(11)), (d | lpad(10)), (e | lpad(13))] | join(" ");
  row(""; "etapa"; "requisições"; "asserções"; "falhas"),
  (to_entries[] | row("\(.key + 1)."; .value.t; .value.r; .value.a; .value.f)),
  row(""; "total"; (map(.r | numbers) | add); (map(.a | numbers) | add); (map(.f | numbers) | add))
' "$WORK/rows.jsonl" | sed "1s/\$/$OFF/"

if [ "$FAILED" -ne 0 ]; then
  printf '\n%s✘ newman encontrou falhas%s\n' "$RED" "$OFF"
  exit 1
fi
printf '\n%s✔ collections Postman: 0 falhas%s\n' "$GREEN" "$OFF"
