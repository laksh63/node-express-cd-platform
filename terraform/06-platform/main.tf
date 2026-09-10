terraform {
  required_version = ">= 1.6"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
  }
}

variable "kubeconfig_path" {
  description = "Path to the kubeconfig written by the cluster layer"
  type        = string
  default     = "~/.kube/config"
}

variable "cluster_name" {
  type    = string
  default = "conduit"
}

variable "grafana_admin_password" {
  description = "Grafana admin password. Local development default only."
  type        = string
  default     = "admin"
  sensitive   = true
}

locals {
  kube_context = "kind-${var.cluster_name}"
}

provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = local.kube_context
}

provider "helm" {
  kubernetes {
    config_path    = var.kubeconfig_path
    config_context = local.kube_context
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

output "grafana_port_forward" {
  value = "kubectl port-forward -n monitoring svc/monitoring-grafana 3002:80"
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
    # Single-node local cluster: no need for HA replicas.
    redis-ha = { enabled = false }
    controller = { replicas = 1 }
    server = {
      # kind has no load balancer; reach the UI via port-forward.
      service = { type = "ClusterIP" }
      extraArgs = ["--insecure"]
    }
  })]
}
