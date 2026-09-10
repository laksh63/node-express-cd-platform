terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "s3" {
    bucket         = "node-express-cd-platform-tfstate-719129114745"
    key            = "secrets/terraform.tfstate"
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

provider "aws" {
  region = var.region
}

# JWT signing secret — fully generated and managed here, no manual step.
resource "random_password" "jwt_secret" {
  length  = 64
  special = false
}

resource "aws_secretsmanager_secret" "jwt" {
  name = "${var.cluster_name}/jwt-secret"
}

resource "aws_secretsmanager_secret_version" "jwt" {
  secret_id     = aws_secretsmanager_secret.jwt.id
  secret_string = random_password.jwt_secret.result
}

# Argo CD's GitHub repo credentials — Terraform only creates the container.
# The actual PAT value is seeded once, by hand, via:
#   aws secretsmanager put-secret-value --secret-id <name> --secret-string '{"username":"laksh63","password":"<PAT>"}'
# so a real GitHub credential never passes through Terraform state or git.
resource "aws_secretsmanager_secret" "argocd_repo" {
  name = "${var.cluster_name}/argocd-repo-credentials"
}

output "jwt_secret_arn" {
  value = aws_secretsmanager_secret.jwt.arn
}

output "argocd_repo_secret_arn" {
  value = aws_secretsmanager_secret.argocd_repo.arn
}

output "argocd_repo_secret_name" {
  value = aws_secretsmanager_secret.argocd_repo.name
}
