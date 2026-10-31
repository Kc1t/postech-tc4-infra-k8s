# API Gateway HTTP único na frente dos três microsserviços e da Lambda de autenticação.
#
# O gateway se liga sozinho ao que já existe, sem copiar ARN ou DNS para variáveis:
#   - Lambdas: procuradas pelo nome que o postech-tc4-lambda-auth cria;
#   - serviços: NLB que o Kubernetes cria para o Service <serviço>-public, achado pela tag
#     kubernetes.io/service-name = <namespace>/<serviço>-public.
# Antes do deploy dos serviços, as rotas daquele serviço simplesmente não são criadas; um novo
# apply depois do deploy liga tudo (ordem em README.md, seção Deploy).

locals {
  issuer_name     = var.lambda_issuer_function_name != "" ? var.lambda_issuer_function_name : "${var.project_name}-${var.environment}-auth-issuer"
  authorizer_name = var.lambda_authorizer_function_name != "" ? var.lambda_authorizer_function_name : "${var.project_name}-${var.environment}-auth-authorizer"

  issuer_enabled     = contains(data.aws_lambda_functions.all.function_names, local.issuer_name)
  authorizer_enabled = contains(data.aws_lambda_functions.all.function_names, local.authorizer_name)

  backends = {
    os        = "os-service-public"
    billing   = "billing-service-public"
    execution = "execution-service-public"
  }

  # Rotas por serviço. auth = true passa pelo Lambda authorizer (JWT do cliente ou da equipe);
  # os serviços validam o JWT de novo e checam papel e posse (defesa em profundidade).
  # /internal/* não tem rota: só existe dentro do cluster e pelo NLB com X-Internal-Token.
  routes = {
    # os-service
    "GET /health"                         = { backend = "os", auth = false }
    "POST /api/v1/auth/{proxy+}"          = { backend = "os", auth = false } # login/refresh da equipe
    "ANY /api/v1/service-orders"          = { backend = "os", auth = true }
    "ANY /api/v1/service-orders/{proxy+}" = { backend = "os", auth = true }
    "ANY /api/v1/requesters"              = { backend = "os", auth = true }
    "ANY /api/v1/requesters/{proxy+}"     = { backend = "os", auth = true }
    "ANY /api/v1/vehicles"                = { backend = "os", auth = true }
    "ANY /api/v1/vehicles/{proxy+}"       = { backend = "os", auth = true }
    "ANY /api/v1/services"                = { backend = "os", auth = true }
    "ANY /api/v1/services/{proxy+}"       = { backend = "os", auth = true }
    "ANY /api/v1/parts"                   = { backend = "os", auth = true }
    "ANY /api/v1/parts/{proxy+}"          = { backend = "os", auth = true }
    # billing-service
    "ANY /api/v1/budgets/{proxy+}"  = { backend = "billing", auth = true }
    "ANY /api/v1/payments/{proxy+}" = { backend = "billing", auth = true }
    # Página do checkout do gateway fake (demonstração sem Mercado Pago).
    "GET /fake-checkout/{proxy+}" = { backend = "billing", auth = false }
    # Público: o Mercado Pago não manda JWT; a autenticidade vem da assinatura x-signature.
    "POST /api/v1/webhooks/mercadopago" = { backend = "billing", auth = false }
    # execution-service
    "ANY /api/v1/executions/{proxy+}" = { backend = "execution", auth = true }
  }

  live_backends = { for k, v in data.aws_lbs.backend : k => tolist(v.arns)[0] if length(v.arns) > 0 }

  # Rota protegida sem authorizer seria rota aberta: só cria quando o authorizer existe.
  live_routes = {
    for key, r in local.routes : key => r
    if contains(keys(local.live_backends), r.backend) && (!r.auth || local.authorizer_enabled)
  }
}

data "aws_lambda_functions" "all" {}

data "aws_lambda_function" "issuer" {
  count         = local.issuer_enabled ? 1 : 0
  function_name = local.issuer_name
}

data "aws_lambda_function" "authorizer" {
  count         = local.authorizer_enabled ? 1 : 0
  function_name = local.authorizer_name
}

