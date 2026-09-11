# RealWorld CI/CD Platform

A continuous delivery platform for the [RealWorld](https://github.com/gothinkster/realworld) API, running on AWS EKS. Terraform provisions the VPC, cluster, database, and platform; GitHub Actions builds and tests; Argo CD deploys; Prometheus, Grafana, and Loki watch it.

The app itself is the upstream Node/Express + Prisma implementation. I only touched it where the platform needed something — a metrics endpoint, a health check, the Dockerfile. Everything else here is the platform.

## What's covered

All eight requirements:

- **Tiered architecture** — app tier (EKS pods behind LoadBalancer Services), data tier (RDS, private subnets, reachable only from the EKS node security group).
- **AWS managed services** — EKS, RDS, ECR, Secrets Manager, S3 + DynamoDB, CloudWatch.
- **Infrastructure as Code** — Terraform, seven layers, each with its own remote state.
- **Containerization** — Docker, deployed to EKS.
- **CI/CD** — GitHub Actions builds/tests/pushes to ECR, Argo CD deploys, merge to master ships.
- **Observability** — Prometheus + Grafana, plus EKS control-plane logs in CloudWatch.
- **Centralized logging** — Loki + Promtail.
- **Backups** — RDS automated backups, 7-day retention, point-in-time recovery. Restore itself is untested — see gaps.

Started on a local [kind](https://kind.sigs.k8s.io/) cluster before the full submission details came through; once AWS was in scope, moving over wasn't much work — same manifests, same GitOps flow, different underlying infrastructure.


## Stack

![Architecture](Docs/Architecture.png)

Node 20, TypeScript, Express, Prisma 4, PostgreSQL 16 (RDS), Nx. Docker on `node:20-slim`. EKS, ECR, Argo CD. Prometheus, Grafana, Loki. Secrets Manager + External Secrets Operator for credentials.

## Layout

```
terraform/00-backend    S3 + DynamoDB remote state
terraform/01-network    default VPC + 2 private subnets + NAT gateway
terraform/02-cluster    EKS, node group, EBS CSI driver via IRSA
terraform/03-database   RDS, credentials in Secrets Manager
terraform/04-secrets    JWT secret + Argo CD repo-credentials container
terraform/05-registry   ECR repo + lifecycle policy, CI IAM user
terraform/06-platform   Helm releases, External Secrets Operator, default StorageClass
k8s/                    app manifests, Argo CD Application, ExternalSecret
.github/workflows/      CI and the manifest update job
src/app/metrics.ts      prom-client instrumentation
```

## Running it

Each layer has its own state and reads the previous one's outputs via `terraform_remote_state`. `06-platform` reads the Argo CD PAT from Secrets Manager, so it can't run until that secret has a value — apply `00` through `05` first:

```bash
export AWS_PROFILE=<your-profile>
for layer in 00-backend 01-network 02-cluster 03-database 04-secrets 05-registry; do
  (cd terraform/$layer && terraform init && terraform apply)
done
```

`04-secrets` only creates the container for the Argo CD PAT, not a value — one thing nothing can generate on its own, seeded straight into Secrets Manager:

```bash
aws secretsmanager put-secret-value \
  --secret-id conduit/argocd-repo-credentials \
  --secret-string '{"username":"laksh63","password":"YOUR_GITHUB_PAT"}'
```

The JWT secret and the RDS password are both generated automatically — no manual step for either. Now `06-platform` can apply:

```bash
cd terraform/06-platform && terraform init && terraform apply
```

Hand Argo the Application and it takes over:

```bash
kubectl apply -f k8s/argocd-application.yaml
```

`api-credentials` isn't created by hand anymore — an `ExternalSecret` (`k8s/external-secrets.yaml`) pulls it from Secrets Manager via External Secrets Operator, under an IRSA role scoped to just the RDS and JWT ARNs. `repo-conduit` is the one exception: Argo CD needs it before it can pull `k8s/` at all, so Terraform creates it directly, wrapped in `sensitive()` so it doesn't print in plan/apply output.

Migrations are still manual:

```bash
kubectl exec deployment/api -- sh -c \
  "cd /app/api && ./node_modules/.bin/prisma migrate deploy --schema=./src/prisma/schema.prisma"
```

Check it:

```bash
API_LB=$(kubectl get svc api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl "http://$API_LB/api/articles"     # {"articles":[],"articlesCount":0}
curl "http://$API_LB/metrics"
```

Grafana and Argo CD are real LoadBalancer Services now:

```bash
kubectl get svc -n monitoring monitoring-grafana
kubectl get svc -n argocd argocd-server
```

Grafana password: `kubectl get secret -n monitoring monitoring-grafana -o jsonpath='{.data.admin-password}' | base64 -d`

Teardown, in reverse: `06-platform`, `05-registry`, `04-secrets`, `03-database`, `02-cluster`, `01-network`, then `00-backend` last — every other layer's state lives in the bucket it creates.

## How a deploy happens

Merge to master:

1. `test` — Postgres service container, migrate, lint, Jest
2. `build` — compile, build image, push to ECR tagged with the commit SHA
3. `update-manifest` — rewrite `k8s/api.yaml` with that SHA, commit back `[skip ci]`
4. Argo CD sees the commit and syncs

CI never touches the cluster, only Git. `prune` + `selfHeal` are on, so Git is the only way to change the cluster. Argo CD polls on its own schedule though — right after a merge, `Synced` can briefly show the previous revision. `kubectl patch application conduit -n argocd --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'` forces an immediate check.

## Seven Terraform layers

A config that creates a cluster *and* configures the Helm provider from that cluster's credentials can't plan — the credentials don't exist yet. So it's split, each layer with its own S3 state, later layers reading earlier ones via `terraform_remote_state`:

| Layer | Creates | Depends on |
|---|---|---|
| `00-backend` | S3 bucket, DynamoDB lock table | — |
| `01-network` | 2 private subnets, NAT gateway | `00-backend` |
| `02-cluster` | EKS, node group, EBS CSI IRSA role | `01-network` |
| `03-database` | RDS, subnet group, security group | `01-network`, `02-cluster` |
| `04-secrets` | JWT + Argo CD repo secrets | — |
| `05-registry` | ECR repo, CI IAM user | — |
| `06-platform` | Helm releases, ESO, `repo-conduit`, StorageClass | `02-cluster`, `03-database`, `04-secrets` |

Splitting it this finely keeps blast radius small — a database change can't touch the network layer. The bucket name is a literal repeated in every `backend "s3" {}` block, unavoidably (Terraform resolves backend config before any variable exists). Everywhere else it's a `local`.

## Networking

EKS and RDS sit in the account's existing default VPC, not a new one — but its six subnets are all public. `01-network` adds two private subnets and one NAT gateway, and tags two existing public subnets for the LoadBalancer/EKS auto-discovery convention. EKS's public API endpoint stays open to the internet, no bastion or VPN — see gaps.

## Data tier

Postgres is RDS: `db.t4g.micro`, single-AZ, encrypted, master password generated and rotated by RDS itself. Automated backups, 7-day retention, point-in-time recovery — replaces the old `pg_dump` CronJob outright.

Before RDS it ran as a StatefulSet on a PVC — verified by deleting `postgres-0`, waiting for the replacement, confirming `"has already been taken"` on the same registration. When it was cut over, the PVC didn't get pruned with the rest of the manifest — Kubernetes deliberately leaves `volumeClaimTemplate` PVCs behind on StatefulSet deletion — so it needed a manual `kubectl delete pvc`.

## Secrets

Three secrets, three lifecycles, none of them need manual `kubectl create secret`:

- **RDS password** — RDS generates and owns it. Terraform never sees the value.
- **JWT secret** — Terraform generates it (`random_password`), fully automated.
- **Argo CD's GitHub PAT** — the one thing nothing can generate. Terraform creates the Secrets Manager container; the value is seeded once by hand.

External Secrets Operator, IRSA-scoped to exactly the RDS and JWT ARNs, syncs the first two into `api-credentials`. `repo-conduit` is the exception — Argo CD needs it before it can pull `k8s/`, so it can't be GitOps-managed; Terraform creates it directly, and the PAT is wrapped in `sensitive()` before it reaches the resource, because the Kubernetes provider doesn't mark `kubernetes_secret`'s `data` field sensitive on its own — without that wrapper, a `terraform plan` could print it in plaintext.

## Things that bit me

**ServiceMonitor selectors match Service labels, not selectors.** Four targets discovered, four dropped. `app: api` was under `spec.selector`, not on the Service's own metadata. Same key, different field.

**Branch protection vs. the deploy bot.** `update-manifest` pushes to master; the ruleset blocked it for not being a PR, then for having no passing check on a commit that didn't exist yet when the check ran. Relaxed the rule. Real fix is a separate config repo.

**ECR lifecycle policy rejected an empty tag prefix.** `tagPrefixList: ["sha", ""]` — ECR rejects the empty string. The tags are just raw SHAs and `latest`, no prefix scheme, so `tagStatus: "any"` was the right rule, not prefix matching.

**Argo CD doesn't sync on your schedule.** After merging AWS support, `Synced` still showed the old revision — its poll interval hadn't ticked. A hard-refresh annotation forces it.

**The default StorageClass wasn't wired to the CSI driver.** `gp2` on the legacy in-tree provisioner, not marked default, and the `aws-ebs-csi-driver` addon had nothing pointing at it. Caught in an audit pass, not by anything actually breaking — nothing had requested a PVC yet.

**`kubernetes_secret`'s `data` isn't sensitive by default.** Same audit pass. A value sourced carefully from Secrets Manager can still print in plaintext once it lands in that field, because the provider doesn't mark it. `sensitive()` fixes the CLI-output side of it.

## Other decisions

**Route labels use the matched pattern**, not the raw path, or every article slug becomes its own time series.

**Prometheus over VictoriaMetrics.** kube-prometheus-stack gives the operator, exporters, and dashboards in one install. VictoriaMetrics is more efficient at scale — not the constraint here.

**`GITHUB_TOKEN` where possible, a PAT only where necessary.** Argo CD runs inside the cluster, outside any workflow, so it needs something long-lived. Now in Secrets Manager instead of a k8s Secret, but still a PAT.

**Reused the default VPC instead of a new one.** It's what the account had. Added only the two private subnets and one NAT gateway actually needed.

**IAM access keys over OIDC for CI.** Simpler — one Terraform resource instead of an OIDC provider plus trust policy — for an account with one pipeline. OIDC is the better long-term answer.

## Gaps

1. **Branch protection is weakened**, so the deploy bot can push. Right fix: a separate config repo.
2. **Migrations are manual.** A pod restarting against a fresh database won't tell you the schema's missing.
3. Backups are automated; restore is still untested end to end.
4. **Containers run as root.** No `USER` line, no read-only root filesystem.
5. **No resource requests/limits, no HPA, no PodDisruptionBudget.**
6. **No NetworkPolicies.** RDS's security group is scoped, but pod-to-pod traffic inside the cluster is flat.
7. **Loki has no persistence.**
8. **No alerting.**
9. **IAM is broad, not least-privilege.** The applying user has `AdministratorAccess`; the IRSA roles are scoped tightly, the human-facing setup isn't.
10. **EKS's public endpoint has no network-level restriction** — IAM/RBAC only, no IP allowlist, no private-only endpoint.
11. **Single NAT gateway, single-AZ RDS.** Cost tradeoffs, both single points of failure.

---

Forked from [gothinkster/node-express-realworld-example-app](https://github.com/gothinkster/node-express-realworld-example-app). Original README preserved at [`Docs/UPSTREAM_README.md`](Docs/UPSTREAM_README.md).
