###############################################################################
# aws-finops-guardian / infra
# Pin de versiones. Se fija Terraform y el provider AWS para que el plan de hoy
# sea el mismo plan de dentro de seis meses.
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

# AWS Budgets y Cost Explorer son servicios globales anclados a us-east-1.
# Este alias existe para eso; no crea recursos fuera de esa necesidad.
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
