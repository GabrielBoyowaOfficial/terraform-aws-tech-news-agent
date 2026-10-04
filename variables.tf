variable "name" {
  description = "Base name used for resources created by this module."
  type        = string
  default     = "tech-news"
}

variable "lambda_package_path" {
  description = "Optional path to a pre-built Lambda ZIP. When null, the bundled src directory is packaged automatically."
  type        = string
  default     = null
}

variable "lambda_handler" {
  description = "Lambda handler entry point."
  type        = string
  default     = "handler.lambda_handler"
}

variable "lambda_runtime" {
  description = "Lambda runtime."
  type        = string
  default     = "python3.13"
}

variable "lambda_architecture" {
  description = "Lambda CPU architecture."
  type        = string
  default     = "arm64"

  validation {
    condition     = contains(["arm64", "x86_64"], var.lambda_architecture)
    error_message = "lambda_architecture must be arm64 or x86_64."
  }
}

variable "lambda_description" {
  description = "Description assigned to the Lambda function."
  type        = string
  default     = "Curates and summarizes technology news and publishes a digest to Slack."
}

variable "lambda_memory_size" {
  description = "Lambda memory in MB."
  type        = number
  default     = 256
}

variable "lambda_timeout_seconds" {
  description = "Lambda timeout in seconds."
  type        = number
  default     = 120
}

variable "reserved_concurrent_executions" {
  description = "Reserved Lambda concurrency. Use -1 for unreserved concurrency."
  type        = number
  default     = 1
}

variable "lambda_environment_variables" {
  description = "Additional Lambda environment variables."
  type        = map(string)
  default     = {}
}

variable "content_sources" {
  description = "RSS or Atom sources consumed by the reference Lambda. Use only sources you are permitted to consume."
  type = list(object({
    name = string
    url  = string
    kind = optional(string, "feed")
  }))
  default = []

  validation {
    condition = alltrue([
      for source in var.content_sources :
      length(trimspace(source.name)) > 0 && can(regex("^https://", source.url))
    ])
    error_message = "Each content source must have a non-empty name and an HTTPS URL."
  }
}

variable "interests" {
  description = "High-level topics used by the model when ranking and curating candidate stories."
  type        = string
  default     = "cloud computing, cybersecurity, software engineering, artificial intelligence, and emerging technology"
}

variable "top_n" {
  description = "Maximum number of stories the model should select for a digest."
  type        = number
  default     = 10

  validation {
    condition     = var.top_n >= 1 && var.top_n <= 25
    error_message = "top_n must be between 1 and 25."
  }
}

variable "lookback_hours" {
  description = "Only consider feed items published within this many hours of execution."
  type        = number
  default     = 24

  validation {
    condition     = var.lookback_hours >= 1 && var.lookback_hours <= 168
    error_message = "lookback_hours must be between 1 and 168."
  }
}

variable "dedupe_ttl_days" {
  description = "How many days article fingerprints remain in DynamoDB before TTL expiry."
  type        = number
  default     = 14

  validation {
    condition     = var.dedupe_ttl_days >= 1
    error_message = "dedupe_ttl_days must be at least 1."
  }
}

variable "digest_title" {
  description = "Title used at the top of the Slack digest."
  type        = string
  default     = "Tech brief"
}

variable "bedrock_model_id" {
  description = "Bedrock model ID or inference profile ID used by the Lambda code."
  type        = string
}

variable "bedrock_model_arns" {
  description = "Exact Bedrock model and/or inference profile ARNs Lambda is allowed to invoke."
  type        = list(string)

  validation {
    condition     = length(var.bedrock_model_arns) > 0
    error_message = "Provide at least one Bedrock model or inference profile ARN."
  }
}

variable "create_slack_secret" {
  description = "Create Secrets Manager metadata for the Slack webhook. The secret value is intentionally not managed by Terraform."
  type        = bool
  default     = true
}

variable "slack_secret_name" {
  description = "Optional Secrets Manager secret name when create_slack_secret is true."
  type        = string
  default     = null
}

variable "slack_secret_arn" {
  description = "Existing Slack webhook secret ARN when create_slack_secret is false."
  type        = string
  default     = null
}

variable "secret_kms_key_arn" {
  description = "Optional customer-managed KMS key ARN used by the Slack secret."
  type        = string
  default     = null
}

variable "secret_recovery_window_days" {
  description = "Secrets Manager recovery window in days."
  type        = number
  default     = 7
}

variable "enable_dynamodb_pitr" {
  description = "Enable DynamoDB point-in-time recovery. Usually unnecessary for an ephemeral dedupe table."
  type        = bool
  default     = false
}

variable "schedule_expression" {
  description = "EventBridge Scheduler expression. Default runs every day at 08:30 in schedule_timezone."
  type        = string
  default     = "cron(30 8 * * ? *)"
}

variable "schedule_timezone" {
  description = "IANA timezone used to evaluate the schedule."
  type        = string
  default     = "Etc/UTC"
}

variable "schedule_enabled" {
  description = "Whether the EventBridge Scheduler schedule is enabled."
  type        = bool
  default     = true
}

variable "schedule_description" {
  description = "Description assigned to the EventBridge Scheduler schedule."
  type        = string
  default     = "Runs the tech news AI agent on a recurring schedule."
}

variable "schedule_max_event_age_seconds" {
  description = "Maximum age of an EventBridge Scheduler event before it is discarded."
  type        = number
  default     = 3600
}

variable "schedule_max_retry_attempts" {
  description = "Maximum EventBridge Scheduler retry attempts for a failed invocation."
  type        = number
  default     = 2
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention period."
  type        = number
  default     = 30
}

variable "cloudwatch_logs_kms_key_arn" {
  description = "Optional KMS key ARN for CloudWatch Logs encryption."
  type        = string
  default     = null
}

variable "log_level" {
  description = "Application log level passed to the Lambda function."
  type        = string
  default     = "INFO"

  validation {
    condition     = contains(["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"], upper(var.log_level))
    error_message = "log_level must be DEBUG, INFO, WARNING, ERROR, or CRITICAL."
  }
}

variable "additional_lambda_policy_statements" {
  description = "Optional additional IAM permissions required by custom Lambda code."
  type = list(object({
    actions   = list(string)
    resources = list(string)
  }))
  default = []
}

variable "tags" {
  description = "Tags applied to resources created by the module."
  type        = map(string)
  default     = {}
}
