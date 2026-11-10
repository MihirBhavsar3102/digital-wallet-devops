output "name_prefix" {
  description = "Prefix used for every resource name in this environment."
  value       = local.name_prefix
}
output "account_id" {
  description = "AWS account Terraform is running against."
  value       = data.aws_caller_identity.current.account_id
}