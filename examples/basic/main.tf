terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

variable "aws_region" {
  description = "AWS region in which to deploy the example."
  type        = string
}

variable "bedrock_model_id" {
  description = "Bedrock model ID or inference profile ID to invoke."
  type        = string
}

variable "bedrock_model_arns" {
  description = "Bedrock model and/or inference profile ARNs permitted for invocation."
  type        = list(string)
}

variable "content_sources" {
  description = "RSS or Atom sources to include in the digest."
  type = list(object({
    name = string
    url  = string
    kind = optional(string, "feed")
  }))
}

provider "aws" {
  region = var.aws_region
}

module "tech_news_agent" {
  source = "../../"

  name = "tech-news"

  bedrock_model_id   = var.bedrock_model_id
  bedrock_model_arns = var.bedrock_model_arns
  content_sources    = var.content_sources

  # Uses the bundled reference Lambda implementation by default.
  # Override lambda_package_path if you want to supply your own ZIP.

  schedule_expression = "cron(30 8 * * ? *)"
  schedule_timezone   = "Etc/UTC"

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
