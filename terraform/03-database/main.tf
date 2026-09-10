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
    key            = "database/terraform.tfstate"
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

variable "db_name" {
  type    = string
  default = "conduit"
}

variable "db_username" {
  type    = string
  default = "conduit_admin"
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

data "terraform_remote_state" "cluster" {
  backend = "s3"
  config = {
    bucket = "node-express-cd-platform-tfstate-719129114745"
    key    = "cluster/terraform.tfstate"
    region = "us-east-1"
  }
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.cluster_name}-db"
  subnet_ids = data.terraform_remote_state.network.outputs.private_subnet_ids
}

resource "aws_security_group" "rds" {
  name_prefix = "${var.cluster_name}-rds-"
  vpc_id      = data.terraform_remote_state.network.outputs.vpc_id

  ingress {
    description     = "Postgres from EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [data.terraform_remote_state.cluster.outputs.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "postgres" {
  identifier     = "${var.cluster_name}-postgres"
  engine         = "postgres"
  engine_version = "16"

  instance_class    = "db.t4g.micro"
  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username

  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az                = false

  backup_retention_period = 7
  # Project/test account — no final snapshot needed for easy teardown.
  skip_final_snapshot = true
  deletion_protection  = false
}

output "db_endpoint" {
  value = aws_db_instance.postgres.address
}

output "db_port" {
  value = aws_db_instance.postgres.port
}

output "db_name" {
  value = aws_db_instance.postgres.db_name
}

output "db_username" {
  value = aws_db_instance.postgres.username
}

output "master_user_secret_arn" {
  value = aws_db_instance.postgres.master_user_secret[0].secret_arn
}