data "aws_lbs" "backend" {
  for_each = local.backends

  tags = {
    "kubernetes.io/service-name" = "${var.k8s_namespace}/${each.value}"
  }
}

data "aws_lb" "backend" {
  for_each = local.live_backends
  arn      = each.value
}

resource "aws_apigatewayv2_api" "this" {
  name          = "${local.name}-gateway"
  protocol_type = "HTTP"

  tags = local.tags
}

# tfsec:ignore:aws-cloudwatch-log-group-customer-key O Learner Lab nao permite criar CMK; o log fica com a chave gerenciada da AWS.
resource "aws_cloudwatch_log_group" "gateway" {
  name              = "/aws/apigateway/${local.name}"
  retention_in_days = 14

  tags = local.tags
}

resource "aws_apigatewayv2_stage" "this" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.gateway.arn
    format = jsonencode({
      correlationId  = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      responseLength = "$context.responseLength"
      latency        = "$context.responseLatency"
      integration    = "$context.integration.latency"
      authorizer     = "$context.authorizer.error"
    })
  }

  default_route_settings {
    throttling_burst_limit = 200
    throttling_rate_limit  = 100
  }

  # A emissão de token é a rota mais sensível a força bruta (enumeração de CPF): limite menor.
  dynamic "route_settings" {
    for_each = local.issuer_enabled ? ["POST /auth"] : []
    content {
      route_key              = route_settings.value
      throttling_burst_limit = 20
      throttling_rate_limit  = 10
    }
  }

  tags = local.tags

  depends_on = [aws_apigatewayv2_route.auth]
}

resource "aws_apigatewayv2_authorizer" "jwt" {
  count = local.authorizer_enabled ? 1 : 0

  api_id                            = aws_apigatewayv2_api.this.id
  authorizer_type                   = "REQUEST"
  authorizer_uri                    = data.aws_lambda_function.authorizer[0].invoke_arn
  authorizer_payload_format_version = "2.0"
  enable_simple_responses           = true
  authorizer_result_ttl_in_seconds  = 0
  identity_sources                  = ["$request.header.Authorization"]
  name                              = "${local.name}-jwt-authorizer"
}

resource "aws_lambda_permission" "authorizer" {
  count = local.authorizer_enabled ? 1 : 0

  statement_id  = "AllowInvocationFromApiGatewayAuthorizer"
  action        = "lambda:InvokeFunction"
  function_name = local.authorizer_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/authorizers/${aws_apigatewayv2_authorizer.jwt[0].id}"
}

resource "aws_apigatewayv2_integration" "issuer" {
  count = local.issuer_enabled ? 1 : 0

  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = data.aws_lambda_function.issuer[0].invoke_arn
  payload_format_version = "2.0"
}

resource "aws_lambda_permission" "issuer" {
  count = local.issuer_enabled ? 1 : 0

  statement_id  = "AllowInvocationFromApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = local.issuer_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}

resource "aws_apigatewayv2_route" "auth" {
  count = local.issuer_enabled ? 1 : 0

  api_id    = aws_apigatewayv2_api.this.id
  route_key = "POST /auth"
  target    = "integrations/${aws_apigatewayv2_integration.issuer[0].id}"
}

# O caminho original vai inteiro para o serviço: com "/{proxy}" na URI, a rota
# ANY /api/v1/budgets/{proxy+} entregaria só o trecho depois do prefixo.
resource "aws_apigatewayv2_integration" "backend" {
  for_each = local.live_backends

  api_id               = aws_apigatewayv2_api.this.id
  integration_type     = "HTTP_PROXY"
  integration_method   = "ANY"
  integration_uri      = "http://${data.aws_lb.backend[each.key].dns_name}"
  timeout_milliseconds = 10000

  request_parameters = {
    "overwrite:path" = "$request.path"
  }
}

resource "aws_apigatewayv2_route" "backend" {
  for_each = local.live_routes

  api_id             = aws_apigatewayv2_api.this.id
  route_key          = each.key
  target             = "integrations/${aws_apigatewayv2_integration.backend[each.value.backend].id}"
  authorization_type = each.value.auth ? "CUSTOM" : "NONE"
  authorizer_id      = each.value.auth ? aws_apigatewayv2_authorizer.jwt[0].id : null
}
