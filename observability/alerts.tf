# Uma policy com todas as condições do sistema. PER_CONDITION_AND_TARGET abre um incidente por
# condição e por faceta (no alerta de DLQ, um por fila), em vez de juntar tudo num só.
resource "newrelic_alert_policy" "this" {
  name                = local.name
  account_id          = var.new_relic_account_id
  incident_preference = "PER_CONDITION_AND_TARGET"
}

locals {
  # Cada condição: janela em segundos (avaliada inteira, uma vez), limites crítico e de aviso
  # (null = sem aviso) e fill_zero para contagens, em que a ausência de evento significa zero.
  conditions = merge(
    { for k, a in var.apps : "${k}-erros" => {
      name        = "${k}: taxa de erro acima de ${var.error_rate_threshold}% em 5 min"
      description = "Percentual de respostas 5xx nas requisições de ${k} (sem /health e Swagger). Erros 4xx são do cliente e ficam fora."
      runbook     = local.runbook["servico-erros"]
      query       = "SELECT percentage(count(*), WHERE ${local.server_error}) FROM Transaction WHERE appName = '${a.app_name}' AND ${local.web_filter}"
      window      = 300
      critical    = var.error_rate_threshold
      warning     = var.error_rate_threshold / 2
      fill_zero   = false
    } },

    { for k, a in var.apps : "${k}-latencia" => {
      name        = "${k}: latência p95 acima de ${a.latency_p95_seconds} s em 5 min"
      description = "p95 da duração das requisições de ${k} (sem /health e Swagger). Aviso na metade do limite."
      runbook     = local.runbook["servico-latencia"]
      query       = "SELECT percentile(duration, 95) FROM Transaction WHERE appName = '${a.app_name}' AND ${local.web_filter}"
      window      = 300
      critical    = a.latency_p95_seconds
      warning     = a.latency_p95_seconds / 2
      fill_zero   = false
    } },

    {
      "saga-compensacao" = {
        name        = "saga: taxa de compensação acima de ${var.saga_compensation_threshold}% em 30 min"
        description = "Sagas compensadas sobre as encerradas (saga_completed + saga_compensated) no os-service. Inclui recusa do cliente e prazo: o runbook separa negócio de falha técnica."
        runbook     = local.runbook["saga-compensacao"]
        query       = "SELECT percentage(count(*), WHERE message = 'saga_compensated') FROM Log WHERE ${local.saga_end}"
        window      = 1800
        critical    = var.saga_compensation_threshold
        warning     = var.saga_compensation_threshold / 2
        fill_zero   = false
      }

      "saga-expirada" = {
        name        = "saga: saga expirada por prazo (aviso a cada uma, crítico acima de 5 em 15 min)"
        description = "Log saga_expired do job ExpireSagas: orçamento sem resposta do cliente ou pagamento sem confirmação. Várias de uma vez indicam resposta perdida (DLQ) ou webhook parado."
        runbook     = local.runbook["saga-expirada"]
        query       = "SELECT count(*) FROM Log WHERE message = 'saga_expired'"
        window      = 900
        critical    = 5
        warning     = 0
        fill_zero   = true
      }

      # Proxy da DLQ: o Learner Lab não deixa integrar o CloudWatch, então o sinal é o próprio
      # consumidor falhando na entrega de número max_receive_count, a última antes da DLQ.
      "dlq" = {
        name        = "mensageria: mensagem falhou na última entrega antes da DLQ (receive_count >= ${var.max_receive_count})"
        description = "Log message_failed com receive_count >= maxReceiveCount: a próxima recepção move a mensagem para <fila>-dlq. Um incidente por consumidor (fila). O alarme do CloudWatch confirma a DLQ."
        runbook     = local.runbook["dlq"]
        query       = "SELECT count(*) FROM Log WHERE message = 'message_failed' AND numeric(receive_count) >= ${var.max_receive_count} FACET consumer"
        window      = 300
        critical    = 0
        warning     = null
        fill_zero   = true
      }

      "mensagem-malformada" = {
        name        = "mensageria: mensagem malformada recebida em 5 min"
        description = "Corpo fora do contrato de pkg/contracts (message_malformed nos serviços, notification_invalid_* na Lambda). A mensagem nunca é processada e acaba na DLQ."
        runbook     = local.runbook["mensagem-malformada"]
        query       = "SELECT count(*) FROM Log WHERE message IN ('message_malformed', 'notification_invalid_message', 'notification_invalid_payload') OR msg IN ('notification_invalid_message', 'notification_invalid_payload')"
        window      = 300
        critical    = 0
        warning     = null
        fill_zero   = true
      }

      "outbox-travado" = {
        name        = "mensageria: mensagem travada no outbox"
        description = "Log outbox_message_stuck: o relay já tentou publicar a mesma mensagem 10 vezes (uns 8 min) e ela não sai do serviço. A saga daquela OS fica parada até o prazo."
        runbook     = local.runbook["outbox-travado"]
        query       = "SELECT count(*) FROM Log WHERE message = 'outbox_message_stuck'"
        window      = 300
        critical    = 0
        warning     = null
        fill_zero   = true
      }

      "notifier-envio" = {
        name        = "lambda notifier: falhas de envio de e-mail acima de 4 em 5 min"
        description = "Logs notification_send_failed, notification_dedup_failed e notification_render_failed. Conta as falhas pelo log, separando envio, dedup e template; a mesma falha também marca erro na invocação (NoticeError) e entra na taxa de erro da function."
        runbook     = local.runbook["lambda-erros"]
        query       = "SELECT count(*) FROM Log WHERE message IN ${local.notifier_failures} OR msg IN ${local.notifier_failures}"
        window      = 300
        critical    = 4
        warning     = 0
        fill_zero   = true
      }

      "authorizer-negacoes" = {
        name        = "lambda authorizer: mais de ${var.authorizer_denials_threshold} requisições negadas em 5 min"
        description = "Invocações do authorizer com auth.outcome missing_token ou invalid_token. Pico indica JWT_SECRET divergente, token expirado em massa ou varredura."
        runbook     = local.runbook["authorizer-negacoes"]
        query       = "SELECT count(*) FROM Transaction WHERE ${local.lambda_where.authorizer} AND auth.outcome IN ('missing_token', 'invalid_token')"
        window      = 300
        critical    = var.authorizer_denials_threshold
        warning     = var.authorizer_denials_threshold / 2
        fill_zero   = true
      }
    },

    { for k, w in local.lambda_where : "lambda-${k}-erros" => {
      name        = "lambda ${k}: taxa de erro acima de ${var.error_rate_threshold}% em 5 min"
      description = "Invocações da function ${var.lambdas[k]} com erro (NoticeError ou erro devolvido ao runtime)."
      runbook     = local.runbook["lambda-erros"]
      query       = "SELECT percentage(count(*), WHERE error IS true) FROM Transaction WHERE ${w}"
      window      = 300
      critical    = var.error_rate_threshold
      warning     = var.error_rate_threshold / 2
      fill_zero   = false
    } },
  )
}

