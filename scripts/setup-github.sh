#!/usr/bin/env bash
# Configura os secrets e as variáveis dos seis repositórios da fase 4 com o gh CLI.
#
# Nenhum valor passa pela linha de comando nem aparece na tela: os segredos são digitados sem
# eco (read -s), lidos do ~/.aws/credentials ou gerados aqui, e chegam ao gh pela entrada padrão.
# Rode no seu terminal, não numa sessão gravada.
#
#   scripts/setup-github.sh status        o que já está configurado em cada repo (só nomes)
#   scripts/setup-github.sh vars          variáveis com os valores padrão (região, CORS, gateway fake...)
#   scripts/setup-github.sh app           JWT_SECRET e INTERNAL_API_TOKEN gerados (os mesmos em todos) e ADMIN_PASSWORD
#   scripts/setup-github.sh aws           credenciais do Learner Lab (rodar a cada sessão do lab)
#   scripts/setup-github.sh state         cria o bucket do state do Terraform e grava TF_STATE_BUCKET
#   scripts/setup-github.sh newrelic      license key e account id do New Relic
#   scripts/setup-github.sh smtp          usuário, senha e remetente do SMTP (Brevo)
#   scripts/setup-github.sh mercadopago   access token e segredo do webhook de teste; liga PAYMENT_GATEWAY=mercadopago
#   scripts/setup-github.sh enable|disable   liga ou desliga os deploys (AWS_DEPLOY_ENABLED)
#
# Ordem na primeira vez: vars, app, newrelic, smtp, aws, state, enable.
set -euo pipefail

OWNER=${GITHUB_OWNER:-Kc1t}
AWS_PROFILE=${AWS_PROFILE:-default}
SECRETS_DIR=${SECRETS_DIR:-$HOME/.postech-tc4}

OS=postech-tc4-os-service
BILLING=postech-tc4-billing-service
EXECUTION=postech-tc4-execution-service
AUTH=postech-tc4-lambda-auth
NOTIFIER=postech-tc4-notification-lambda
INFRA=postech-tc4-infra-k8s
ALL=("$OS" "$BILLING" "$EXECUTION" "$AUTH" "$NOTIFIER" "$INFRA")
SERVICES=("$OS" "$BILLING" "$EXECUTION")

die() { echo "erro: $*" >&2; exit 1; }
info() { printf '\033[1;34m▶\033[0m %s\n' "$*"; }

command -v gh >/dev/null || die "instale o gh CLI"
gh auth status >/dev/null 2>&1 || die "rode gh auth login antes"

# put_secret NOME VALOR REPO... (o valor vai pela entrada padrão, nunca pelo argv)
put_secret() {
  local name=$1 value=$2
  shift 2
  [ -n "$value" ] || die "$name vazio"
  for repo in "$@"; do
    printf '%s' "$value" | gh secret set "$name" --repo "$OWNER/$repo" >/dev/null
    echo "  secret $name → $repo"
  done
}

put_var() {
  local name=$1 value=$2
  shift 2
  for repo in "$@"; do
    gh variable set "$name" --repo "$OWNER/$repo" --body "$value" >/dev/null
    echo "  var $name=$value → $repo"
  done
}

has_secret() { gh secret list --repo "$OWNER/$2" --json name -q '.[].name' | grep -qx "$1"; }

ask_secret() { # pergunta sem eco
  local prompt=$1 value
  read -r -s -p "$prompt: " value
  echo >&2
  printf '%s' "$value"
}

ask() {
  local prompt=$1 default=${2:-} value
  read -r -p "$prompt${default:+ [$default]}: " value
  printf '%s' "${value:-$default}"
}

random() { openssl rand -base64 48 | tr -d '\n/+=' | cut -c1-48; }

cmd_status() {
  for repo in "${ALL[@]}"; do
    echo "== $repo"
    echo "  secrets: $(gh secret list --repo "$OWNER/$repo" --json name -q '[.[].name] | join(" ")')"
    echo "  vars:    $(gh variable list --repo "$OWNER/$repo" --json name,value -q '[.[] | "\(.name)=\(.value)"] | join(" ")')"
  done
}

cmd_vars() {
  info "variáveis padrão"
  put_var AWS_REGION "$(ask 'Região AWS' us-east-1)" "${ALL[@]}"
  put_var CORS_ALLOWED_ORIGINS "$(ask 'Origens CORS permitidas (separadas por vírgula)' http://localhost:3000)" "${SERVICES[@]}"
  put_var FAULT_INJECTION_ENABLED "$(ask 'Liberar o header X-Simulate-Failure para a demo (true/false)' true)" "${SERVICES[@]}"
  put_var PAYMENT_GATEWAY "$(ask 'Gateway de pagamento (fake/mercadopago)' fake)" "$BILLING"
  put_var EKS_CLUSTER_NAME "$(ask 'Nome do cluster EKS' postech-tc4-prod)" "${SERVICES[@]}"
  gh variable list --repo "$OWNER/$OS" --json name -q '.[].name' | grep -qx AWS_DEPLOY_ENABLED \
    || put_var AWS_DEPLOY_ENABLED false "${ALL[@]}"
}

