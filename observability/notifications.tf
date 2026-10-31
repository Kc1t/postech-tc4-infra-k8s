# E-mail é opcional: com alert_email vazio os incidentes ficam só no New Relic (Alerts → Issues).
locals {
  email_enabled = trimspace(var.alert_email) != ""
}

resource "newrelic_notification_destination" "email" {
  count = local.email_enabled ? 1 : 0

  account_id = var.new_relic_account_id
  name       = "${local.name}: e-mail da equipe"
  type       = "EMAIL"

  property {
    key   = "email"
    value = join(",", [for e in split(",", var.alert_email) : trimspace(e)])
  }
}

resource "newrelic_notification_channel" "email" {
  count = local.email_enabled ? 1 : 0

  account_id     = var.new_relic_account_id
  name           = "${local.name}: e-mail"
  type           = "EMAIL"
  product        = "IINT"
  destination_id = newrelic_notification_destination.email[0].id

  property {
    key   = "subject"
    value = "[{{priority}}] {{issueTitle}}"
  }
}

# Todo issue da policy vai para o e-mail, na abertura e no fechamento.
resource "newrelic_workflow" "email" {
  count = local.email_enabled ? 1 : 0

  account_id            = var.new_relic_account_id
  name                  = "${local.name}: e-mail"
  muting_rules_handling = "NOTIFY_ALL_ISSUES"

  issues_filter {
    name = "Policy ${local.name}"
    type = "FILTER"

    predicate {
      attribute = "labels.policyIds"
      operator  = "EXACTLY_MATCHES"
      values    = [newrelic_alert_policy.this.id]
    }
  }

  destination {
    channel_id            = newrelic_notification_channel.email[0].id
    notification_triggers = ["ACTIVATED", "CLOSED"]
  }
}