resource "newrelic_nrql_alert_condition" "this" {
  for_each = local.conditions

  account_id  = var.new_relic_account_id
  policy_id   = newrelic_alert_policy.this.id
  type        = "static"
  name        = each.value.name
  description = each.value.description
  runbook_url = each.value.runbook
  enabled     = true

  nrql {
    query = each.value.query
  }

  # Cadence: a janela fecha pelo relógio (fim da janela + 2 min para o dado chegar). O tráfego da
  # demo é baixo e irregular: com event flow a janela com erro só fecharia na próxima requisição, e
  # com event timer a janela de 30 min fecharia no primeiro lote, ignorando o resto.
  aggregation_method = "cadence"
  aggregation_delay  = 120
  aggregation_window = each.value.window

  fill_option = each.value.fill_zero ? "static" : "none"
  fill_value  = each.value.fill_zero ? 0 : null

  # Sem dado por 30 min (tráfego parou ou a falha cessou), o incidente aberto fecha sozinho.
  expiration_duration            = 1800
  open_violation_on_expiration   = false
  close_violations_on_expiration = true
  violation_time_limit_seconds   = 86400

  critical {
    operator              = "above"
    threshold             = each.value.critical
    threshold_duration    = each.value.window
    threshold_occurrences = "all"
  }

  dynamic "warning" {
    for_each = each.value.warning == null ? [] : [each.value.warning]
    content {
      operator              = "above"
      threshold             = warning.value
      threshold_duration    = each.value.window
      threshold_occurrences = "all"
    }
  }
}
