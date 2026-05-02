output "private_ips" {
  description = "List of private IP addresses of the Redis instances"
  value       = aws_instance.redis[*].private_ip
}

output "instance_ids" {
  description = "List of Redis EC2 instance IDs"
  value       = aws_instance.redis[*].id
}

output "security_group_id" {
  description = "ID of the Redis security group"
  value       = aws_security_group.redis.id
}
