locals {
  repositories = toset(["frontend", "backend"])
}

resource "aws_ecr_repository" "this" {
  #checkov:skip=CKV_AWS_136:AES256 encryption (the ECR default) is free; a customer-managed KMS key would add cost and key management.
  for_each             = local.repositories
  name                 = "${var.name_prefix}-${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.force_delete # without it, destroying a repository that holds images fails

  image_scanning_configuration {
    scan_on_push = true
  }
  encryption_configuration {
    encryption_type = "AES256" # free; KMS would add cost and key management
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the last ${var.keep_last_images} images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = var.keep_last_images
      }
      action = { type = "expire" }
    }]
  })
}
