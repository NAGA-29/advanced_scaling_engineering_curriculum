variable "prefix" {
  description = "Prefix for all resource names"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID in which to launch Redis instances"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for the security group"
  type        = string
}

variable "app_security_group_id" {
  description = "Security group ID of the application layer; allowed to connect on port 6379"
  type        = string
}

variable "ami_id" {
  description = "AMI ID for the Redis EC2 instances (use Amazon Linux 2023)"
  type        = string
}

variable "instance_count" {
  description = "Number of Redis instances to create"
  type        = number
  default     = 1
}
