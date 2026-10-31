#!/usr/bin/env bash
# Roteiro de demonstração (vídeo) contra o ambiente na AWS, tudo pelo API Gateway:
#
#   1. caminho feliz: OS aberta → diagnóstico → orçamento → aprovação do cliente (JWT do CPF pela
#      Lambda issuer) → pagamento → reparo → entrega, com a visão composta no /details
#   2. pagamento recusado → compensação (orçamento cancelado, peças devolvidas, execução cancelada)
#   3. falha no reparo depois de pago → estorno → OS cancelada
#
# Uso:
#   GATEWAY=https://<id>.execute-api.us-east-1.amazonaws.com scripts/demo.sh [feliz|pagamento|reparo|tudo]
#
# Sem GATEWAY, lê o endpoint do state do Terraform deste repositório. A senha do admin vem de
# ADMIN_PASSWORD ou de ~/.postech-tc4/admin-password (gerada pelo setup-github.sh app).
# PAUSE=1 espera Enter entre as etapas, para narrar. Com o billing em PAYMENT_GATEWAY=mercadopago,
# o pagamento não é simulado: o script mostra o link do Checkout Pro e espera o pagamento de teste.
set -euo pipefail

GATEWAY=${GATEWAY:-$(terraform -chdir="$(dirname "$0")/.." output -raw api_gateway_endpoint 2>/dev/null || true)}
[ -n "$GATEWAY" ] || { echo "defina GATEWAY com o endpoint do API Gateway" >&2; exit 1; }
API="$GATEWAY/api/v1"
ADMIN_PASSWORD=${ADMIN_PASSWORD:-$(cat "$HOME/.postech-tc4/admin-password" 2>/dev/null || true)}
[ -n "$ADMIN_PASSWORD" ] || { echo "defina ADMIN_PASSWORD" >&2; exit 1; }
CPF=${CPF:-52998224725}
EMAIL=${EMAIL:-ana.demo@example.com}
SCENARIO=${1:-tudo}

step() { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; [ "${PAUSE:-0}" = 1 ] && read -r -p "  (Enter para continuar) " _ </dev/tty || true; }
ok() { printf '  \033[32m✔\033[0m %s\n' "$*"; }
info() { printf '  \033[2m%s\033[0m\n' "$*"; }
fail() { printf '  \033[31m✘ %s\033[0m\n' "$*"; exit 1; }

# req MÉTODO URL TOKEN [corpo] [headers...] → corpo da resposta; falha em 4xx/5xx.
req() {
  local method=$1 url=$2 token=$3 body=${4:-}
  shift 4 || shift $#
  local args=(-sS -X "$method" -H 'Content-Type: application/json' -w '\n%{http_code}')
  [ -n "$token" ] && args+=(-H "Authorization: Bearer $token")
  [ -n "$body" ] && args+=(-d "$body")
  for h in "$@"; do args+=(-H "$h"); done
  local out code
  out=$(curl "${args[@]}" "$url")
  code=${out##*$'\n'}
  out=${out%$'\n'*}
  if [ "$code" -ge 400 ]; then echo "$method $url → $code $out" >&2; return 1; fi
  echo "$out"
}

wait_for() { # descrição comando valor-esperado [tentativas]
  local what=$1 cmd=$2 want=$3 got=""
  for _ in $(seq 1 "${4:-90}"); do
    got=$(eval "$cmd" 2>/dev/null || true)
    [ "$got" = "$want" ] && { ok "$what: $want"; return; }
    sleep 1
  done
  fail "$what: esperava $want, está ${got:-vazio}"
}
os_status() { req GET "$API/service-orders/$1" "$ADMIN" | jq -r .status; }
exec_status() { req GET "$API/executions/$1" "$ADMIN" | jq -r .status; }
budget() { req GET "$API/budgets/os/$1" "$ADMIN"; }
stock() { req GET "$API/parts/$PART_ID" "$ADMIN" | jq -r .stock; }

open_os() { # [falha simulada]
  local extra=()
  [ -n "${1:-}" ] && extra=("X-Simulate-Failure: $1")
  req POST "$API/service-orders" "$ADMIN" \
    "{\"requester_document\":\"$CPF\",\"vehicle_plate\":\"$PLATE\",\"notes\":\"barulho ao frear\"}" ${extra[@]+"${extra[@]}"} | jq -r .id
}

diagnose() {
  wait_for "execução na fila" "exec_status $1" queued_diagnosis
  req POST "$API/executions/$1/diagnosis/start" "$ADMIN" >/dev/null
  req POST "$API/executions/$1/diagnosis/complete" "$ADMIN" \
    "{\"services\":[{\"code\":$SERVICE_CODE}],\"parts\":[{\"manufacturer_code\":\"$PART_CODE\",\"quantity\":2}],\"notes\":\"pastilhas gastas\"}" >/dev/null
  ok "mecânico concluiu o diagnóstico: 1 serviço e 2 pastilhas"
}

approve() {
  wait_for "OS" "os_status $1" awaiting_approval
  local b
  b=$(budget "$1")
  info "orçamento $(jq -r .id <<<"$b"): total R\$ $(jq -r .total <<<"$b")"
  req POST "$API/budgets/$(jq -r .id <<<"$b")/approve" "$CLIENT" >/dev/null
  ok "cliente aprovou com o token do CPF"
}

pay() { # os approved|rejected
  wait_for "pagamento criado" "budget $1 | jq -r .payment.status" pending
  local p url
  p=$(budget "$1" | jq -r .payment.id)
  url=$(req GET "$API/payments/$p" "$ADMIN" | jq -r '.checkout_url // empty')
  if [[ "$url" == *mercadopago* ]]; then
    info "Checkout Pro: $url"
    info "pague com o usuário comprador de teste ($2 = cartão de teste aprovado ou recusado)"
    wait_for "pagamento" "req GET $API/payments/$p $ADMIN | jq -r .status" "$2" 600
  else
    req POST "$API/payments/$p/simulate" "$ADMIN" "{\"status\":\"$2\"}" >/dev/null
    ok "pagamento $2 (gateway fake)"
  fi
}

show_details() {
  req GET "$API/service-orders/$1/details" "$ADMIN" | jq '{status: .service_order.status, partial, saga: {state: .saga.state, motivo: .saga.failure_reason},
    orcamento: .budget.status, pagamento: .budget.payment.status, execucao: .execution.status,
    historico: [.history[] | "\(.from // "-") → \(.to)"]}'
}

