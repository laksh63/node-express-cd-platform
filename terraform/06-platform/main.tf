terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
  }

  backend "s3" {
    bucket         = "node-express-cd-platform-tfstate-719129114745"
    key            = "platform/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "node-express-cd-platform-tfstate-lock"
    encrypt        = true
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  type    = string
  default = "conduit"
}

variable "grafana_admin_password" {
  description = "Grafana admin password."
  type        = string
  default     = "admin"
  sensitive   = true
}

variable "github_repo_url" {
  type    = string
  default = "https://github.com/laksh63/node-express-cd-platform"
}

provider "aws" {
  region = var.region
}

locals {
  tfstate_bucket = "node-express-cd-platform-tfstate-719129114745"
  tfstate_region = "us-east-1"
}

data "terraform_remote_state" "cluster" {
  backend = "s3"
  config = {
    bucket = local.tfstate_bucket
    key    = "cluster/terraform.tfstate"
    region = local.tfstate_region
  }
}

data "terraform_remote_state" "database" {
  backend = "s3"
  config = {
    bucket = local.tfstate_bucket
    key    = "database/terraform.tfstate"
    region = local.tfstate_region
  }
}

data "terraform_remote_state" "secrets" {
  backend = "s3"
  config = {
    bucket = local.tfstate_bucket
    key    = "secrets/terraform.tfstate"
    region = local.tfstate_region
  }
}

data "aws_eks_cluster" "this" {
  name = data.terraform_remote_state.cluster.outputs.cluster_name
}

data "aws_eks_cluster_auth" "this" {
  name = data.terraform_remote_state.cluster.outputs.cluster_name
}

locals {
  cluster_host  = data.aws_eks_cluster.this.endpoint
  cluster_ca    = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  cluster_token = data.aws_eks_cluster_auth.this.token
}

provider "kubernetes" {
  host                   = local.cluster_host
  cluster_ca_certificate = local.cluster_ca
  token                  = local.cluster_token
}

provider "helm" {
  kubernetes {
    host                   = local.cluster_host
    cluster_ca_certificate = local.cluster_ca
    token                  = local.cluster_token
  }
}

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }
}

resource "helm_release" "kube_prometheus_stack" {
  name       = "monitoring"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "88.5.4"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  timeout = 900
  wait    = true

  set_sensitive {
    name  = "grafana.adminPassword"
    value = var.grafana_admin_password
  }

  values = [yamlencode({
    grafana = {
      service = { type = "LoadBalancer" }
      additionalDataSources = [{
        name      = "Loki"
        type      = "loki"
        url       = "http://loki:3100"
        access    = "proxy"
        isDefault = false
      }]
    }
  })]
}

resource "helm_release" "loki" {
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki-stack"
  version    = "2.10.2"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  timeout = 900
  wait    = true

  values = [yamlencode({
    loki = {
      enabled     = true
      persistence = { enabled = false }
    }
    promtail   = { enabled = true }
    grafana    = { enabled = false }
    prometheus = { enabled = false }
  })]

  depends_on = [helm_release.kube_prometheus_stack]
}

output "grafana_lb_hint" {
  value = "kubectl get svc -n monitoring monitoring-grafana"
}

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "7.7.11"
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  timeout = 900
  wait    = true

  values = [yamlencode({
    redis-ha   = { enabled = false }
    controller = { replicas = 1 }
    server = {
      service   = { type = "LoadBalancer" }
      extraArgs = ["--insecure"]
    }
  })]
}

data "aws_secretsmanager_secret_version" "argocd_repo" {
  secret_id = data.terraform_remote_state.secrets.outputs.argocd_repo_secret_arn
}

locals {
  argocd_repo_creds = sensitive(jsondecode(data.aws_secretsmanager_secret_version.argocd_repo.secret_string))
}

resource "kubernetes_secret" "repo_conduit" {
  metadata {
    name      = "repo-conduit"
    namespace = kubernetes_namespace.argocd.metadata[0].name
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    type     = "git"
    url      = var.github_repo_url
    username = local.argocd_repo_creds["username"]
    password = local.argocd_repo_creds["password"]
  }

  depends_on = [helm_release.argocd]
}

resource "kubernetes_namespace" "external_secrets" {
  metadata {
    name = "external-secrets"
  }
}

resource "aws_iam_policy" "external_secrets" {
  name = "${var.cluster_name}-external-secrets"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          data.terraform_remote_state.database.outputs.master_user_secret_arn,
          data.terraform_remote_state.secrets.outputs.jwt_secret_arn
        ]
      }
    ]
  })
}

module "external_secrets_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.cluster_name}-external-secrets"

  role_policy_arns = {
    secrets = aws_iam_policy.external_secrets.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = data.terraform_remote_state.cluster.outputs.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }
}

resource "helm_release" "external_secrets" {
  name       = "external-secrets"
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  version    = "0.10.4"
  namespace  = kubernetes_namespace.external_secrets.metadata[0].name

  timeout = 300
  wait    = true

  values = [yamlencode({
    installCRDs = true
    serviceAccount = {
      name = "external-secrets"
      annotations = {
        "eks.amazonaws.com/role-arn" = module.external_secrets_irsa_role.iam_role_arn
      }
    }
  })]
}

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }
}
