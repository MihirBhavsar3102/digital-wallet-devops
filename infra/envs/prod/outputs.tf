# This file is identical in every environment. No output ever carries a secret value: the secret
# outputs are ARNs, which only say where a secret is stored.

output "name_prefix" {
  description = "Prefix used for every resource name in this environment."
  value       = local.name_prefix
}

output "account_id" {
  description = "AWS account Terraform is running against."
  value       = data.aws_caller_identity.current.account_id
}

# ---------- network ----------
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

# ---------- application ----------
output "alb_dns_name" {
  description = "DNS name of the application load balancer. Open http://<this> to reach the app."
  value       = module.alb.alb_dns_name
}

output "asg_name" {
  description = "Name of the Auto Scaling group running the app instances."
  value       = module.compute.autoscaling_group_name
}

output "ecr_repository_urls" {
  description = "ECR repository URLs by name (frontend, backend). The pipeline pushes images here."
  value       = module.ecr.repository_urls
}

output "github_deploy_role_arn" {
  description = "ARN of the role GitHub Actions assumes through OIDC to deploy to this environment."
  value       = module.iam.github_deploy_role_arn
}

# ---------- database ----------
output "db_endpoint" {
  description = "DNS name of the PostgreSQL instance. Only reachable from the app tier."
  value       = module.rds.address
}

output "db_master_secret_arn" {
  description = "ARN of the Secrets Manager secret with the database master credentials (created and rotated by RDS). This is an ARN, not the password."
  value       = module.rds.master_user_secret_arn
}

output "jwt_secret_arn" {
  description = "ARN of the Secrets Manager secret with the JWT signing key. This is an ARN, not the key."
  value       = module.secrets.jwt_secret_arn
}

# ---------- logs ----------
output "db_log_group_names" {
  description = "CloudWatch log groups receiving the exported PostgreSQL logs, by log type."
  value       = module.rds.log_group_names
}

output "app_log_group_names" {
  description = "CloudWatch log groups for the application and the hosts, by kind (backend, frontend, syslog, auth)."
  value       = module.monitoring.log_group_names
}

# ---------- dashboards, saved queries and alarms ----------
output "dashboard_names" {
  description = "Names of the two CloudWatch dashboards, by kind (infrastructure, application)."
  value       = module.observability.dashboard_names
}

output "dashboard_urls" {
  description = "Console links to the two dashboards, by kind."
  value       = module.observability.dashboard_urls
}

output "alarm_names" {
  description = "Names of the CloudWatch alarms of this environment."
  value       = module.observability.alarm_names
}

output "alarm_topic_arn" {
  description = "ARN of the SNS topic the alarms notify (created in infra/bootstrap)."
  value       = data.aws_sns_topic.alarms.arn
}

output "saved_query_names" {
  description = "Names of the saved Logs Insights queries."
  value       = module.observability.saved_query_names
}

output "alb_access_logs_bucket" {
  description = "S3 bucket receiving the load balancer access logs."
  value       = module.alb.access_logs_bucket_name
}
