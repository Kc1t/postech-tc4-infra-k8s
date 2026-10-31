#!/usr/bin/env bash
# Teste ponta a ponta da saga com os três microsserviços reais + as duas Lambdas no LocalStack.
#
#   1. caminho feliz: OS aberta → diagnóstico → orçamento → aprovação do cliente (JWT do issuer)
#      → pagamento → reparo → entrega, com e-mails no Mailpit e API composition no /details
#   2. pagamento recusado → compensação (orçamento cancelado, peças devolvidas, execução cancelada)
#   3. reparo recusado depois do pagamento → estorno → OS cancelada
#   4. cliente recusa o orçamento → compensação
#
#   make up && make lambdas && make e2e
set -euo pipefail

OS_API=${OS_API:-http://localhost:8080/api/v1}
BILLING_API=${BILLING_API:-http://localhost:8082/api/v1}
EXEC_API=${EXEC_API:-http://localhost:8083/api/v1}
MAILPIT=${MAILPIT:-http://localhost:8026}
LS=e2e-localstack
CPF=52998224725
EMAIL="ana.e2e@example.com"

step() { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
ok() { printf '  \033[32m✔\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✘ %s\033[0m\n' "$*"; exit 1; }

# req MÉTODO URL TOKEN [corpo] [headers extras...] → corpo da resposta; falha em 4xx/5xx.
req() {
  local method=$1 url=$2 token=$3 body=${4:-}
  shift 4 || shift $#
  local args=(-sS -X "$method" -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -w '\n%{http_code}')
  [ -n "$body" ] && args+=(-d "$body")
  for h in "$@"; do args+=(-H "$h"); done
  local out code
  out=$(curl "${args[@]}" "$url")
  code=${out##*$'\n'}
  out=${out%$'\n'*}
  if [ "$code" -ge 400 ]; then echo "$method $url → $code $out" >&2; return 1; fi
  echo "$out"
}

os_status() { req GET "$OS_API/service-orders/$1" "$ADMIN" | jq -r .status; }
wait_os() { # os status [tentativas]
  local got=""
  for _ in $(seq 1 "${3:-60}"); do
    got=$(os_status "$1")
    [ "$got" = "$2" ] && { ok "OS em $2"; return; }
    sleep 0.5
  done
  fail "OS esperava $2, está $got"
}
wait_exec() {
  local got=""
  for _ in $(seq 1 60); do
    got=$(req GET "$EXEC_API/executions/$1" "$ADMIN" 2>/dev/null | jq -r .status || true)
    [ "$got" = "$2" ] && { ok "execução em $2"; return; }
    sleep 0.5
  done
  fail "execução esperava $2, está $got"
}
budget_of() { req GET "$BILLING_API/budgets/os/$1" "$ADMIN"; }
wait_budget() { # os campo valor
  local got=""
  for _ in $(seq 1 60); do
    got=$(budget_of "$1" 2>/dev/null | jq -r "$2" || true)
    [ "$got" = "$3" ] && { ok "orçamento: $2 = $3"; return; }
    sleep 0.5
  done
  fail "orçamento: $2 esperava $3, está $got"
}
stock() { req GET "$OS_API/parts/$PART_ID" "$ADMIN" | jq -r .stock; }

open_os() { # [falha simulada]
  local extra=()
  [ -n "${1:-}" ] && extra=("X-Simulate-Failure: $1")
  req POST "$OS_API/service-orders" "$ADMIN" \
    "{\"requester_document\":\"$CPF\",\"vehicle_plate\":\"$PLATE\",\"notes\":\"barulho na suspensão\"}" ${extra[@]+"${extra[@]}"} | jq -r .id
}

diagnose() { # os
  wait_exec "$1" queued_diagnosis
  req POST "$EXEC_API/executions/$1/diagnosis/start" "$ADMIN" >/dev/null
  req POST "$EXEC_API/executions/$1/diagnosis/complete" "$ADMIN" \
    "{\"services\":[{\"code\":$SERVICE_CODE}],\"parts\":[{\"manufacturer_code\":\"$PART_CODE\",\"quantity\":2}],\"notes\":\"pastilhas gastas\"}" >/dev/null
  ok "mecânico concluiu o diagnóstico"
}

approve() { # os
  wait_os "$1" awaiting_approval
  local budget
  budget=$(budget_of "$1" | jq -r .id)
  req POST "$BILLING_API/budgets/$budget/approve" "$CLIENT" >/dev/null
  ok "cliente aprovou o orçamento $budget (JWT do issuer)"
}

pay() { # os status
  wait_budget "$1" '.payment.status' pending
  local payment
  payment=$(budget_of "$1" | jq -r .payment.id)
  req POST "$BILLING_API/payments/$payment/simulate" "$ADMIN" "{\"status\":\"$2\"}" >/dev/null
  ok "pagamento $payment: $2"
}

mails_for() { curl -s "$MAILPIT/api/v1/search?query=to:$EMAIL" | jq -r '.messages_count // 0'; }

# ─────────────────────────────────────────────────────────────────────────────
step "preparação: login da equipe, cliente, veículo, serviço e peça"
ADMIN=$(curl -sf "$OS_API/auth/login" -H 'Content-Type: application/json' \
  -d '{"email":"admin@workshop.com","password":"admin123"}' | jq -r .access_token)
[ -n "$ADMIN" ] && [ "$ADMIN" != null ] || fail "login da equipe"
SUF=$((RANDOM % 9000 + 1000))
PLATE="TCE$SUF"
SERVICE_CODE=$((SUF * 10 + RANDOM % 10))
PART_CODE="PAS-E2E-$SUF"
req POST "$OS_API/requesters" "$ADMIN" "{\"name\":\"Ana E2E\",\"document\":\"$CPF\",\"email\":\"$EMAIL\"}" >/dev/null 2>&1 || true
req POST "$OS_API/vehicles" "$ADMIN" "{\"requester_document\":\"$CPF\",\"plate\":\"$PLATE\",\"brand\":\"Fiat\",\"model\":\"Argo\",\"year\":2022}" >/dev/null
req POST "$OS_API/services" "$ADMIN" "{\"code\":$SERVICE_CODE,\"name\":\"Troca de pastilhas\",\"price\":150,\"duration_min\":60}" >/dev/null
PART_ID=$(req POST "$OS_API/parts" "$ADMIN" "{\"manufacturer_code\":\"$PART_CODE\",\"name\":\"Pastilha de freio\",\"unit\":\"par\",\"price\":90,\"stock\":10}" | jq -r .id)
ok "veículo $PLATE, serviço $SERVICE_CODE, peça $PART_CODE (estoque $(stock))"

step "cliente troca o CPF por um JWT na Lambda auth-issuer"
docker exec "$LS" awslocal lambda invoke --function-name auth-issuer \
  --payload "{\"body\":\"{\\\"cpf\\\":\\\"$CPF\\\"}\",\"requestContext\":{\"requestId\":\"e2e-$SUF\"}}" /tmp/issuer.json >/dev/null
CLIENT=$(docker exec "$LS" cat /tmp/issuer.json | jq -r '.body | fromjson | .access_token')
[ -n "$CLIENT" ] && [ "$CLIENT" != null ] || fail "issuer não devolveu token: $(docker exec "$LS" cat /tmp/issuer.json)"
ok "token do cliente emitido pela Lambda"
MAILS_BEFORE=$(mails_for)

# ─────────────────────────────────────────────────────────────────────────────
step "1. caminho feliz"
OS1=$(open_os)
ok "OS $OS1 aberta"
diagnose "$OS1"
approve "$OS1"
pay "$OS1" approved
wait_os "$OS1" in_execution
wait_exec "$OS1" queued_repair
req POST "$EXEC_API/executions/$OS1/repair/start" "$ADMIN" >/dev/null
req POST "$EXEC_API/executions/$OS1/repair/finish" "$ADMIN" >/dev/null
wait_os "$OS1" finished
req POST "$OS_API/service-orders/$OS1/deliver" "$ADMIN" >/dev/null
wait_os "$OS1" delivered
[ "$(stock)" = 8 ] && ok "estoque baixou 2 peças (8)" || fail "estoque esperado 8, está $(stock)"

DETAILS=$(req GET "$OS_API/service-orders/$OS1/details" "$ADMIN")
echo "$DETAILS" | jq -e '.partial == false and .budget.status == "approved" and .budget.payment.status == "approved" and .execution.status == "finished"' >/dev/null \
  && ok "API composition: orçamento aprovado, pagamento aprovado e execução finalizada no /details" \
  || fail "details inesperado: $(echo "$DETAILS" | jq -c '{partial, unavailable, b: .budget.status, e: .execution.status}')"
echo "$DETAILS" | jq -r '.history[] | "    \(.from // "-") → \(.to) (\(.actor))"'

step "notificação: e-mails da Lambda notifier no Mailpit"
# Um e-mail por status do caminho feliz, menos awaiting_budget (interno): 7.
for _ in $(seq 1 90); do [ $(( $(mails_for) - MAILS_BEFORE )) -ge 7 ] && break; sleep 1; done
SENT=$(( $(mails_for) - MAILS_BEFORE ))
[ "$SENT" -ge 7 ] && ok "$SENT e-mails para $EMAIL" || fail "esperava 7 e-mails, chegaram $SENT"
curl -s "$MAILPIT/api/v1/search?query=to:$EMAIL&limit=7" | jq -r '.messages[].Subject' | sed 's/^/    /'

# ─────────────────────────────────────────────────────────────────────────────
step "2. pagamento recusado → compensação"
OS2=$(open_os)
diagnose "$OS2"
approve "$OS2"
[ "$(stock)" = 6 ] && ok "peças reservadas (estoque 6)" || fail "estoque esperado 6, está $(stock)"
pay "$OS2" rejected
wait_os "$OS2" cancelled
wait_exec "$OS2" cancelled
wait_budget "$OS2" .status cancelled
[ "$(stock)" = 8 ] && ok "peças devolvidas ao estoque (8)" || fail "estoque esperado 8, está $(stock)"

# ─────────────────────────────────────────────────────────────────────────────
step "3. reparo recusado depois do pagamento → estorno"
OS3=$(open_os repair)
diagnose "$OS3"
approve "$OS3"
pay "$OS3" approved
wait_os "$OS3" cancelled
wait_budget "$OS3" '.payment.status' refunded
wait_exec "$OS3" rejected  # quem recusou foi o próprio execution-service: estado terminal
[ "$(stock)" = 8 ] && ok "peças devolvidas ao estoque (8)" || fail "estoque esperado 8, está $(stock)"
req GET "$OS_API/service-orders/$OS3/details" "$ADMIN" | jq -r '"    saga: \(.saga.state) · motivo: \(.saga.failure_reason)"'

# ─────────────────────────────────────────────────────────────────────────────
step "4. cliente recusa o orçamento"
OS4=$(open_os)
diagnose "$OS4"
wait_os "$OS4" awaiting_approval
BUDGET4=$(budget_of "$OS4" | jq -r .id)
req POST "$BILLING_API/budgets/$BUDGET4/reject" "$CLIENT" '{"reason":"vou fazer em outro lugar"}' >/dev/null
wait_os "$OS4" cancelled
wait_exec "$OS4" cancelled
[ "$(stock)" = 8 ] && ok "peças devolvidas ao estoque (8)" || fail "estoque esperado 8, está $(stock)"

# ─────────────────────────────────────────────────────────────────────────────
step "filas: nada parado nas DLQs"
for q in os-saga-replies billing-commands execution-commands notification-os-events; do
  n=$(docker exec "$LS" awslocal sqs get-queue-attributes --queue-url "http://localhost:4566/000000000000/${q}-dlq" \
    --attribute-names ApproximateNumberOfMessages --query Attributes.ApproximateNumberOfMessages --output text)
  [ "$n" = 0 ] && ok "${q}-dlq vazia" || fail "${q}-dlq com $n mensagens"
done

printf '\n\033[1;32m✔ e2e completo: caminho feliz + 3 compensações, com notificação e API composition\033[0m\n'
