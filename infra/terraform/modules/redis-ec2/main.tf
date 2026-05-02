terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# -------------------------------------------------------------------
# Security Group — Redis port only accessible from the app layer
# -------------------------------------------------------------------
resource "aws_security_group" "redis" {
  name        = "${var.prefix}-redis-sg"
  description = "Security group for Redis EC2 instances"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Redis from app security group"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [var.app_security_group_id]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.prefix}-redis-sg"
  }
}

# -------------------------------------------------------------------
# User-data script — installs Redis 7 on Amazon Linux 2023
# -------------------------------------------------------------------
locals {
  redis_user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail

    # Amazon Linux 2023 uses dnf
    dnf update -y
    dnf install -y redis6

    # Enable and start Redis, binding to all interfaces inside the VPC
    sed -i 's/^bind 127.0.0.1/bind 0.0.0.0/' /etc/redis/redis.conf || \
      sed -i 's/^bind 127.0.0.1/bind 0.0.0.0/' /etc/redis6/redis.conf || true

    systemctl enable redis6
    systemctl start redis6
  EOF
}

# -------------------------------------------------------------------
# Redis EC2 Instances
# -------------------------------------------------------------------
resource "aws_instance" "redis" {
  count = var.instance_count

  ami                    = var.ami_id
  instance_type          = "t3.micro"
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.redis.id]

  user_data                   = local.redis_user_data
  user_data_replace_on_change = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    delete_on_termination = true
  }

  tags = {
    Name = "${var.prefix}-redis-${count.index + 1}"
    Role = "redis"
  }
}
