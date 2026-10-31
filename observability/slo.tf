# Service levels. Cada SLI fica preso à entidade APM do serviço, então o GUID é buscado pelo nome.
# ignore_not_found: antes do primeiro deploy o serviço ainda não reportou ao New Relic e a busca
# volta vazia; o SLO dele fica para o apply seguinte e o resto (dashboard, alertas) sai mesmo assim.
data "newrelic_entity" "app" {
  for_each = var.apps

  account_id       = var.new_relic_account_id
  name             = each.value.app_name
  domain           = "APM"
  type             = "APPLICATION"
  ignore_not_found = true
}

locals {
  app_guid = { for k, e in data.newrelic_entity.app : k => e.guid if try(length(e.guid) > 0, false) }

  # Janela de 7 dias: cobre uma semana de demo e reage rápido a uma regressão. Em 28 dias uma
  # tarde de falhas ficaria diluída.
  slo_window_days = 7
}

# Disponibilidade de cada serviço: das requisições de negócio (sem /health e Swagger), quantas não
# terminaram em 5xx. 4xx é erro do cliente e conta como resposta boa. 99,5% em 7 dias deixa
# 0,5% das requisições da semana falharem antes de o orçamento de erro acabar.
resource "newrelic_service_level" "disponibilidade" {
  for_each = local.app_guid

  guid        = each.value
  name        = "${each.key}: disponibilidade (sem 5xx)"
  description = "Requisições sem resposta 5xx sobre todas as requisições de negócio de ${var.apps[each.key].app_name}."

  events {
    account_id = var.new_relic_account_id

    valid_events {
      from  = "Transaction"
      where = "appName = '${var.apps[each.key].app_name}' AND ${local.web_filter}"
    }

    bad_events {
      from  = "Transaction"
      where = "appName = '${var.apps[each.key].app_name}' AND ${local.web_filter} AND ${local.server_error}"
    }
  }

  objective {
    target = 99.5
    time_window {
      rolling {
        count = local.slo_window_days
        unit  = "DAY"
      }
    }
  }
}

# Latência do os-service, a porta de entrada da equipe e do cliente: 95% das requisições abaixo de
# 500 ms. É o mesmo T do Apdex do dashboard; o alerta de p95 (1 s) é o limite de emergência.
resource "newrelic_service_level" "latencia_os" {
  count = contains(keys(local.app_guid), "os-service") ? 1 : 0

  guid        = local.app_guid["os-service"]
  name        = "os-service: latência abaixo de 500 ms"
  description = "Requisições de negócio do os-service respondidas em menos de 500 ms."

  events {
    account_id = var.new_relic_account_id

    valid_events {
      from  = "Transaction"
      where = "appName = '${var.apps["os-service"].app_name}' AND ${local.web_filter}"
    }

    good_events {
      from  = "Transaction"
      where = "appName = '${var.apps["os-service"].app_name}' AND ${local.web_filter} AND duration < 0.5"
    }
  }

  objective {
    target = 95
    time_window {
      rolling {
        count = local.slo_window_days
        unit  = "DAY"
      }
    }
  }
}

# SLO de negócio da saga: das OS que chegaram ao fim (concluídas ou compensadas), quantas não
# terminaram por falha técnica. Recusa do cliente, cancelamento pela oficina, prazo vencido, falta
# de estoque, pagamento recusado pelo provedor e oficina sem capacidade são desfechos legítimos e
# contam como bons; falha ao gerar orçamento, falha técnica no pagamento, diagnóstico fora do
# catálogo, reparo recusado por estado inválido e as falhas simuladas (simulate_failure) são ruins.
# Fica preso ao os-service, que orquestra a saga e emite os logs.
resource "newrelic_service_level" "saga" {
  count = contains(keys(local.app_guid), "os-service") ? 1 : 0

  guid        = local.app_guid["os-service"]
  name        = "saga: OS encerradas sem compensação técnica"
  description = "Sagas encerradas (saga_completed + saga_compensated) que não foram compensadas por falha do sistema ou de dados."

  events {
    account_id = var.new_relic_account_id

    valid_events {
      from  = "Log"
      where = local.saga_end
    }

    bad_events {
      from  = "Log"
      where = "message = 'saga_compensated' AND (${local.technical_compensation})"
    }
  }

  objective {
    target = 95
    time_window {
      rolling {
        count = local.slo_window_days
        unit  = "DAY"
      }
    }
  }
}
