terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# -------------------------------------------------------------------
# Key Pair
# -------------------------------------------------------------------
resource "aws_key_pair" "main" {
  key_name   = "${var.prefix}-key"
  public_key = var.public_key

  tags = {
    Name = "${var.prefix}-key"
  }
}

# -------------------------------------------------------------------
# Security Group
# -------------------------------------------------------------------
resource "aws_security_group" "app" {
  name        = "${var.prefix}-app-sg"
  description = "Security group for application EC2 instances"
  vpc_id      = var.vpc_id

  # SSH access — restrict var.ssh_cidr in production (see variables.tf)
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_cidr]
  }

  # Application port 8080 from anywhere (ALB or direct during learning)
  ingress {
    description = "App port 8080"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP port 80 from anywhere
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.prefix}-app-sg"
  }
}

# -------------------------------------------------------------------
# IAM Role & Instance Profile
# -------------------------------------------------------------------
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${var.prefix}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = {
    Name = "${var.prefix}-ec2-role"
  }
}

# Attach SSM policy so instances can be accessed via Session Manager
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.prefix}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# -------------------------------------------------------------------
# EC2 Instances
# -------------------------------------------------------------------
resource "aws_instance" "app" {
  count = var.instance_count

  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.app.id]
  key_name               = aws_key_pair.main.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  user_data = var.user_data_template != "" ? templatefile(var.user_data_template, {
    prefix       = var.prefix
    instance_num = count.index + 1
  }) : null

  user_data_replace_on_change = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    delete_on_termination = true
  }

  tags = {
    Name = "${var.prefix}-app-${count.index + 1}"
  }
}
