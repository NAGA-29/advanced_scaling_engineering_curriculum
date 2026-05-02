variable "aws_region" {
  description = "AWS region to deploy resources into"
  type        = string
  default     = "ap-northeast-1"
}

variable "prefix" {
  description = "Prefix applied to all resource names"
  type        = string
  default     = "scaling-step06"
}

variable "public_key" {
  description = "Public SSH key material (contents of your ~/.ssh/id_rsa.pub or similar)"
  type        = string
}

variable "ssh_cidr" {
  # IMPORTANT: restrict this to your own IP in production, e.g. "203.0.113.0/32"
  description = "CIDR range allowed to SSH. Defaults to 0.0.0.0/0 for learning; restrict in real environments."
  type        = string
  default     = "0.0.0.0/0"
}

variable "ami_id" {
  # To get the latest Amazon Linux 2023 AMI ID:
  #   aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  #     --query Parameter.Value --output text
  description = "AMI ID for EC2 instances. Use the latest Amazon Linux 2023 AMI for your target region."
  type        = string
  default     = "ami-0599b6e53ca798bb2" # Amazon Linux 2023 ap-northeast-1 (update as needed)
}

variable "app_instance_count" {
  description = "Number of application EC2 instances to create"
  type        = number
  default     = 2
}

variable "db_name" {
  description = "Name of the initial MySQL database"
  type        = string
  default     = "scaling"
}

variable "db_username" {
  description = "Master username for the RDS MySQL instance"
  type        = string
  default     = "admin"
}

variable "db_password" {
  description = "Master password for the RDS MySQL instance (use a strong password)"
  type        = string
  sensitive   = true
}

variable "create_rds_replica" {
  description = "Whether to create an RDS read replica (set true to practise read-scaling)"
  type        = bool
  default     = false
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID for DNS. Leave empty string to skip DNS record creation."
  type        = string
  default     = ""
}

variable "route53_record_name" {
  description = "DNS record name to create in the hosted zone (e.g. 'app.example.com')"
  type        = string
  default     = ""
}
