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

  prefix              = local.prefix
  vpc_cidr            = "10.0.0.0/16"
  public_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24"]
  availability_zones  = ["${var.aws_region}a", "${var.aws_region}c"]
}

# -------------------------------------------------------------------
# EC2 — application instances
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
  instance_count = var.app_instance_count
}

# -------------------------------------------------------------------
# Application Load Balancer
# -------------------------------------------------------------------
module "alb" {
  source = "../../modules/alb"

  prefix            = local.prefix
  vpc_id            = module.vpc.vpc_id
  subnet_ids        = module.vpc.public_subnet_ids
  instance_ids      = module.ec2.instance_ids
  health_check_path = "/health"
}

# -------------------------------------------------------------------
# RDS — MySQL 8.0, optional read replica
# -------------------------------------------------------------------
module "rds" {
  source = "../../modules/rds"

  prefix                = local.prefix
  vpc_id                = module.vpc.vpc_id
  subnet_ids            = module.vpc.public_subnet_ids
  app_security_group_id = module.ec2.security_group_id
  db_name               = var.db_name
  db_username           = var.db_username
  db_password           = var.db_password
  instance_class        = "db.t3.micro"
  create_replica        = var.create_rds_replica
}

# -------------------------------------------------------------------
# Redis on EC2 (cost-effective alternative to ElastiCache)
# -------------------------------------------------------------------
module "redis" {
  source = "../../modules/redis-ec2"

  prefix                = local.prefix
  subnet_id             = module.vpc.public_subnet_ids[0]
  vpc_id                = module.vpc.vpc_id
  app_security_group_id = module.ec2.security_group_id
  ami_id                = var.ami_id
  instance_count        = 1
}

# -------------------------------------------------------------------
# Route53 DNS alias record (only created when zone_id is provided)
# -------------------------------------------------------------------
module "route53" {
  source = "../../modules/route53"
  count  = var.route53_zone_id != "" ? 1 : 0

  zone_id      = var.route53_zone_id
  record_name  = var.route53_record_name
  alb_dns_name = module.alb.alb_dns_name
  alb_zone_id  = module.alb.alb_zone_id
}
