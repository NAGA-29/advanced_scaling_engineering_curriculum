output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer — point your browser here"
  value       = module.alb.alb_dns_name
}

output "alb_url" {
  description = "HTTP URL of the ALB"
  value       = "http://${module.alb.alb_dns_name}"
}

output "ec2_instance_ids" {
  description = "IDs of the two application EC2 instances"
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

output "rds_primary_address" {
  description = "RDS primary hostname"
  value       = module.rds.primary_address
}

output "vpc_id" {
  description = "VPC ID created for step05"
  value       = module.vpc.vpc_id
}

output "ssh_commands" {
  description = "SSH commands to reach each EC2 instance"
  value = [
    for ip in module.ec2.public_ips :
    "ssh -i ~/.ssh/id_rsa ec2-user@${ip}"
  ]
}
