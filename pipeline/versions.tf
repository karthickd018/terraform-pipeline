terraform {
  required_version = ">= 1.10.0" # 1.10+ is needed for the S3 lock file in backend.tf

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = local.region

  default_tags {
    tags = {
      ManagedBy = "terraform/pipeline"
    }
  }
}
