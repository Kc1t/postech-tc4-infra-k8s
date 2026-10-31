output "dashboard_url" {
  value = newrelic_one_dashboard.ordem_de_servico.permalink
}

output "workload_url" {
  value = newrelic_workload.ordem_de_servico.permalink
}

output "alert_policy_id" {
  value = newrelic_alert_policy.this.id
}

output "alert_conditions" {
  value = sort([for c in newrelic_nrql_alert_condition.this : c.name])
}

output "service_levels" {
  description = "SLOs criados; um serviço que ainda não reportou ao New Relic fica de fora até o próximo apply"
  value = concat(
    [for s in newrelic_service_level.disponibilidade : s.name],
    [for s in newrelic_service_level.latencia_os : s.name],
    [for s in newrelic_service_level.saga : s.name],
  )
}

output "apps_sem_slo" {
  description = "Serviços sem entidade APM no New Relic (não reportaram ainda): rode o apply de novo depois do deploy"
  value       = sort([for k in keys(var.apps) : k if !contains(keys(local.app_guid), k)])
}

output "email_alerts" {
  value = local.email_enabled ? "alertas por e-mail ligados" : "sem alert_email: incidentes só no New Relic"
}
