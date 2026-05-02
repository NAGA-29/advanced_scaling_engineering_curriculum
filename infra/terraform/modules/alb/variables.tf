variable "prefix" {
  description = "Prefix for all resource names"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID to deploy the ALB into"
  type        = string
}

variable "subnet_ids" {
  description = "List of public subnet IDs for the ALB (minimum 2, in different AZs)"
  type        = list(string)
}

variable "instance_ids" {
  description = "List of EC2 instance IDs to register with the target group"
  type        = list(string)
}

variable "health_check_path" {
  description = "HTTP path used for ALB health checks"
  type        = string
  default     = "/health"
}
