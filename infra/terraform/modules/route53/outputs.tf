output "fqdn" {
  description = "Fully qualified domain name of the created Route53 record"
  value       = aws_route53_record.alb_alias.fqdn
}
