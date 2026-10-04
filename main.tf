data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  function_name = substr("${var.name}-agent", 0, 64)
  table_name    = substr("${var.name}-dedupe", 0, 255)
  secret_name   = coalesce(var.slack_secret_name, "${var.name}/slack-webhook")

  slack_secret_arn = var.create_slack_secret ? aws_secretsmanager_secret.slack_webhook[0].arn : coalesce(
    var.slack_secret_arn,
    "arn:${data.aws_partition.current.partition}:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:invalid"
  )

  bundled_lambda_zip = "${path.root}/.terraform/${local.function_name}.zip"
  lambda_package_path = var.lambda_package_path != null ? var.lambda_package_path : data.archive_file.lambda[0].output_path
  lambda_source_hash = var.lambda_package_path != null ? filebase64sha256(var.lambda_package_path) : data.archive_file.lambda[0].output_base64sha256

  common_tags = merge(
    {
      ManagedBy = "Terraform"
      Component = "tech-news-ai-agent"
    },
    var.tags
  )
}

data "archive_file" "lambda" {
  count = var.lambda_package_path == null ? 1 : 0

  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = local.bundled_lambda_zip
}

resource "aws_dynamodb_table" "dedupe" {
  name         = local.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "article_id"

  attribute {
    name = "article_id"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = var.enable_dynamodb_pitr
  }

  server_side_encryption {
    enabled = true
  }

  tags = local.common_tags
}

resource "aws_secretsmanager_secret" "slack_webhook" {
  count = var.create_slack_secret ? 1 : 0

  name                    = local.secret_name
  description             = "Slack webhook used by the tech news AI agent"
  recovery_window_in_days = var.secret_recovery_window_days
  kms_key_id              = var.secret_kms_key_arn

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.cloudwatch_logs_kms_key_arn

  tags = local.common_tags
}

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "lambda" {
  name               = substr("${var.name}-lambda-role", 0, 64)
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "lambda" {
  statement {
    sid    = "WriteLambdaLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["${aws_cloudwatch_log_group.lambda.arn}:*"]
  }

  statement {
    sid     = "ReadSlackWebhookSecret"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      local.slack_secret_arn
    ]
  }

  statement {
    sid    = "UseDedupeTable"
    effect = "Allow"
    actions = [
      "dynamodb:BatchGetItem",
      "dynamodb:BatchWriteItem"
    ]
    resources = [aws_dynamodb_table.dedupe.arn]
  }

  statement {
    sid     = "InvokeBedrockModel"
    effect  = "Allow"
    actions = ["bedrock:InvokeModel"]
    resources = var.bedrock_model_arns
  }

  dynamic "statement" {
    for_each = var.secret_kms_key_arn != null ? [1] : []

    content {
      sid       = "DecryptSlackSecret"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [var.secret_kms_key_arn]
    }
  }

  dynamic "statement" {
    for_each = var.additional_lambda_policy_statements
    iterator = extra

    content {
      sid       = "AdditionalPermissions${extra.key}"
      effect    = "Allow"
      actions   = extra.value.actions
      resources = extra.value.resources
    }
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = substr("${var.name}-lambda-policy", 0, 128)
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}

resource "aws_lambda_function" "this" {
  function_name = local.function_name
  description   = var.lambda_description
  role          = aws_iam_role.lambda.arn

  filename         = local.lambda_package_path
  source_code_hash = local.lambda_source_hash
  handler          = var.lambda_handler
  runtime          = var.lambda_runtime
  architectures    = [var.lambda_architecture]

  memory_size = var.lambda_memory_size
  timeout     = var.lambda_timeout_seconds

  reserved_concurrent_executions = var.reserved_concurrent_executions

  environment {
    variables = merge(
      {
        TABLE_NAME           = aws_dynamodb_table.dedupe.name
        SLACK_SECRET_ID      = local.slack_secret_arn
        MODEL_ID             = var.bedrock_model_id
        CONTENT_SOURCES_JSON = jsonencode(var.content_sources)
        INTERESTS            = var.interests
        TOP_N                = tostring(var.top_n)
        LOOKBACK_HOURS       = tostring(var.lookback_hours)
        TTL_DAYS             = tostring(var.dedupe_ttl_days)
        DIGEST_TITLE         = var.digest_title
        LOG_LEVEL            = var.log_level
      },
      var.lambda_environment_variables
    )
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy.lambda
  ]

  lifecycle {
    precondition {
      condition     = var.create_slack_secret || (var.slack_secret_arn != null && try(length(var.slack_secret_arn), 0) > 0)
      error_message = "slack_secret_arn must be provided when create_slack_secret is false."
    }
  }

  tags = local.common_tags
}

data "aws_iam_policy_document" "scheduler_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "scheduler" {
  name               = substr("${var.name}-scheduler-role", 0, 64)
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume_role.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    sid       = "InvokeTechNewsAgent"
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.this.arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = substr("${var.name}-scheduler-policy", 0, 128)
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

resource "aws_scheduler_schedule" "this" {
  name                         = substr("${var.name}-schedule", 0, 64)
  description                  = var.schedule_description
  schedule_expression          = var.schedule_expression
  schedule_expression_timezone = var.schedule_timezone
  state                        = var.schedule_enabled ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.this.arn
    role_arn = aws_iam_role.scheduler.arn
    input = jsonencode({
      source = "eventbridge-scheduler"
    })

    retry_policy {
      maximum_event_age_in_seconds = var.schedule_max_event_age_seconds
      maximum_retry_attempts       = var.schedule_max_retry_attempts
    }
  }

  depends_on = [aws_iam_role_policy.scheduler]
}
