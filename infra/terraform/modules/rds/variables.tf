variable "prefix" {
  description = "Prefix for all resource names"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID to deploy RDS into"
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet IDs for the DB subnet group (minimum 2 subnets in different AZs)"
  type        = list(string)
}

variable "app_security_group_id" {
  description = "Security group ID of the application layer; allowed to connect on port 3306"
  type        = string
}

variable "db_name" {
  description = "Name of the initial database to create"
  type        = string
  default     = "scaling"
}

variable "db_username" {
  description = "Master username for the RDS instance"
  type        = string
}

variable "db_password" {
  description = "Master password for the RDS instance"
  type        = string
  sensitive   = true
}

variable "instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "create_replica" {
  description = "Whether to create a read replica (set to true when practising replication in later steps)"
  type        = bool
  default     = false
}
