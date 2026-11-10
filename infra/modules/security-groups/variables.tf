variable "name_prefix" {
  type        = string
  description = "Prefix for every resource name, <project>-<environment>."
}
variable "vpc_id" {
  type        = string
  description = "VPC the security groups belong to."
}
variable "frontend_port" {
  type        = number
  description = "Port the frontend container listens on (nginx in docker-compose)."
  default     = 80
  validation {
    condition     = var.frontend_port >= 1 && var.frontend_port <= 65535
    error_message = "frontend_port must be between 1 and 65535."
  }
}
variable "backend_port" {
  type        = number
  description = "Port the NestJS backend listens on (PORT=8081 in docker-compose)."
  default     = 8081
  validation {
    condition     = var.backend_port >= 1 && var.backend_port <= 65535
    error_message = "backend_port must be between 1 and 65535."
  }
}
variable "db_port" {
  type        = number
  description = "PostgreSQL port."
  default     = 5432
}
