#!/usr/bin/env bash
# Publica as Lambdas reais no LocalStack do e2e:
#   auth-issuer  CPF → JWT, consultando o os-service pela rota interna (como na AWS)
#   notifier     consome notification-os-events (SNS os-events → SQS) e manda e-mail ao Mailpit
# As functions rodam em containers provided.al2023 na rede do compose.
set -euo pipefail
cd "$(dirname "$0")"

ROOT=../..
LS=e2e-localstack
ACC=000000000000
REGION=us-east-1
ROLE="arn:aws:iam::${ACC}:role/lambda-e2e"
JWT_SECRET=${JWT_SECRET:-e2e-jwt-secret-troque}
INTERNAL_API_TOKEN=${INTERNAL_API_TOKEN:-e2e-internal-token}
aws() { docker exec "$LS" awslocal "$@"; }

build() { # repo cmd zip
  (cd "$ROOT/$1" && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" \
    -tags lambda.norpc -o "bin/$2/bootstrap" "./cmd/$2" && (cd "bin/$2" && zip -q -o "../../$3" bootstrap))
  docker cp "$ROOT/$1/$3" "$LS:/tmp/$3" >/dev/null
}

deploy() { # nome zip env-json memoria timeout
  aws lambda delete-function --function-name "$1" >/dev/null 2>&1 || true
  aws lambda create-function --function-name "$1" --runtime provided.al2023 --architectures arm64 \
    --handler bootstrap --role "$ROLE" --zip-file "fileb:///tmp/$2" \
    --memory-size "$4" --timeout "$5" --environment "$3" >/dev/null
  aws lambda wait function-active-v2 --function-name "$1"
  echo "function: $1"
}

echo "▶ build (linux/arm64)"
build postech-tc4-lambda-auth issuer issuer.zip
build postech-tc4-notification-lambda notifier notifier.zip

echo "▶ deploy"
deploy auth-issuer issuer.zip "{\"Variables\":{
  \"OS_SERVICE_URL\":\"http://os-service:8080\",
  \"INTERNAL_API_TOKEN\":\"${INTERNAL_API_TOKEN}\",
  \"JWT_SECRET\":\"${JWT_SECRET}\",
  \"LOG_LEVEL\":\"debug\"}}" 256 10

deploy notifier notifier.zip "{\"Variables\":{
  \"SMTP_HOST\":\"mailpit\",
  \"SMTP_PORT\":\"1025\",
  \"SMTP_FROM\":\"noreply@reservoirdevs.online\",
  \"DEDUP_TABLE\":\"notification-dedup\",
  \"PORTAL_URL\":\"http://localhost:3000\",
  \"AWS_ENDPOINT_URL\":\"http://localstack:4566\",
  \"LOG_LEVEL\":\"debug\"}}" 128 30

# Mesma ligação do Terraform: lote 1, ReportBatchItemFailures (só as que falharam voltam à fila).
aws lambda list-event-source-mappings --function-name notifier --query 'EventSourceMappings[].UUID' --output text \
  | tr '\t' '\n' | sed '/^$/d' | while read -r id; do aws lambda delete-event-source-mapping --uuid "$id" >/dev/null; done
aws lambda create-event-source-mapping --function-name notifier \
  --event-source-arn "arn:aws:sqs:${REGION}:${ACC}:notification-os-events" \
  --batch-size 1 --function-response-types ReportBatchItemFailures >/dev/null
echo "event source: notification-os-events → notifier"
echo "✔ lambdas no LocalStack"
