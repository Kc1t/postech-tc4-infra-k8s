# Pedaços de NRQL usados no dashboard, nos alertas e nos SLOs. Os nomes de atributo vêm do código:
# Transaction e Span do agente Go (nrgin, Consume/<tipo>, OutboxRelay/<tipo>), Log dos JSON do
# slog (o msg vira message) e NotificationSent da Lambda de notificação.
locals {
  name = "Ordem de Serviço (${var.environment})"

  runbook = { for f in [
    "servico-erros", "servico-latencia", "saga-compensacao", "saga-expirada",
    "dlq", "mensagem-malformada", "outbox-travado", "lambda-erros", "authorizer-negacoes",
  ] : f => "${var.runbook_base_url}/${f}.md" }

  # appName IN (...) dos três serviços.
  app_names = join(", ", [for a in values(var.apps) : "'${a.app_name}'"])

  # Requisições de negócio: sem as probes do Kubernetes (/health, /health/live, /health/ready) e
  # sem o Swagger. O nrgin nomeia a transação "WebTransaction/Go/<método> <rota>".
  web_filter = "transactionType = 'Web' AND name NOT LIKE '%/health%' AND name NOT LIKE '%/swagger/%'"

  # Erro de serviço = resposta 5xx. O agente marca error = true também em 4xx (exceto 404), que são
  # erro do cliente (validação, token, conflito) e não indisponibilidade.
  server_error = "http.statusCode >= 500"

  # Consumo de mensagem: transação de background Consume/<tipo> (pkg/messaging/consumer.go).
  consume_filter = "name LIKE 'OtherTransaction/Go/Consume/%'"

  # Publicação do outbox: transação OutboxRelay/<tipo> que reaceita o trace gravado no Enqueue.
  relay_filter = "name LIKE 'OtherTransaction/Go/OutboxRelay/%'"

  # Lambdas: o nrlambda grava aws.lambda.arn em toda invocação. Com NEW_RELIC_APM_LAMBDA_MODE=true
  # (infra/main.tf dos dois repos) as invocações chegam como Transaction.
  lambda_where   = { for k, fn in var.lambdas : k => "aws.lambda.arn LIKE '%:function:${fn}%'" }
  lambdas_filter = "(${join(" OR ", values(local.lambda_where))})"
  lambda_facet   = "cases(${join(", ", [for k, w in local.lambda_where : "WHERE ${w} AS '${k}'"])})"
  lambda_names   = join(", ", [for fn in values(var.lambdas) : "'${fn}'"])

  # Logs da Lambda chegam pela extension; o filtro aceita o msg tanto em message quanto em msg.
  notifier_failures = "('notification_send_failed', 'notification_dedup_failed', 'notification_render_failed')"

  # Fim da saga: um saga_completed (reparo concluído) ou um saga_compensated (qualquer compensação,
  # inclusive as expiradas, que logam saga_compensated e depois saga_expired).
  saga_end = "message IN ('saga_completed', 'saga_compensated')"

  # Motivo da compensação (campo reason do saga_compensated, montado em sagauc). O CASES usa o
  # primeiro que casar, por isso a falha simulada vem antes e os genéricos por último.
  compensation_reason = join("", [
    "cases(",
    "WHERE reason LIKE '%simulate_failure=%' AS 'Falha simulada (demo)', ",
    "WHERE reason LIKE 'orçamento recusado pelo cliente%' AS 'Cliente recusou o orçamento', ",
    "WHERE reason LIKE 'cancelada pela oficina%' AS 'Cancelada pela oficina', ",
    "WHERE reason LIKE 'prazo de aprovação%' AS 'Prazo de aprovação expirado', ",
    "WHERE reason LIKE 'prazo de pagamento%' AS 'Prazo de pagamento expirado', ",
    "WHERE reason LIKE 'estoque insuficiente%' AS 'Estoque insuficiente', ",
    "WHERE reason LIKE 'pagamento não aprovado: pagamento % pelo provedor%' AS 'Pagamento recusado pelo provedor', ",
    "WHERE reason LIKE 'pagamento não aprovado:%' AS 'Falha técnica no pagamento', ",
    "WHERE reason LIKE 'falha ao gerar o orçamento%' AS 'Falha ao gerar o orçamento', ",
    "WHERE reason LIKE '%capacidade de reparos esgotada%' AS 'Oficina sem capacidade', ",
    "WHERE reason LIKE 'execução recusada pela oficina:%' AS 'Reparo recusado pelo execution', ",
    "WHERE reason LIKE '%catálogo' OR reason LIKE 'quantidade inválida%' OR reason LIKE 'diagnóstico sem%' AS 'Diagnóstico fora do catálogo'",
    ")",
  ])

  # Compensação técnica: a saga terminou por falha do sistema ou de dados, não por decisão do
  # cliente, da oficina ou por prazo. As falhas simuladas (simulate_failure) entram aqui de
  # propósito: simulam justamente uma falha técnica.
  technical_compensation = join(" OR ", [
    "reason LIKE 'falha ao gerar o orçamento%'",
    "reason LIKE '%não existe no catálogo'",
    "reason LIKE 'quantidade inválida%'",
    "reason LIKE 'diagnóstico sem serviços%'",
    "(reason LIKE 'pagamento não aprovado:%' AND reason NOT LIKE 'pagamento não aprovado: pagamento % pelo provedor%')",
    "(reason LIKE 'execução recusada pela oficina:%' AND reason NOT LIKE '%capacidade de reparos esgotada%')",
  ])
}
