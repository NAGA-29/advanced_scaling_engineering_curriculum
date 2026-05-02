terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# -------------------------------------------------------------------
# Security Group
# -------------------------------------------------------------------
resource "aws_security_group" "rds" {
  name        = "${var.prefix}-rds-sg"
  description = "Security group for RDS MySQL instance"
  vpc_id      = var.vpc_id

  ingress {
    description     = "MySQL from app security group"
    from_port       = 3306
    to_port         = 3306
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
    Name = "${var.prefix}-rds-sg"
  }
}

# -------------------------------------------------------------------
# DB Subnet Group
# -------------------------------------------------------------------
resource "aws_db_subnet_group" "main" {
  name       = "${var.prefix}-db-subnet-group"
  subnet_ids = var.subnet_ids

  tags = {
    Name = "${var.prefix}-db-subnet-group"
  }
}

# -------------------------------------------------------------------
# Primary RDS Instance (MySQL 8.0, single-AZ to minimise cost)
# -------------------------------------------------------------------
resource "aws_db_instance" "primary" {
  identifier        = "${var.prefix}-mysql-primary"
  engine            = "mysql"
  engine_version    = "8.0"
  instance_class    = var.instance_class
  allocated_storage = 20
  storage_type      = "gp2"

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  multi_az               = false   # single-AZ for learning / cost savings
  publicly_accessible    = false
  skip_final_snapshot    = true    # learning environment — no final snapshot needed
  deletion_protection    = false

  backup_retention_period = 1
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  tags = {
    Name = "${var.prefix}-mysql-primary"
  }
}

# -------------------------------------------------------------------
# Optional Read Replica
# -------------------------------------------------------------------
resource "aws_db_instance" "replica" {
  count = var.create_replica ? 1 : 0

  identifier          = "${var.prefix}-mysql-replica"
  replicate_source_db = aws_db_instance.primary.identifier
  instance_class      = var.instance_class

  publicly_accessible = false
  skip_final_snapshot = true
  deletion_protection = false

  tags = {
    Name = "${var.prefix}-mysql-replica"
  }
}
