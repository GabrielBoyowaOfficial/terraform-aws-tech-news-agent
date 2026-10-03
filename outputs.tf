output "lambda_function_name" {
  description = "Name of the tech news Lambda function."
  value       = aws_lambda_function.this.function_name
}

output "lambda_function_arn" {
  description = "ARN of the tech news Lambda function."
  value       = aws_lambda_function.this.arn
}

output "lambda_role_arn" {
  description = "IAM role used by the Lambda function."
  value       = aws_iam_role.lambda.arn
}

output "dedupe_table_name" {
  description = "DynamoDB table used for article deduplication."
  value       = aws_dynamodb_table.dedupe.name
}

output "dedupe_table_arn" {
  description = "ARN of the DynamoDB deduplication table."
  value       = aws_dynamodb_table.dedupe.arn
}

output "slack_secret_arn" {
  description = "Secrets Manager ARN read by the Lambda function."
  value       = local.slack_secret_arn
}

output "schedule_name" {
  description = "EventBridge Scheduler schedule name."
  value       = aws_scheduler_schedule.this.name
}

output "cloudwatch_log_group_name" {
  description = "CloudWatch log group for the Lambda function."
  value       = aws_cloudwatch_log_group.lambda.name
}
