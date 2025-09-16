# Terraform configuration for Argus-Watch
# This file defines the complete infrastructure for detection, assessment, and remediation.

provider "aws" {
  region = "us-east-1" # Or your desired region
}

# =============================================================================
# SECTION 1: Detection & Assessment Infrastructure
# =============================================================================

# -----------------------------------------------------------------------------
# Data sources for packaging the Lambda functions
# -----------------------------------------------------------------------------

data "archive_file" "detection_engine_zip" {
  type        = "zip"
  source_dir  = "../src/detection_engine"
  output_path = "detection_engine.zip"
}

data "archive_file" "remediation_lambda_zip" {
  type        = "zip"
  source_dir  = "../src/remediation_handler"
  output_path = "remediation_handler.zip"
}

# -----------------------------------------------------------------------------
# SNS Topic and SQS Queue for Findings
# -----------------------------------------------------------------------------

resource "aws_sns_topic" "findings_topic" {
  name = "argus-watch-findings-topic"
}

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
# IAM Role and Lambda for the Detection Engine
# -----------------------------------------------------------------------------

resource "aws_iam_role" "detection_engine_role" {
  name = "argus-watch-detection-engine-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Effect    = "Allow",
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# In a production environment, this should be a custom, fine-grained policy
# with the exact read-only permissions required by the controls in controls.yaml.
# For this PoC refactor, we are using the AWS managed ReadOnlyAccess policy for simplicity.
resource "aws_iam_role_policy_attachment" "detection_engine_readonly_access" {
  role       = aws_iam_role.detection_engine_role.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "detection_engine_sns_publish" {
  name = "argus-watch-detection-engine-sns-publish"
  role = aws_iam_role.detection_engine_role.id
  policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [
      {
        Action   = "sns:Publish",
        Effect   = "Allow",
        Resource = aws_sns_topic.findings_topic.arn
      },
      {
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
        Effect   = "Allow",
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_lambda_function" "detection_engine_lambda" {
  function_name    = "argus-watch-detection-engine"
  role             = aws_iam_role.detection_engine_role.arn
  handler          = "app.lambda_handler"
  runtime          = "python3.12"
  timeout          = 300 # Increased timeout for potentially long-running scans
  filename         = data.archive_file.detection_engine_zip.output_path
  source_code_hash = data.archive_file.detection_engine_zip.output_base64sha256
  environment {
    variables = {
      SNS_TOPIC_ARN = aws_sns_topic.findings_topic.arn
      AWS_REGION    = "us-east-1"
    }
  }
}

# -----------------------------------------------------------------------------
# EventBridge Rule to trigger the detection Lambda
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "daily_trigger" {
  name                = "argus-watch-daily-scan"
  description         = "Triggers the Argus-Watch detection engine daily."
  schedule_expression = "rate(1 day)"
}

resource "aws_cloudwatch_event_target" "lambda_target" {
  rule      = aws_cloudwatch_event_rule.daily_trigger.name
  target_id = "TriggerDetectionEngine"
  arn       = aws_lambda_function.detection_engine_lambda.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.detection_engine_lambda.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_trigger.arn
}


# =============================================================================
# SECTION 2: Remediation Infrastructure
# =============================================================================

# -----------------------------------------------------------------------------
# IAM Role and Lambda for Remediation (remediation_handler)
# -----------------------------------------------------------------------------

resource "aws_iam_role" "remediation_lambda_exec_role" {
  name = "argus-watch-remediation-lambda-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Effect    = "Allow",
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "remediation_lambda_permissions" {
  name = "argus-watch-remediation-lambda-permissions"
  role = aws_iam_role.remediation_lambda_exec_role.id
  policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [
      {
        Action = [
          "rds:ModifyDBInstance",
          "s3:PutBucketEncryption"
        ],
        Effect   = "Allow",
        Resource = "*" # In production, this should be scoped down to specific resource ARNs if possible.
      },
      {
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
        Effect   = "Allow",
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_lambda_function" "remediation_handler_lambda" {
  function_name    = "argus-watch-remediation-handler"
  role             = aws_iam_role.remediation_lambda_exec_role.arn
  handler          = "app.lambda_handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.remediation_lambda_zip.output_path
  source_code_hash = data.archive_file.remediation_lambda_zip.output_base64sha256
}

# -----------------------------------------------------------------------------
# API Gateway for Triggering Remediation
# -----------------------------------------------------------------------------

resource "aws_api_gateway_rest_api" "remediation_api" {
  name        = "ArgusWatchRemediationAPI"
  description = "API to trigger Argus-Watch remediations"
}

resource "aws_api_gateway_resource" "remediate_resource" {
  rest_api_id = aws_api_gateway_rest_api.remediation_api.id
  parent_id   = aws_api_gateway_rest_api.remediation_api.root_resource_id
  path_part   = "remediate"
}

resource "aws_api_gateway_method" "remediate_method" {
  rest_api_id      = aws_api_gateway_rest_api.remediation_api.id
  resource_id      = aws_api_gateway_resource.remediate_resource.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = true
}

resource "aws_api_gateway_integration" "lambda_integration" {
  rest_api_id             = aws_api_gateway_rest_api.remediation_api.id
  resource_id             = aws_api_gateway_resource.remediate_resource.id
  http_method             = aws_api_gateway_method.remediate_method.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.remediation_handler_lambda.invoke_arn
}

resource "aws_lambda_permission" "allow_apigateway_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.remediation_handler_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.remediation_api.execution_arn}/*/${aws_api_gateway_method.remediate_method.http_method}${aws_api_gateway_resource.remediate_resource.path}"
}

resource "aws_api_gateway_deployment" "api_deployment" {
  rest_api_id = aws_api_gateway_rest_api.remediation_api.id
  triggers = {
    redeployment = sha1(jsonencode(aws_api_gateway_integration.lambda_integration))
  }
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "api_stage" {
  deployment_id = aws_api_gateway_deployment.api_deployment.id
  rest_api_id   = aws_api_gateway_rest_api.remediation_api.id
  stage_name    = "v1"
}

resource "aws_api_gateway_api_key" "remediation_api_key" {
  name    = "argus-watch-remediation-key"
  enabled = true
}

resource "aws_api_gateway_usage_plan" "remediation_usage_plan" {
  name = "argus-watch-remediation-usage-plan"
  api_stages {
    api_id = aws_api_gateway_rest_api.remediation_api.id
    stage  = aws_api_gateway_stage.api_stage.stage_name
  }
}

resource "aws_api_gateway_usage_plan_key" "main" {
  key_id        = aws_api_gateway_api_key.remediation_api_key.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.remediation_usage_plan.id
}
