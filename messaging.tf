# Mensageria da saga: um tópico SNS por publicador e uma fila SQS (com DLQ) por consumidor.
# É a mesma topologia que o local/localstack/init-aws.sh cria no LocalStack (ADR-0013).
#
#   os-events         ──▶ notification-os-events  (Lambda de notificação)
#   billing-events    ──▶ os-saga-replies         (orquestrador da saga)
#   execution-events  ──▶ os-saga-replies
#   (comandos do orquestrador vão direto para billing-commands e execution-commands)
#
# Os nomes não têm prefixo de ambiente porque só produção roda no cluster (o ambiente de
# homologação é o e2e local); os manifests dos serviços montam as URLs a partir deles.

locals {
  topics = toset(["os-events", "billing-events", "execution-events"])

  queues = {
    "os-saga-replies"        = { visibility = 30 }
    "billing-commands"       = { visibility = 30 }
    "execution-commands"     = { visibility = 30 }
    "notification-os-events" = { visibility = var.notification_visibility_timeout }
  }

  subscriptions = {
    "billing-events-to-os-saga-replies"   = { topic = "billing-events", queue = "os-saga-replies" }
    "execution-events-to-os-saga-replies" = { topic = "execution-events", queue = "os-saga-replies" }
    "os-events-to-notification-os-events" = { topic = "os-events", queue = "notification-os-events" }
  }

  # Tópicos que publicam em cada fila (para a policy da fila).
  queue_sources = {
    for q in keys(local.queues) : q => [
      for s in values(local.subscriptions) : aws_sns_topic.this[s.topic].arn if s.queue == q
    ]
  }
}

# tfsec:ignore:aws-sns-enable-topic-encryption Learner Lab sem CMK; a chave gerenciada exigiria kms:GenerateDataKey na policy das filas assinantes.
resource "aws_sns_topic" "this" {
  for_each = local.topics
  name     = each.key

  tags = merge(local.tags, { Component = "messaging" })
}

resource "aws_sqs_queue" "dlq" {
  for_each = local.queues

  name                      = "${each.key}-dlq"
  message_retention_seconds = 1209600 # 14 dias para investigar e fazer o redrive
  sqs_managed_sse_enabled   = true

  tags = merge(local.tags, { Component = "messaging", Role = "dlq" })
}

resource "aws_sqs_queue" "this" {
  for_each = local.queues

  name                       = each.key
  visibility_timeout_seconds = each.value.visibility
  receive_wait_time_seconds  = 20     # long polling
  message_retention_seconds  = 345600 # 4 dias
  sqs_managed_sse_enabled    = true

  # Depois de 5 entregas sem sucesso a mensagem vai para a DLQ (veneno não trava a fila).
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = merge(local.tags, { Component = "messaging" })
}

resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  for_each  = local.queues
  queue_url = aws_sqs_queue.dlq[each.key].id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.this[each.key].arn]
  })
}

# Só os tópicos assinados podem publicar na fila.
data "aws_iam_policy_document" "queue" {
  for_each = { for q, sources in local.queue_sources : q => sources if length(sources) > 0 }

  statement {
    sid       = "AllowSNS"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.this[each.key].arn]

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = each.value
    }
  }
}

resource "aws_sqs_queue_policy" "this" {
  for_each  = data.aws_iam_policy_document.queue
  queue_url = aws_sqs_queue.this[each.key].id
  policy    = each.value.json
}

# Raw delivery: a fila recebe o envelope JSON do serviço, sem o invólucro do SNS, e os
# MessageAttributes (tipo, traceparent) viram atributos da mensagem SQS.
resource "aws_sns_topic_subscription" "this" {
  for_each = local.subscriptions

  topic_arn            = aws_sns_topic.this[each.value.topic].arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.this[each.value.queue].arn
  raw_message_delivery = true

  depends_on = [aws_sqs_queue_policy.this]
}

# Mensagem na DLQ = saga travada ou notificação perdida. O alarme fica no CloudWatch: o Learner
# Lab não permite integrar a conta AWS ao New Relic, então lá o alerta equivalente usa o log
# message_failed na entrega de número max_receive_count (condição "dlq" em observability/alerts.tf).
resource "aws_cloudwatch_metric_alarm" "dlq" {
  for_each = local.queues

  alarm_name          = "${local.name}-dlq-${each.key}"
  alarm_description   = "Mensagens na DLQ ${each.key}-dlq: consulte docs/runbooks/dlq.md (redrive depois de corrigir a causa)"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.dlq[each.key].name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  tags = local.tags
}
