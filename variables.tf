variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "postech-tc4"
}

variable "environment" {
  type = string
}

variable "vpc_id" {
  type        = string
  default     = ""
  description = "VPC do cluster; vazio usa a VPC padrão da conta (a do Learner Lab)"
}

variable "k8s_namespace" {
  type        = string
  default     = "postech"
  description = "Namespace dos microsserviços: o gateway procura os NLBs <serviço>-public nele"
}

variable "max_receive_count" {
  type        = number
  default     = 5
  description = "Entregas sem sucesso antes de a mensagem ir para a DLQ"
}

variable "notification_visibility_timeout" {
  type        = number
  default     = 180
  description = "Visibilidade da fila da Lambda de notificação (6x o timeout da function, como recomenda a AWS)"
}

variable "cluster_version" {
  type    = string
  default = "1.35"
}

variable "node_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "node_min" {
  type    = number
  default = 2
}

variable "node_max" {
  type    = number
  default = 5
}

variable "node_desired" {
  type    = number
  default = 2
}

variable "lambda_issuer_function_name" {
  type        = string
  default     = ""
  description = "Vazio = <project>-<environment>-auth-issuer (nome criado pelo postech-tc4-lambda-auth)"
}

variable "lambda_authorizer_function_name" {
  type        = string
  default     = ""
  description = "Vazio = <project>-<environment>-auth-authorizer"
}

variable "metrics_server_version" {
  type        = string
  default     = null
  description = "Versao do addon metrics-server; null usa a padrao da versao do cluster"
}

variable "vpc_cni_version" {
  type        = string
  default     = null
  description = "Versao do addon vpc-cni; null usa a padrao da versao do cluster"
}

variable "cluster_az_ids" {
  type        = list(string)
  default     = ["use1-az1", "use1-az2", "use1-az4", "use1-az5", "use1-az6"]
  description = "AZs das subnets do cluster; use1-az3 fica de fora porque o EKS nao aceita control plane nela"
}

variable "lab_eks_cluster_role_regex" {
  type    = string
  default = "LabEksClusterRole"
}

variable "lab_eks_node_role_regex" {
  type        = string
  default     = "^LabRole$"
  description = "Role dos nós. LabRole porque os pods herdam dela o acesso a SQS, SNS e DynamoDB; a LabEksNodeRole só tem as policies de worker"
}
