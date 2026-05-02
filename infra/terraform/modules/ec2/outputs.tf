output "instance_ids" {
  description = "List of EC2 instance IDs"
  value       = aws_instance.app[*].id
}

output "public_ips" {
  description = "List of public IP addresses assigned to the instances"
  value       = aws_instance.app[*].public_ip
}

output "private_ips" {
  description = "List of private IP addresses assigned to the instances"
  value       = aws_instance.app[*].private_ip
}

output "security_group_id" {
  description = "ID of the application security group"
  value       = aws_security_group.app.id
}
