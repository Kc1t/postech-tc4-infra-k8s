output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_security_group_id" {
  value = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "api_gateway_id" {
  value = aws_apigatewayv2_api.this.id
}

output "api_gateway_endpoint" {
  value = aws_apigatewayv2_api.this.api_endpoint
}

output "api_gateway_routes" {
  description = "Rotas criadas neste apply (as de um serviço aparecem depois que o NLB dele existe)"
  value = {
    emitir_token = local.issuer_enabled ? "POST ${aws_apigatewayv2_api.this.api_endpoint}/auth" : "issuer ainda não publicado (${local.issuer_name})"
    authorizer   = local.authorizer_enabled ? local.authorizer_name : "não publicado: rotas protegidas não são criadas"
    backends     = { for k, lb in data.aws_lb.backend : k => lb.dns_name }
    rotas        = sort(keys(local.live_routes))
  }
}

output "sns_topic_arns" {
  value = { for k, t in aws_sns_topic.this : k => t.arn }
}

output "sqs_queue_urls" {
  value = { for k, q in aws_sqs_queue.this : k => q.url }
}

output "sqs_dlq_urls" {
  value = { for k, q in aws_sqs_queue.dlq : k => q.url }
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.this.name}"
}
