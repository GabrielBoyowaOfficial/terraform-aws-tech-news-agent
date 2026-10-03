terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-2"
}

module "tech_news_agent" {
  source = "../../"

  name                = "tech-news"
  lambda_package_path = "${path.module}/lambda.zip"

  bedrock_model_id = "replace-with-bedrock-model-or-inference-profile-id"
  bedrock_model_arns = [
    "arn:aws:bedrock:us-east-2:123456789012:inference-profile/replace-me"
  ]

  news_sources = [
    "https://example.com/technology/rss",
    "https://example.org/security/feed"
  ]

  schedule_expression = "cron(30 8 * * ? *)"
  schedule_timezone   = "America/Toronto"

  tags = {
    Environment = "example"
    Project     = "tech-news-agent"
  }
}

output "lambda_name" {
  value = module.tech_news_agent.lambda_function_name
}

output "slack_secret_arn" {
  value = module.tech_news_agent.slack_secret_arn
}
