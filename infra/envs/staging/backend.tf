terraform {
  backend "s3" {
    bucket       = "digital-wallet-shared-tfstate-455993205758"
    key          = "staging/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}