#!/usr/bin/env bash
# Gateway local: nginx na frente dos três serviços com as mesmas rotas do API Gateway, e o
# POST /auth ligado à Lambda auth-issuer do LocalStack por uma function URL. Serve para rodar o
# ../scripts/demo.sh e as collections Postman sem AWS.
#
# Não emula o Lambda authorizer: aqui quem barra a requisição sem token são os próprios
# serviços, que na AWS validam o JWT de novo depois do authorizer.
#
#   make up && make lambdas && ./gateway.sh up      # gateway em http://localhost:8090
#   GATEWAY=http://localhost:8090 ADMIN_PASSWORD=admin123 ../scripts/demo.sh
#   ./gateway.sh down
set -euo pipefail
cd "$(dirname "$0")"

PORT=${GATEWAY_PORT:-8090}
LS=e2e-localstack
NAME=e2e-gateway
CONF="$PWD/.gateway.conf"

case ${1:-up} in
  up)
    url=$(docker exec "$LS" awslocal lambda get-function-url-config --function-name auth-issuer \
      --query FunctionUrl --output text 2>/dev/null) ||
      url=$(docker exec "$LS" awslocal lambda create-function-url-config --function-name auth-issuer \
        --auth-type NONE --query FunctionUrl --output text)
    host=$(sed -E 's#^https?://([^:/]+).*#\1#' <<<"$url")

    sed "s/ISSUER_HOST/$host/" >"$CONF" <<'EOF'
server {
  listen 80;
  proxy_set_header X-Forwarded-For $remote_addr;
  proxy_read_timeout 15s;

  # POST /auth → Lambda auth-issuer (function URL do LocalStack, roteada pelo Host).
  location = /auth {
    proxy_set_header Host ISSUER_HOST;
    proxy_pass http://localstack:4566/;
  }

  # billing-service
  location /api/v1/budgets/              { proxy_pass http://billing-service:8082; }
  location /api/v1/payments/             { proxy_pass http://billing-service:8082; }
  location = /api/v1/webhooks/mercadopago { proxy_pass http://billing-service:8082; }
  location /fake-checkout/               { proxy_pass http://billing-service:8082; }

  # execution-service
  location /api/v1/executions/           { proxy_pass http://execution-service:8080; }

  # Como na AWS, /internal não tem rota pública.
  location /internal/                    { return 404; }

  # os-service (cadastros, OS, login da equipe, health)
  location /                             { proxy_pass http://os-service:8080; }
}
EOF
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker run -d --name "$NAME" --network tc4-e2e_default -p "$PORT:80" \
      -v "$CONF:/etc/nginx/conf.d/default.conf:ro" nginx:1.27-alpine >/dev/null
    for _ in $(seq 1 20); do curl -sf "http://localhost:$PORT/health" >/dev/null && break; sleep 0.5; done
    curl -sf "http://localhost:$PORT/health" >/dev/null || { docker logs "$NAME"; exit 1; }
    echo "gateway local em http://localhost:$PORT (issuer: $url)"
    ;;
  down)
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    rm -f "$CONF"
    ;;
  *)
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
