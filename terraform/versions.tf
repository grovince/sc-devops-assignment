terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }

  # 실제 운영 시 원격 상태 저장소 사용 권장
  # backend "s3" {
  #   bucket         = "supercent-tfstate"
  #   key            = "log-pipeline/terraform.tfstate"
  #   region         = "ap-northeast-2"
  #   dynamodb_table = "supercent-tflock"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
