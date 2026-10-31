terraform {
  required_version = ">= 1.5.0"

  required_providers {
    newrelic = {
      source  = "newrelic/newrelic"
      version = "3.100.5"
    }
  }

  # Mesmo bucket do state da infra, com outra chave (observability/prod.tfstate), passada no init.
  backend "s3" {}
}

# A user key (NRAK-...) vem de NEW_RELIC_API_KEY no ambiente, nunca do código nem do tfvars.
provider "newrelic" {
  account_id = var.new_relic_account_id
  region     = var.new_relic_region
}
