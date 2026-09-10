terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "node-express-cd-platform-tfstate-719129114745"
    key            = "cluster/terraform.tfstate"
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

variable "kubernetes_version" {
  type    = string
  default = "1.36"
}

provider "aws" {
  region = var.region
}

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "node-express-cd-platform-tfstate-719129114745"
    key    = "network/terraform.tfstate"
    region = "us-east-1"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  vpc_id     = data.terraform_remote_state.network.outputs.vpc_id
  subnet_ids = data.terraform_remote_state.network.outputs.private_subnet_ids

  cluster_endpoint_public_access = true

  # Grants the applying IAM principal (incodeuser) cluster-admin via EKS
  enable_cluster_creator_admin_permissions = true

  # Ships control-plane logs to CloudWatch Logs.
  cluster_enabled_log_types = ["api", "audit", "authenticator"]

  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni    = {}
    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_irsa_role.iam_role_arn
    }
  }

  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.medium"]
      min_size       = 2
      max_size       = 3
      desired_size   = 2
    }
  }
}

module "ebs_csi_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name             = "${var.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "cluster_oidc_issuer_url" {
  value = module.eks.cluster_oidc_issuer_url
}

output "node_security_group_id" {
  value = module.eks.node_security_group_id
}

output "cluster_security_group_id" {
  value = module.eks.cluster_security_group_id
}
