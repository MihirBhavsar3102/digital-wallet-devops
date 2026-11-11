output "instance_profile_name" {
  description = "Name of the EC2 instance profile to attach to the app instances."
  value       = aws_iam_instance_profile.ec2.name
}

output "ec2_role_arn" {
  description = "ARN of the EC2 instance role (SSM, CloudWatch agent, ECR pull, read access to the database secret)."
  value       = aws_iam_role.ec2.arn
}

output "github_deploy_role_arn" {
  description = "ARN of the role GitHub Actions assumes through OIDC to deploy to this environment."
  value       = aws_iam_role.github_deploy.arn
}
