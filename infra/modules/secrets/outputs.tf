output "jwt_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the JWT signing key. This is an ARN, never the key itself."
  value       = aws_secretsmanager_secret.jwt.arn
}

output "jwt_secret_name" {
  description = "Name of the Secrets Manager secret holding the JWT signing key."
  value       = aws_secretsmanager_secret.jwt.name
}
