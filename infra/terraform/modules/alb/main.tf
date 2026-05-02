terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# -------------------------------------------------------------------
# Security Group for the ALB
# -------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${var.prefix}-alb-sg"
  description = "Security group for the Application Load Balancer"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
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
    Name = "${var.prefix}-alb-sg"
  }
}

# -------------------------------------------------------------------
# Application Load Balancer
# -------------------------------------------------------------------
resource "aws_lb" "main" {
  name               = "${var.prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.subnet_ids

  enable_deletion_protection = false

  tags = {
    Name = "${var.prefix}-alb"
  }
}

# -------------------------------------------------------------------
# Target Group
# -------------------------------------------------------------------
resource "aws_lb_target_group" "app" {
  name     = "${var.prefix}-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    enabled             = true
    path                = var.health_check_path
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = {
    Name = "${var.prefix}-tg"
  }
}

# -------------------------------------------------------------------
# Target Group Attachments
# -------------------------------------------------------------------
resource "aws_lb_target_group_attachment" "app" {
  count = length(var.instance_ids)

  target_group_arn = aws_lb_target_group.app.arn
  target_id        = var.instance_ids[count.index]
  port             = 8080
}

# -------------------------------------------------------------------
# HTTP Listener (port 80 -> forward to target group)
# -------------------------------------------------------------------
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
