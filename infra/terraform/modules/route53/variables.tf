variable "zone_id" {
  description = "Route53 hosted zone ID (zone must already exist; this module does not create it)"
  type        = string
}

variable "record_name" {
  description = "DNS record name (e.g. 'app.example.com' or just 'app' for a relative name within the zone)"
  type        = string
}

variable "alb_dns_name" {
  description = "DNS name of the ALB to alias to"
  type        = string
}

variable "alb_zone_id" {
  description = "Hosted zone ID of the ALB (needed for ALIAS records; available from the alb module output)"
  type        = string
}

variable "ttl" {
  description = "TTL in seconds (not used for ALIAS records but kept for documentation consistency)"
  type        = number
  default     = 300
}
