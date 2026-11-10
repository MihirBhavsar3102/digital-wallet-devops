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