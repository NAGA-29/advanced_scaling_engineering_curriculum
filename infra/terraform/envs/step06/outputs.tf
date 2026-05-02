output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = module.alb.alb_dns_name
}

output "alb_url" {
  description = "HTTP URL of the Application Load Balancer"
  value       = "http://${module.alb.alb_dns_name}"
}

output "app_fqdn" {
  description = "Custom domain FQDN (empty if Route53 not configured)"
  value       = length(module.route53) > 0 ? module.route53[0].fqdn : ""
}

output "ec2_instance_ids" {
  description = "IDs of the application EC2 instances"
  value       = module.ec2.instance_ids
}

output "ec2_public_ips" {
  description = "Public IP addresses of the application EC2 instances"
  value       = module.ec2.public_ips
}

output "rds_primary_endpoint" {
  description = "RDS primary connection endpoint (host:port)"
  value       = module.rds.primary_endpoint
}

output "rds_replica_endpoint" {
  description = "RDS read replica endpoint (empty if replica not created)"
  value       = module.rds.replica_endpoint
}

output "redis_private_ips" {
  description = "Private IP addresses of the Redis EC2 instances"
  value       = module.redis.private_ips
}

output "vpc_id" {
  description = "VPC ID created for step06"
  value       = module.vpc.vpc_id
}

output "ssh_commands" {
  description = "SSH commands to reach each EC2 application instance"
  value = [
    for ip in module.ec2.public_ips :
    "ssh -i ~/.ssh/id_rsa ec2-user@${ip}"
  ]
}
