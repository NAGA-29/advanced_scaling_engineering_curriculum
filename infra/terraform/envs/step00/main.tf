terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  prefix = var.prefix
}

# -------------------------------------------------------------------
# VPC
# -------------------------------------------------------------------
module "vpc" {
  source = "../../modules/vpc"

  prefix             = local.prefix
  vpc_cidr           = "10.0.0.0/16"
  public_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24"]
  availability_zones  = ["${var.aws_region}a", "${var.aws_region}c"]
}

# -------------------------------------------------------------------
# EC2 (single instance for step00 — baseline single-server setup)
# -------------------------------------------------------------------
module "ec2" {
  source = "../../modules/ec2"

  prefix         = local.prefix
  instance_type  = "t3.micro"
  ami_id         = var.ami_id
  subnet_id      = module.vpc.public_subnet_ids[0]
  vpc_id         = module.vpc.vpc_id
  public_key     = var.public_key
  ssh_cidr       = var.ssh_cidr
  instance_count = 1
}
