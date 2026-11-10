output "name_prefix" {
  description = "Prefix used for every resource name in this environment."
  value       = local.name_prefix
}
output "account_id" {
  description = "AWS account Terraform is running against."
  value       = data.aws_caller_identity.current.account_id
}
output "vpc_id" {
  description = "ID of the VPC."
  value       = module.network.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (ALB, NAT), one per AZ."
  value       = module.network.public_subnet_ids
}

output "private_app_subnet_ids" {
  description = "Private app subnet IDs (EC2), one per AZ."
  value       = module.network.private_app_subnet_ids
}

output "private_db_subnet_ids" {
  description = "Private db subnet IDs (RDS), one per AZ."
  value       = module.network.private_db_subnet_ids
}

output "alb_security_group_id" {
  description = "ID of the load balancer security group."
  value       = module.security_groups.alb_security_group_id
}

output "app_security_group_id" {
  description = "ID of the app tier security group."
  value       = module.security_groups.app_security_group_id
}

output "db_security_group_id" {
  description = "ID of the database security group."
  value       = module.security_groups.db_security_group_id
}

output "alb_dns_name" {
  description = "DNS name of the application load balancer. Open http://<this> to reach the app."
  value       = module.alb.alb_dns_name
}
