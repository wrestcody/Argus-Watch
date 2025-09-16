# Terraform configuration for Argus-Watch PoC
# This file defines the necessary AWS resources to deploy the RDS backup checker.

provider "aws" {
  region = "us-east-1" # Or your desired region
}

# -----------------------------------------------------------------------------
# Data sources for packaging the Lambda function
# -----------------------------------------------------------------------------

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "../src/check_rds_backups"
  output_path = "check_rds_backups.zip"
}

# -----------------------------------------------------------------------------
# SNS Topic for Findings
# -----------------------------------------------------------------------------

resource "aws_sns_topic" "findings_topic" {
  name = "argus-watch-findings-topic"
}

# -----------------------------------------------------------------------------
# SQS Queue for Decoupling
# -----------------------------------------------------------------------------

resource "aws_sqs_queue" "findings_queue" {
  name = "argus-watch-findings-queue"
}

resource "aws_sns_topic_subscription" "findings_queue_subscription" {
  topic_arn = aws_sns_topic.findings_topic.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.findings_queue.arn
}

resource "aws_sqs_queue_policy" "findings_queue_policy" {
  queue_url = aws_sqs_queue.findings_queue.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = {
        Service = "sns.amazonaws.com"
      },
      Action    = "sqs:SendMessage",
      Resource  = aws_sqs_queue.findings_queue.arn,
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = aws_sns_topic.findings_topic.arn
        }
      }
    }]
  })
}


# -----------------------------------------------------------------------------
# IAM Role and Policy for the Lambda Function
# -----------------------------------------------------------------------------

resource "aws_iam_role" "lambda_exec_role" {
  name = "argus-watch-lambda-role"

  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Effect    = "Allow",
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_permissions" {
  name = "argus-watch-lambda-permissions"
  role = aws_iam_role.lambda_exec_role.id

  policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [
      {
        Action = [
          "rds:DescribeDBInstances"
        ],
        Effect   = "Allow",
        Resource = "*"
      },
      {
        Action   = "sns:Publish",
        Effect   = "Allow",
        Resource = aws_sns_topic.findings_topic.arn
      },
      {
        # Basic permissions for Lambda logging
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Effect   = "Allow",
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# AWS Lambda Function
# -----------------------------------------------------------------------------

resource "aws_lambda_function" "check_rds_backups_lambda" {
  function_name = "argus-watch-check-rds-backups"
  role          = aws_iam_role.lambda_exec_role.arn
  handler       = "app.lambda_handler"
  runtime       = "python3.12"
  timeout       = 60

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      SNS_TOPIC_ARN = aws_sns_topic.findings_topic.arn
      AWS_REGION    = "us-east-1" # Ensure this matches the provider region
    }
  }

  depends_on = [
    aws_iam_role_policy.lambda_permissions,
    aws_sns_topic.findings_topic
  ]
}

# -----------------------------------------------------------------------------
# EventBridge (CloudWatch Events) Rule to trigger the Lambda
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "daily_trigger" {
  name                = "argus-watch-daily-rds-check"
  description         = "Triggers the Argus-Watch RDS backup check daily."
  schedule_expression = "rate(1 day)" # Runs once every day
}

resource "aws_cloudwatch_event_target" "lambda_target" {
  rule      = aws_cloudwatch_event_rule.daily_trigger.name
  target_id = "TriggerLambda"
  arn       = aws_lambda_function.check_rds_backups_lambda.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.check_rds_backups_lambda.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_trigger.arn
}
