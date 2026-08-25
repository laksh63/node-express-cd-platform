# Infrastructure as Code

Terraform provisions the cluster and the observability platform.

## Why two layers

Terraform resolves provider configuration during `plan`, before any resource
is created. A single configuration that both creates a cluster *and*
configures the Helm provider from that cluster's credentials cannot plan —
the credentials do not exist yet.

The layers are therefore applied in sequence, each with its own state:

| Layer | Creates | Provider |
|---|---|---|
| `01-cluster` | kind cluster, nodes, port mappings | `tehcyx/kind` |
| `02-platform` | Prometheus, Grafana, Loki, Promtail | `helm`, `kubernetes` |


## Usage

```bash
# Layer 1 — cluster
cd terraform/01-cluster
terraform init
terraform apply

# Layer 2 — platform
cd ../02-platform
terraform init
terraform apply
```

Teardown runs in reverse:

```bash
cd terraform/02-platform && terraform destroy
cd ../01-cluster && terraform destroy
```

## What is not managed here

**Application manifests.** `k8s/api.yaml`, `k8s/postgres.yaml`, and
`k8s/servicemonitor.yaml` are applied with `kubectl`, not Terraform.

This is deliberate. Terraform is a poor fit for workloads that change on
every commit.

The dividing line used here is: **Terraform owns things that are created
once and rarely change; a GitOps controller owns things that change per
commit.**
