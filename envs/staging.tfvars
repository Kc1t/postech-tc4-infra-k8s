# Não é aplicado: existe um só ambiente na AWS (ADR-0021) e o plan dos PRs usa o prod.tfvars.
# Fica para um eventual segundo ambiente.
environment   = "staging"
k8s_namespace = "postech-homolog"
node_min      = 2
node_max      = 4
node_desired  = 2
