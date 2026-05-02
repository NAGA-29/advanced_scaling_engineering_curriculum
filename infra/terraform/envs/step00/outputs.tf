output "ec2_public_ip" {
  description = "Public IP address of the step00 EC2 instance"
  value       = module.ec2.public_ips[0]
}

output "ec2_instance_id" {
  description = "Instance ID of the step00 EC2 instance"
  value       = module.ec2.instance_ids[0]
}

output "ssh_command" {
  description = "Ready-to-use SSH command to connect to the instance"
  value       = "ssh -i ~/.ssh/id_rsa ec2-user@${module.ec2.public_ips[0]}"
}

output "vpc_id" {
  description = "VPC ID created for step00"
  value       = module.vpc.vpc_id
}
