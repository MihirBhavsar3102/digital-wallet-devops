terraform {
  # 1.11 is needed for write-only arguments, which keep the JWT secret out of state.
  required_version = "~> 1.11"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.72"
    }
  }
}
