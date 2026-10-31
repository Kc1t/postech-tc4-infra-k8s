# Workload "Ordem de Serviço": tudo que participa da saga numa visão só (saúde, alertas, service
# map). As entidades entram por consulta, então a réplica nova, a Lambda republicada ou o cluster
# recriado entram sozinhos, sem GUID fixo no código.
resource "newrelic_workload" "ordem_de_servico" {
  name        = local.name
  account_id  = var.new_relic_account_id
  description = "Saga da OS: os-service (orquestrador), billing-service, execution-service, Lambdas de autenticação e notificação e o cluster EKS."

  scope_account_ids = [var.new_relic_account_id]

  # Serviços do cluster (agente Go, NEW_RELIC_APP_NAME do ConfigMap).
  entity_search_query {
    query = "domain = 'APM' AND type = 'APPLICATION' AND name IN (${local.app_names})"
  }

  # Lambdas. Sem filtro de tipo: com o APM Lambda mode a function vira entidade APM e, sem ele,
  # AWSLAMBDAFUNCTION; o nome é o mesmo nos dois casos.
  entity_search_query {
    query = "name IN (${local.lambda_names})"
  }

  # Cluster, reportado pelo nri-bundle com global.cluster = nome do EKS.
  entity_search_query {
    query = "type = 'KUBERNETESCLUSTER' AND name = '${var.cluster_name}'"
  }

  status_config_automatic {
    enabled = true
  }
}
