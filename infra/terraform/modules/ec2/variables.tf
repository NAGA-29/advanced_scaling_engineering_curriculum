variable "prefix" {
  description = "Prefix for all resource names"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "ami_id" {
  description = "AMI ID to use for EC2 instances (use latest Amazon Linux 2023 for the target region)"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID in which to launch instances"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for the security group"
  type        = string
}

variable "public_key" {
  description = "Public SSH key material to create the key pair"
  type        = string
}

variable "ssh_cidr" {
  # IMPORTANT: restrict this in production — e.g. your office IP or VPN CIDR
  description = "CIDR block allowed to SSH into instances. Defaults to 0.0.0.0/0 for learning; restrict in production."
  type        = string
  default     = "0.0.0.0/0"
}

variable "instance_count" {
  description = "Number of EC2 instances to create"
  type        = number
  default     = 1
}

variable "user_data_template" {
  description = "Path to a templatefile-compatible shell script for instance user_data. Leave empty string to skip."
  type        = string
  default     = ""
}
