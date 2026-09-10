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
    key            = "network/terraform.tfstate"
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
  description = "Name later used for the EKS cluster; subnets get tagged for its auto-discovery"
  type        = string
  default     = "conduit"
}

provider "aws" {
  region = var.region
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet" "public_a" {
  vpc_id            = data.aws_vpc.default.id
  availability_zone = "us-east-1a"
  # The default VPC's original 172.31.0.0/20 subnet in this AZ.
  cidr_block = "172.31.0.0/20"
}

data "aws_subnet" "public_b" {
  vpc_id            = data.aws_vpc.default.id
  availability_zone = "us-east-1b"
  # The default VPC's original 172.31.80.0/20 subnet in this AZ.
  cidr_block = "172.31.80.0/20"
}

resource "aws_ec2_tag" "public_a_cluster" {
  resource_id = data.aws_subnet.public_a.id
  key         = "kubernetes.io/cluster/${var.cluster_name}"
  value       = "shared"
}

resource "aws_ec2_tag" "public_a_elb" {
  resource_id = data.aws_subnet.public_a.id
  key         = "kubernetes.io/role/elb"
  value       = "1"
}

resource "aws_ec2_tag" "public_b_cluster" {
  resource_id = data.aws_subnet.public_b.id
  key         = "kubernetes.io/cluster/${var.cluster_name}"
  value       = "shared"
}

resource "aws_ec2_tag" "public_b_elb" {
  resource_id = data.aws_subnet.public_b.id
  key         = "kubernetes.io/role/elb"
  value       = "1"
}

# New private subnets for EKS nodes and RDS — unused /20 ranges within the
# default VPC's 172.31.0.0/16.
resource "aws_subnet" "private_a" {
  vpc_id                  = data.aws_vpc.default.id
  cidr_block              = "172.31.96.0/20"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = false

  tags = {
    Name                                          = "${var.cluster_name}-private-us-east-1a"
    "kubernetes.io/cluster/${var.cluster_name}"   = "shared"
    "kubernetes.io/role/internal-elb"             = "1"
  }
}

resource "aws_subnet" "private_b" {
  vpc_id                  = data.aws_vpc.default.id
  cidr_block              = "172.31.112.0/20"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = false

  tags = {
    Name                                          = "${var.cluster_name}-private-us-east-1b"
    "kubernetes.io/cluster/${var.cluster_name}"   = "shared"
    "kubernetes.io/role/internal-elb"             = "1"
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.cluster_name}-nat"
  }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = data.aws_subnet.public_a.id

  tags = {
    Name = "${var.cluster_name}-nat"
  }
}

resource "aws_route_table" "private" {
  vpc_id = data.aws_vpc.default.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = {
    Name = "${var.cluster_name}-private"
  }
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private.id
}

output "vpc_id" {
  value = data.aws_vpc.default.id
}

output "private_subnet_ids" {
  value = [aws_subnet.private_a.id, aws_subnet.private_b.id]
}

output "public_subnet_ids" {
  value = [data.aws_subnet.public_a.id, data.aws_subnet.public_b.id]
}

