locals {
  acc = var.new_relic_account_id

  # Requisições de negócio dos três serviços.
  apps_web = "appName IN (${local.app_names}) AND ${local.web_filter}"

  # Entidades que podem aparecer num trace: os serviços e as Lambdas (no APM Lambda mode o appName
  # é o nome da function).
  trace_apps = "appName IN (${local.app_names}, ${local.lambda_names})"

  malformed = "message IN ('message_malformed', 'notification_invalid_message', 'notification_invalid_payload') OR msg IN ('notification_invalid_message', 'notification_invalid_payload')"
}

resource "newrelic_one_dashboard" "ordem_de_servico" {
  account_id  = var.new_relic_account_id
  name        = local.name
  description = "Saga da ordem de serviço, serviços, mensageria com trace distribuído e Lambdas. Gerado por postech-tc4-infra-k8s/observability."
  permissions = "public_read_only"

  # ---------------------------------------------------------------------------------------------
  # Página 1: a saga como processo de negócio (logs do orquestrador no os-service).
  # ---------------------------------------------------------------------------------------------
  page {
    name = "Saga"

    widget_markdown {
      title  = "Como ler esta página"
      row    = 1
      column = 1
      width  = 12
      height = 2
      text   = "**Saga da OS** pelos logs do orquestrador (os-service, `sagauc`): `saga_started`, `saga_step` (com `saga_state` e `os_status`), `saga_completed`, `saga_compensated` (com `reason`) e `saga_expired`. Toda saga expirada também conta como compensada. Runbooks: [compensação](${local.runbook["saga-compensacao"]}) · [expiração](${local.runbook["saga-expirada"]})."
    }

    widget_billboard {
      title  = "Sagas no período"
      row    = 3
      column = 1
      width  = 8
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT filter(count(*), WHERE message = 'saga_started') AS 'Iniciadas', filter(count(*), WHERE message = 'saga_completed') AS 'Concluídas', filter(count(*), WHERE message = 'saga_compensated') AS 'Compensadas', filter(count(*), WHERE message = 'saga_expired') AS 'Expiradas' FROM Log WHERE message IN ('saga_started', 'saga_completed', 'saga_compensated', 'saga_expired')"
      }
    }

    widget_billboard {
      title    = "Taxa de compensação (compensadas / encerradas)"
      row      = 3
      column   = 9
      width    = 4
      height   = 3
      warning  = tostring(var.saga_compensation_threshold / 2)
      critical = tostring(var.saga_compensation_threshold)
      nrql_query {
        account_id = local.acc
        query      = "SELECT percentage(count(*), WHERE message = 'saga_compensated') AS '% compensadas' FROM Log WHERE ${local.saga_end}"
      }
    }

    widget_funnel {
      title  = "Funil da saga (sagas distintas que chegaram a cada etapa)"
      row    = 6
      column = 1
      width  = 6
      height = 4
      nrql_query {
        account_id = local.acc
        query      = "SELECT funnel(saga_id, WHERE message = 'saga_started' AS 'Aberta', WHERE message = 'saga_step' AND saga_state = 'awaiting_budget' AS 'Diagnosticada', WHERE message = 'saga_step' AND saga_state = 'awaiting_approval' AS 'Orçamento criado', WHERE message = 'saga_step' AND saga_state = 'awaiting_payment' AS 'Aprovada', WHERE message = 'saga_step' AND saga_state = 'executing' AS 'Paga, em reparo', WHERE message = 'saga_completed' AS 'Concluída') FROM Log WHERE message IN ('saga_started', 'saga_step', 'saga_completed')"
      }
    }

    widget_line {
      title  = "Concluídas × compensadas × expiradas"
      row    = 6
      column = 7
      width  = 6
      height = 4
      nrql_query {
        account_id = local.acc
        query      = "SELECT filter(count(*), WHERE message = 'saga_completed') AS 'Concluídas', filter(count(*), WHERE message = 'saga_compensated') AS 'Compensadas', filter(count(*), WHERE message = 'saga_expired') AS 'Expiradas' FROM Log WHERE message IN ('saga_completed', 'saga_compensated', 'saga_expired') TIMESERIES AUTO"
      }
    }

    widget_bar {
      title  = "Motivos de compensação"
      row    = 10
      column = 1
      width  = 6
      height = 4
      nrql_query {
        account_id = local.acc
        query      = "SELECT count(*) FROM Log WHERE message = 'saga_compensated' FACET ${local.compensation_reason}"
      }
    }

    widget_bar {
      title  = "Passos aplicados por estado da saga (saga_step)"
      row    = 10
      column = 7
      width  = 6
      height = 4
      nrql_query {
        account_id = local.acc
        query      = "SELECT count(*) FROM Log WHERE message = 'saga_step' FACET saga_state"
      }
    }

    # Duração de cada saga = do saga_started ao saga_completed com o mesmo saga_id (agregação
    # aninhada); só entram as que abriram e concluíram dentro da janela de 7 dias.
    widget_billboard {
      title  = "Tempo até concluir: abertura → reparo concluído (7 dias)"
      row    = 14
      column = 1
      width  = 4
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT average(minutos) AS 'Média (min)', max(minutos) AS 'Máximo (min)', count(*) AS 'Sagas medidas' FROM (SELECT (max(timestamp) - min(timestamp)) / 60000 AS minutos, filter(count(*), WHERE message = 'saga_started') AS abertas, filter(count(*), WHERE message = 'saga_completed') AS concluidas FROM Log WHERE message IN ('saga_started', 'saga_completed') FACET saga_id LIMIT MAX) WHERE abertas > 0 AND concluidas > 0 SINCE 7 days ago"
      }
    }

    widget_table {
      title  = "Últimas compensações"
      row    = 14
      column = 5
      width  = 8
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT timestamp, service_order_code, previous_status, reason, refund_payment, cancel_budget, released_parts, actor FROM Log WHERE message = 'saga_compensated' LIMIT 20"
      }
    }

    widget_bar {
      title  = "Respostas da saga fora do caminho feliz (ignoradas, duplicadas, com falha, confirmações)"
      row    = 17
      column = 1
      width  = 6
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT count(*) FROM Log WHERE message IN ('saga_reply_ignored', 'saga_reply_duplicate', 'saga_reply_unknown_saga', 'saga_reply_unknown_type', 'saga_reply_failed', 'saga_late_payment_refund', 'saga_compensation_confirmed', 'saga_refund_confirmed') FACET message"
      }
    }

    widget_table {
      title  = "Linha do tempo das sagas (logs)"
      row    = 17
      column = 7
      width  = 6
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT timestamp, saga_id, message, saga_state, os_status, message_type, trace.id FROM Log WHERE message LIKE 'saga_%' LIMIT 50"
      }
    }
  }

  # ---------------------------------------------------------------------------------------------
  # Página 2: os três serviços (APM) e o que roda por baixo deles no cluster.
  # ---------------------------------------------------------------------------------------------
  page {
    name = "Serviços"

    widget_markdown {
      title  = "Como ler esta página"
      row    = 1
      column = 1
      width  = 12
      height = 2
      text   = "APM dos três serviços (agente Go com `nrgin`). Erro = resposta **5xx**; `/health` e Swagger ficam de fora. `Consume/*` é a transação de cada mensagem consumida. Runbooks: [erros](${local.runbook["servico-erros"]}) · [latência](${local.runbook["servico-latencia"]})."
    }

    widget_billboard {
      title    = "Apdex (T = 0,5 s)"
      row      = 3
      column   = 1
      width    = 4
      height   = 3
      warning  = "0.85"
      critical = "0.7"
      nrql_query {
        account_id = local.acc
        query      = "SELECT apdex(duration, t: 0.5) FROM Transaction WHERE ${local.apps_web} FACET appName"
      }
    }

    widget_billboard {
      title    = "Taxa de erro 5xx (%)"
      row      = 3
      column   = 5
      width    = 4
      height   = 3
      warning  = tostring(var.error_rate_threshold / 2)
      critical = tostring(var.error_rate_threshold)
      nrql_query {
        account_id = local.acc
        query      = "SELECT percentage(count(*), WHERE ${local.server_error}) AS 'Erro 5xx' FROM Transaction WHERE ${local.apps_web} FACET appName"
      }
    }

    widget_billboard {
      title  = "Latência p95 (ms)"
      row    = 3
      column = 9
      width  = 4
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT percentile(duration, 95) * 1000 AS 'p95 (ms)' FROM Transaction WHERE ${local.apps_web} FACET appName"
      }
    }

    widget_line {
      title  = "Throughput (requisições/min)"
      row    = 6
      column = 1
      width  = 6
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT rate(count(*), 1 minute) FROM Transaction WHERE ${local.apps_web} FACET appName TIMESERIES AUTO"
      }
    }

    widget_line {
      title  = "Latência p95 (ms)"
      row    = 6
      column = 7
      width  = 6
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT percentile(duration, 95) * 1000 FROM Transaction WHERE ${local.apps_web} FACET appName TIMESERIES AUTO"
      }
    }

    widget_line {
      title  = "Taxa de erro 5xx (%)"
      row    = 9
      column = 1
      width  = 6
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT percentage(count(*), WHERE ${local.server_error}) FROM Transaction WHERE ${local.apps_web} FACET appName TIMESERIES AUTO"
      }
    }

    widget_table {
      title  = "Rotas: volume, p95 e erro 5xx"
      row    = 9
      column = 7
      width  = 6
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT count(*) AS 'Requisições', percentile(duration, 95) * 1000 AS 'p95 (ms)', percentage(count(*), WHERE ${local.server_error}) AS 'Erro 5xx (%)' FROM Transaction WHERE ${local.apps_web} FACET appName, name LIMIT 20"
      }
    }

    widget_line {
      title  = "Mensagens consumidas por tipo (Consume/*)"
      row    = 12
      column = 1
      width  = 6
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT count(*) FROM Transaction WHERE appName IN (${local.app_names}) AND ${local.consume_filter} FACET message_type TIMESERIES AUTO"
      }
    }

    widget_table {
      title  = "Consumo por tipo: volume, falhas e p95"
      row    = 12
      column = 7
      width  = 6
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT count(*) AS 'Mensagens', filter(count(*), WHERE error IS true) AS 'Falhas', percentile(duration, 95) * 1000 AS 'p95 (ms)' FROM Transaction WHERE appName IN (${local.app_names}) AND ${local.consume_filter} FACET appName, message_type LIMIT 30"
      }
    }

    widget_line {
      title  = "Falhas de consumo por consumidor (message_failed, message_malformed)"
      row    = 15
      column = 1
      width  = 6
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT count(*) FROM Log WHERE message IN ('message_failed', 'message_malformed') FACET consumer, message TIMESERIES AUTO"
      }
    }

    widget_table {
      title  = "Últimos erros registrados pelo agente"
      row    = 15
      column = 7
      width  = 6
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT timestamp, appName, transactionName, http.statusCode, error.class, error.message FROM TransactionError WHERE appName IN (${local.app_names}) LIMIT 20"
      }
    }

    widget_line {
      title  = "Pods prontos por deployment (HPA)"
      row    = 18
      column = 1
      width  = 4
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT latest(podsReady) FROM K8sDeploymentSample WHERE clusterName = '${var.cluster_name}' AND namespaceName = '${var.k8s_namespace}' FACET deploymentName TIMESERIES AUTO"
      }
    }

    widget_line {
      title  = "CPU em uso (% do limite)"
      row    = 18
      column = 5
      width  = 4
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT average(cpuUsedCores) / average(cpuLimitCores) * 100 FROM K8sContainerSample WHERE clusterName = '${var.cluster_name}' AND namespaceName = '${var.k8s_namespace}' FACET containerName TIMESERIES AUTO"
      }
    }

    widget_line {
      title  = "Memória em uso (MiB)"
      row    = 18
      column = 9
      width  = 4
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT average(memoryWorkingSetBytes) / 1024 / 1024 FROM K8sContainerSample WHERE clusterName = '${var.cluster_name}' AND namespaceName = '${var.k8s_namespace}' FACET containerName TIMESERIES AUTO"
      }
    }
  }

  # ---------------------------------------------------------------------------------------------
  # Página 3: mensageria (outbox, SNS/SQS, consumo, DLQ) e o trace que atravessa os serviços.
  # ---------------------------------------------------------------------------------------------
  page {
    name = "Mensageria e trace"

    widget_markdown {
      title  = "Como ler esta página"
      row    = 1
      column = 1
      width  = 12
      height = 2
      text   = "Cada mensagem sai do outbox numa transação `OutboxRelay/*` que reaceita o trace da requisição, vai por SNS/SQS com `traceparent` nos atributos e chega à transação `Consume/*` do consumidor, no mesmo trace. Sem a integração AWS (Learner Lab), a DLQ aparece aqui pelo `message_failed` na entrega de número ${var.max_receive_count}. Para abrir um trace, copie o `trace.id` e cole em *Distributed tracing*. Runbooks: [DLQ](${local.runbook["dlq"]}) · [malformada](${local.runbook["mensagem-malformada"]}) · [outbox travado](${local.runbook["outbox-travado"]})."
    }

    widget_billboard {
      title    = "Última entrega antes da DLQ (receive_count >= ${var.max_receive_count})"
      row      = 3
      column   = 1
      width    = 4
      height   = 3
      critical = "1"
      nrql_query {
        account_id = local.acc
        query      = "SELECT count(*) AS 'Mensagens' FROM Log WHERE message = 'message_failed' AND numeric(receive_count) >= ${var.max_receive_count} FACET consumer"
      }
    }

    widget_billboard {
      title    = "Mensagens malformadas"
      row      = 3
      column   = 5
      width    = 4
      height   = 3
      critical = "1"
      nrql_query {
        account_id = local.acc
        query      = "SELECT count(*) AS 'Recepções' FROM Log WHERE ${local.malformed}"
      }
    }

    widget_billboard {
      title    = "Falhas do relay do outbox (publicação no SNS/SQS)"
      row      = 3
      column   = 9
      width    = 4
      height   = 3
      critical = "1"
      nrql_query {
        account_id = local.acc
        query      = "SELECT filter(count(*), WHERE message = 'outbox_publish_failed') AS 'Falhas', filter(count(*), WHERE message = 'outbox_message_stuck') AS 'Travadas' FROM Log WHERE message IN ('outbox_publish_failed', 'outbox_message_stuck') FACET container_name"
      }
    }

    widget_bar {
      title  = "message_failed por fila (consumidor) e receive_count"
      row    = 6
      column = 1
      width  = 6
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT count(*) FROM Log WHERE message = 'message_failed' FACET consumer, receive_count"
      }
    }

    widget_line {
      title  = "message_failed por fila (consumidor)"
      row    = 6
      column = 7
      width  = 6
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT count(*) FROM Log WHERE message = 'message_failed' FACET consumer TIMESERIES AUTO"
      }
    }

    widget_line {
      title  = "Mensagens publicadas por destino (métrica MessageBroker do agente)"
      row    = 9
      column = 1
      width  = 6
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT count(newrelic.timeslice.value) FROM Metric WHERE appName IN (${local.app_names}) AND metricTimesliceName LIKE 'MessageBroker/%/Produce/Named/%' FACET metricTimesliceName TIMESERIES AUTO"
      }
    }

    widget_line {
      title  = "Tempo na fila: publicação → consumo (p95, ms)"
      row    = 9
      column = 7
      width  = 6
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT percentile(parent.transportDuration, 95) * 1000 FROM Transaction WHERE appName IN (${local.app_names}) AND ${local.consume_filter} FACET messaging.consumer TIMESERIES AUTO"
      }
    }

    widget_line {
      title  = "Atraso do outbox: gravação → publicação (p95, ms)"
      row    = 12
      column = 1
      width  = 6
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT percentile(parent.transportDuration, 95) * 1000 FROM Transaction WHERE appName IN (${local.app_names}) AND ${local.relay_filter} FACET appName TIMESERIES AUTO"
      }
    }

    widget_billboard {
      title  = "Traces distribuídos que atravessam serviços"
      row    = 12
      column = 7
      width  = 6
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT count(*) AS 'Traces com 2+ serviços', average(servicos) AS 'Serviços por trace (média)', max(servicos) AS 'Máximo' FROM (SELECT uniqueCount(appName) AS servicos FROM Span WHERE ${local.trace_apps} FACET trace.id LIMIT MAX) WHERE servicos > 1"
      }
    }

    # saga_id vai no span raiz de Consume/* e OutboxRelay/* (txn.AddAttribute), então os spans de
    # uma saga se agrupam por ele mesmo quando a saga cruza vários traces (a aprovação do cliente
    # é uma requisição nova).
    widget_table {
      title  = "Spans por saga_id: por onde a saga passou"
      row    = 15
      column = 1
      width  = 12
      height = 4
      nrql_query {
        account_id = local.acc
        query      = "SELECT uniqueCount(appName) AS 'Serviços', uniques(appName) AS 'Quais', uniqueCount(trace.id) AS 'Traces', count(*) AS 'Transações', latest(trace.id) AS 'Último trace.id' FROM Span WHERE saga_id IS NOT NULL FACET saga_id LIMIT 50"
      }
    }

    widget_table {
      title  = "Traces com mais serviços"
      row    = 19
      column = 1
      width  = 12
      height = 4
      nrql_query {
        account_id = local.acc
        query      = "SELECT uniqueCount(appName) AS 'Serviços', uniques(appName) AS 'Quais', count(*) AS 'Spans', uniques(saga_id) AS 'Sagas', max(duration.ms) AS 'Maior span (ms)' FROM Span WHERE ${local.trace_apps} FACET trace.id LIMIT 20"
      }
    }
  }

  # ---------------------------------------------------------------------------------------------
  # Página 4: as três Lambdas (extension do New Relic com APM Lambda mode).
  # ---------------------------------------------------------------------------------------------
  page {
    name = "Lambdas"

    widget_markdown {
      title  = "Como ler esta página"
      row    = 1
      column = 1
      width  = 12
      height = 2
      text   = "**issuer** (CPF → JWT), **authorizer** do API Gateway e **notifier** (e-mail a cada mudança de status). Cada invocação é uma `Transaction` com `aws.lambda.arn`; a primeira de cada container traz `aws.lambda.coldStart`. E-mails enviados vêm do evento `NotificationSent`. Runbooks: [erros](${local.runbook["lambda-erros"]}) · [negações](${local.runbook["authorizer-negacoes"]})."
    }

    widget_billboard {
      title  = "Invocações"
      row    = 3
      column = 1
      width  = 3
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT count(*) FROM Transaction WHERE ${local.lambdas_filter} FACET ${local.lambda_facet}"
      }
    }

    widget_billboard {
      title    = "Taxa de erro (%)"
      row      = 3
      column   = 4
      width    = 3
      height   = 3
      warning  = tostring(var.error_rate_threshold / 2)
      critical = tostring(var.error_rate_threshold)
      nrql_query {
        account_id = local.acc
        query      = "SELECT percentage(count(*), WHERE error IS true) FROM Transaction WHERE ${local.lambdas_filter} FACET ${local.lambda_facet}"
      }
    }

    widget_billboard {
      title  = "Duração p95 (ms)"
      row    = 3
      column = 7
      width  = 3
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT percentile(duration, 95) * 1000 FROM Transaction WHERE ${local.lambdas_filter} FACET ${local.lambda_facet}"
      }
    }

    widget_billboard {
      title  = "Cold starts"
      row    = 3
      column = 10
      width  = 3
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT filter(count(*), WHERE aws.lambda.coldStart IS true) FROM Transaction WHERE ${local.lambdas_filter} FACET ${local.lambda_facet}"
      }
    }

    widget_line {
      title  = "Invocações por função"
      row    = 6
      column = 1
      width  = 6
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT count(*) FROM Transaction WHERE ${local.lambdas_filter} FACET ${local.lambda_facet} TIMESERIES AUTO"
      }
    }

    widget_line {
      title  = "Duração p95 por função (ms)"
      row    = 6
      column = 7
      width  = 6
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT percentile(duration, 95) * 1000 FROM Transaction WHERE ${local.lambdas_filter} FACET ${local.lambda_facet} TIMESERIES AUTO"
      }
    }

    widget_line {
      title  = "Erros por função"
      row    = 9
      column = 1
      width  = 6
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT filter(count(*), WHERE error IS true) FROM Transaction WHERE ${local.lambdas_filter} FACET ${local.lambda_facet} TIMESERIES AUTO"
      }
    }

    widget_table {
      title  = "Cold start × container quente"
      row    = 9
      column = 7
      width  = 6
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT filter(count(*), WHERE aws.lambda.coldStart IS true) AS 'Cold starts', filter(average(duration), WHERE aws.lambda.coldStart IS true) * 1000 AS 'Duração cold (ms)', filter(average(duration), WHERE aws.lambda.coldStart IS NULL) * 1000 AS 'Duração quente (ms)' FROM Transaction WHERE ${local.lambdas_filter} FACET ${local.lambda_facet}"
      }
    }

    widget_bar {
      title  = "Authorizer: resultado (auth.outcome)"
      row    = 12
      column = 1
      width  = 4
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT count(*) FROM Transaction WHERE ${local.lambda_where.authorizer} FACET auth.outcome"
      }
    }

    widget_bar {
      title  = "Issuer: resultado (auth.outcome)"
      row    = 12
      column = 5
      width  = 4
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT count(*) FROM Transaction WHERE ${local.lambda_where.issuer} FACET auth.outcome"
      }
    }

    widget_billboard {
      title  = "E-mails enviados (NotificationSent)"
      row    = 12
      column = 9
      width  = 4
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT count(*) AS 'E-mails' FROM NotificationSent"
      }
    }

    widget_line {
      title  = "E-mails enviados por status da OS"
      row    = 15
      column = 1
      width  = 6
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT count(*) FROM NotificationSent FACET status TIMESERIES AUTO"
      }
    }

    widget_bar {
      title  = "Notificações por resultado (logs notification_*)"
      row    = 15
      column = 7
      width  = 6
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT count(*) FROM Log WHERE message LIKE 'notification_%' OR msg LIKE 'notification_%' FACET message"
      }
    }

    widget_table {
      title  = "Últimos erros das Lambdas"
      row    = 18
      column = 1
      width  = 12
      height = 3
      nrql_query {
        account_id = local.acc
        query      = "SELECT timestamp, aws.lambda.arn, error.class, error.message, aws.requestId FROM TransactionError WHERE ${local.lambdas_filter} LIMIT 20"
      }
    }
  }
}