# JWT_SECRET e INTERNAL_API_TOKEN precisam ser iguais em todos os repos que os usam. Só gera
# quando ainda não existem (ou com ROTATE=true): trocar invalida os tokens já emitidos.
cmd_app() {
  info "segredos da aplicação"
  if [ "${ROTATE:-false}" = true ] || ! has_secret JWT_SECRET "$OS"; then
    put_secret JWT_SECRET "$(random)" "${SERVICES[@]}" "$AUTH"
  else
    echo "  JWT_SECRET já existe (ROTATE=true para gerar outro)"
  fi
  if [ "${ROTATE:-false}" = true ] || ! has_secret INTERNAL_API_TOKEN "$OS"; then
    put_secret INTERNAL_API_TOKEN "$(random)" "$OS" "$AUTH"
  else
    echo "  INTERNAL_API_TOKEN já existe"
  fi

  local admin
  admin=$(ask_secret "Senha do admin@workshop.com (Enter para gerar)")
  if [ -z "$admin" ]; then
    admin=$(random | cut -c1-20)
    mkdir -p "$SECRETS_DIR" && chmod 700 "$SECRETS_DIR"
    (umask 077 && printf '%s\n' "$admin" > "$SECRETS_DIR/admin-password")
    echo "  senha gerada e salva em $SECRETS_DIR/admin-password (permissão 600)"
  fi
  put_secret ADMIN_PASSWORD "$admin" "$OS"
}

cmd_aws() {
  info "credenciais do Learner Lab do perfil '$AWS_PROFILE' (cole em ~/.aws/credentials o que aparece em AWS Details)"
  local id secret token
  id=$(aws configure get aws_access_key_id --profile "$AWS_PROFILE") || die "perfil $AWS_PROFILE sem aws_access_key_id"
  secret=$(aws configure get aws_secret_access_key --profile "$AWS_PROFILE")
  token=$(aws configure get aws_session_token --profile "$AWS_PROFILE") || die "perfil sem aws_session_token: as credenciais do lab são temporárias"
  aws sts get-caller-identity --profile "$AWS_PROFILE" --query Arn --output text >/dev/null \
    || die "credenciais recusadas pela AWS (sessão do lab expirada?)"
  put_secret AWS_ACCESS_KEY_ID "$id" "${ALL[@]}"
  put_secret AWS_SECRET_ACCESS_KEY "$secret" "${ALL[@]}"
  put_secret AWS_SESSION_TOKEN "$token" "${ALL[@]}"
}

cmd_state() {
  local region account bucket
  region=$(ask 'Região do bucket' us-east-1)
  account=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text)
  bucket="postech-tc4-tfstate-$account"
  info "bucket do state: $bucket"
  if ! aws s3api head-bucket --bucket "$bucket" --profile "$AWS_PROFILE" 2>/dev/null; then
    if [ "$region" = us-east-1 ]; then
      aws s3api create-bucket --bucket "$bucket" --region "$region" --profile "$AWS_PROFILE" >/dev/null
    else
      aws s3api create-bucket --bucket "$bucket" --region "$region" --profile "$AWS_PROFILE" \
        --create-bucket-configuration LocationConstraint="$region" >/dev/null
    fi
    aws s3api put-bucket-versioning --bucket "$bucket" --versioning-configuration Status=Enabled --profile "$AWS_PROFILE"
    aws s3api put-public-access-block --bucket "$bucket" --profile "$AWS_PROFILE" \
      --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
    aws s3api put-bucket-encryption --bucket "$bucket" --profile "$AWS_PROFILE" \
      --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
    echo "  bucket criado (versionado, privado, criptografado)"
  else
    echo "  bucket já existe"
  fi
  put_secret TF_STATE_BUCKET "$bucket" "${ALL[@]}"
}

cmd_newrelic() {
  info "New Relic (license key de ingestão, não a user key)"
  put_secret NEW_RELIC_LICENSE_KEY "$(ask_secret 'License key')" "${ALL[@]}"
  put_var NEW_RELIC_ACCOUNT_ID "$(ask 'Account ID')" "$AUTH" "$NOTIFIER"
}

cmd_smtp() {
  info "SMTP da Lambda de notificação (Brevo: SMTP & API → SMTP)"
  put_secret SMTP_USERNAME "$(ask_secret 'Usuário SMTP')" "$NOTIFIER"
  put_secret SMTP_PASSWORD "$(ask_secret 'Senha SMTP (chave SMTP do Brevo)')" "$NOTIFIER"
  put_var SMTP_FROM "$(ask 'Remetente verificado no Brevo')" "$NOTIFIER"
}

cmd_mercadopago() {
  info "Mercado Pago (credenciais de TESTE da aplicação)"
  local token
  token=$(ask_secret 'Access token de teste (TEST-...)')
  case $token in TEST-*|APP_USR-*) ;; *) die "não parece um access token do Mercado Pago" ;; esac
  put_secret MP_ACCESS_TOKEN "$token" "$BILLING"
  put_secret MP_WEBHOOK_SECRET "$(ask_secret 'Assinatura secreta do webhook (Suas integrações → Webhooks)')" "$BILLING"
  put_var PAYMENT_GATEWAY mercadopago "$BILLING"
}

cmd_enable() { info "deploys ligados"; put_var AWS_DEPLOY_ENABLED true "${ALL[@]}"; }
cmd_disable() { info "deploys desligados"; put_var AWS_DEPLOY_ENABLED false "${ALL[@]}"; }

case ${1:-} in
  status | vars | app | aws | state | newrelic | smtp | mercadopago | enable | disable) "cmd_$1" ;;
  *) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
