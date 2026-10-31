# new_relic_account_id e alert_email vêm de fora: no CI, de vars.NEW_RELIC_ACCOUNT_ID e
# vars.NEW_RELIC_ALERT_EMAIL (TF_VAR_*); localmente, -var ou TF_VAR_*. Assim o e-mail não fica no repo.
environment   = "prod"
k8s_namespace = "postech"
cluster_name  = "postech-tc4-prod"

apps = {
  "os-service"        = { app_name = "os-service-postech", latency_p95_seconds = 1 }
  "billing-service"   = { app_name = "billing-service-postech", latency_p95_seconds = 2 }
  "execution-service" = { app_name = "execution-service-postech", latency_p95_seconds = 1 }
}

lambdas = {
  issuer     = "postech-tc4-prod-auth-issuer"
  authorizer = "postech-tc4-prod-auth-authorizer"
  notifier   = "postech-tc4-prod-notifier"
}

max_receive_count = 5
