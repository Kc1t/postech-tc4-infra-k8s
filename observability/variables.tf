variable "new_relic_account_id" {
  type        = number
  description = "Conta do New Relic que recebe a telemetria (a mesma do NEW_RELIC_ACCOUNT_ID das Lambdas)"
}

variable "new_relic_region" {
  type    = string
  default = "US"

  validation {
    condition     = contains(["US", "EU"], var.new_relic_region)
    error_message = "new_relic_region deve ser US ou EU."
  }
}

variable "alert_email" {
  type        = string
  description = "E-mail (ou lista separada por vírgula) que recebe os alertas; vazio não cria destino nem workflow"

  validation {
    condition = var.alert_email == "" || alltrue([
      for e in split(",", var.alert_email) : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", trimspace(e)))
    ])
    error_message = "alert_email deve ser vazio ou uma lista de e-mails separados por vírgula."
  }
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "k8s_namespace" {
  type        = string
  default     = "postech"
  description = "Namespace dos microsserviços no cluster"
}

variable "cluster_name" {
  type        = string
  default     = "postech-tc4-prod"
  description = "Nome do cluster no New Relic (global.cluster do nri-bundle = output cluster_name da infra)"
}

# Chave = nome curto do serviço, usado nos títulos. app_name = NEW_RELIC_APP_NAME do ConfigMap
# (<serviço>-<namespace>). latency_p95_seconds é o limite crítico do alerta de latência; o aviso
# fica na metade. O billing tem limite maior porque chama o Mercado Pago (MP_TIMEOUT 5s).
variable "apps" {
  type = map(object({
    app_name            = string
    latency_p95_seconds = number
  }))
  default = {
    "os-service"        = { app_name = "os-service-postech", latency_p95_seconds = 1 }
    "billing-service"   = { app_name = "billing-service-postech", latency_p95_seconds = 2 }
    "execution-service" = { app_name = "execution-service-postech", latency_p95_seconds = 1 }
  }
}

# Chave = nome curto usado nos títulos; valor = nome da function na AWS.
variable "lambdas" {
  type = object({
    issuer     = string
    authorizer = string
    notifier   = string
  })
  default = {
    issuer     = "postech-tc4-prod-auth-issuer"
    authorizer = "postech-tc4-prod-auth-authorizer"
    notifier   = "postech-tc4-prod-notifier"
  }
}

variable "max_receive_count" {
  type        = number
  default     = 5
  description = "maxReceiveCount da redrive policy (messaging.tf): a falha nessa entrega é a última antes da DLQ"
}

variable "error_rate_threshold" {
  type        = number
  default     = 5
  description = "Percentual de erro em 5 minutos que abre incidente crítico (serviços e Lambdas)"
}

variable "saga_compensation_threshold" {
  type        = number
  default     = 30
  description = "Percentual de sagas compensadas (sobre as encerradas) em 30 minutos que abre incidente crítico"
}

variable "authorizer_denials_threshold" {
  type        = number
  default     = 50
  description = "Requisições negadas pelo authorizer em 5 minutos que abrem incidente crítico"
}

variable "runbook_base_url" {
  type    = string
  default = "https://github.com/Kc1t/postech-tc4-infra-k8s/blob/main/docs/runbooks"
}
