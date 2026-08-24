###############################################################################
# aws-finops-guardian / infra
# Version pinning. Terraform and the AWS provider are pinned so that today's
# plan is the same plan six months from now.
###############################################################################

terraform {
  required_version = ">= 1.6.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
      Repo      = "aws-finops-guardian"
      Issue     = "IA-7"
    }
  }
}

# AWS Budgets and Cost Explorer are global services anchored to us-east-1.
# This alias exists for that reason only; it creates nothing beyond that need.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
      Repo      = "aws-finops-guardian"
      Issue     = "IA-7"
    }
  }
}
