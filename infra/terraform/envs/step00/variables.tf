variable "aws_region" {
  description = "AWS region to deploy resources into"
  type        = string
  default     = "ap-northeast-1"
}

variable "prefix" {
  description = "Prefix applied to all resource names"
  type        = string
  default     = "scaling-step00"
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
  # Latest Amazon Linux 2023 AMI for ap-northeast-1 as of 2024:
  #   aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text
  description = "AMI ID for EC2 instances. Use the latest Amazon Linux 2023 AMI for your target region."
  type        = string
  default     = "ami-0599b6e53ca798bb2" # Amazon Linux 2023 ap-northeast-1 (update as needed)
}
