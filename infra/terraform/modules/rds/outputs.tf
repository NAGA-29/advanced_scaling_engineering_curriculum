output "primary_endpoint" {
  description = "Connection endpoint (host:port) of the primary RDS instance"
  value       = aws_db_instance.primary.endpoint
}

output "primary_address" {
  description = "Hostname of the primary RDS instance"
  value       = aws_db_instance.primary.address
}

output "replica_endpoint" {
  description = "Connection endpoint of the read replica. Empty string when create_replica is false."
  value       = var.create_replica ? aws_db_instance.replica[0].endpoint : ""
}

output "security_group_id" {
  description = "ID of the RDS security group"
  value       = aws_security_group.rds.id
}