# ─────────────────────────────────────────────────────────────────────────────
step "preparação: login da equipe e cadastro do cliente, do veículo, do serviço e da peça"
ADMIN=$(req POST "$API/auth/login" "" "{\"email\":\"admin@workshop.com\",\"password\":\"$ADMIN_PASSWORD\"}" | jq -r .access_token)
ok "equipe autenticada"
SUF=$((RANDOM % 9000 + 1000))
PLATE="DEM$SUF"
SERVICE_CODE=$((SUF * 10 + RANDOM % 10))
PART_CODE="PAS-DEMO-$SUF"
req POST "$API/requesters" "$ADMIN" "{\"name\":\"Ana Demo\",\"document\":\"$CPF\",\"email\":\"$EMAIL\"}" >/dev/null 2>&1 || true
req POST "$API/vehicles" "$ADMIN" "{\"requester_document\":\"$CPF\",\"plate\":\"$PLATE\",\"brand\":\"Fiat\",\"model\":\"Argo\",\"year\":2022}" >/dev/null
req POST "$API/services" "$ADMIN" "{\"code\":$SERVICE_CODE,\"name\":\"Troca de pastilhas\",\"price\":150,\"duration_min\":60}" >/dev/null
PART_ID=$(req POST "$API/parts" "$ADMIN" "{\"manufacturer_code\":\"$PART_CODE\",\"name\":\"Pastilha de freio\",\"unit\":\"par\",\"price\":90,\"stock\":10}" | jq -r .id)
ok "veículo $PLATE, serviço $SERVICE_CODE, peça $PART_CODE com estoque $(stock)"

step "cliente troca o CPF por um JWT (POST /auth → Lambda issuer → os-service /internal)"
CLIENT=$(req POST "$GATEWAY/auth" "" "{\"cpf\":\"$CPF\"}" | jq -r .access_token)
ok "token do cliente emitido"
code=$(curl -s -o /dev/null -w '%{http_code}' "$API/service-orders")
info "sem token, o gateway responde $code (authorizer)"

if [[ $SCENARIO == feliz || $SCENARIO == tudo ]]; then
  step "1. caminho feliz"
  OS1=$(open_os)
  ok "OS $OS1 aberta: a saga mandou StartDiagnosis para o execution-service"
  diagnose "$OS1"
  approve "$OS1"
  pay "$OS1" approved
  wait_for "OS" "os_status $OS1" in_execution
  wait_for "execução" "exec_status $OS1" queued_repair
  req POST "$API/executions/$OS1/repair/start" "$ADMIN" >/dev/null
  req POST "$API/executions/$OS1/repair/finish" "$ADMIN" >/dev/null
  ok "mecânico executou o reparo"
  wait_for "OS" "os_status $OS1" finished
  req POST "$API/service-orders/$OS1/deliver" "$ADMIN" >/dev/null
  wait_for "OS" "os_status $OS1" delivered
  info "estoque da peça: $(stock) (2 baixadas)"
  step "visão composta da OS (os-service + billing + execution)"
  show_details "$OS1"
  info "no New Relic: Distributed tracing, filtro os_id = $OS1"
fi

if [[ $SCENARIO == pagamento || $SCENARIO == tudo ]]; then
  step "2. pagamento recusado → compensação"
  OS2=$(open_os payment)
  info "OS $OS2 aberta com X-Simulate-Failure: payment (o billing recusa a cobrança depois da aprovação)"
  diagnose "$OS2"
  approve "$OS2"
  wait_for "OS" "os_status $OS2" cancelled
  wait_for "pagamento" "budget $OS2 | jq -r .payment.status" failed
  wait_for "execução" "exec_status $OS2" cancelled
  wait_for "orçamento" "budget $OS2 | jq -r .status" cancelled
  ok "peças devolvidas, estoque $(stock)"
  show_details "$OS2"
fi

if [[ $SCENARIO == reparo || $SCENARIO == tudo ]]; then
  step "3. reparo recusado depois do pagamento → estorno"
  OS3=$(open_os repair)
  info "OS $OS3 aberta com X-Simulate-Failure: repair"
  diagnose "$OS3"
  approve "$OS3"
  pay "$OS3" approved
  wait_for "OS" "os_status $OS3" cancelled
  wait_for "pagamento" "budget $OS3 | jq -r .payment.status" refunded
  ok "pagamento estornado, estoque $(stock)"
  show_details "$OS3"
fi

printf '\n\033[1;32m✔ demonstração concluída\033[0m\n'
