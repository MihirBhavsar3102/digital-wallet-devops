output "address" {
  description = "DNS name of the database instance (without the port)."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "Port the database listens on."
  value       = aws_db_instance.this.port
}

output "db_name" {
  description = "Name of the initial database."
  value       = aws_db_instance.this.db_name
}

output "identifier" {
  description = "Identifier of the database instance."
  value       = aws_db_instance.this.identifier
}

output "instance_arn" {
  description = "ARN of the database instance."
  value       = aws_db_instance.this.arn
}

output "master_user_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the master user credentials, created and rotated by RDS."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}
