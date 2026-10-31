# Usado só no plan dos PRs (o cluster é único e o apply roda apenas na main).
environment   = "staging"
k8s_namespace = "postech-homolog"
node_min      = 2
node_max      = 4
node_desired  = 2
