locals {
  lambda_zip = var.lambda_zip == null ? "${path.module}/lambdas/runner-binaries-syncer/runner-binaries-syncer.zip" : var.lambda_zip
  role_path  = var.role_path == null ? "/${var.environment}/" : var.role_path
}

resource "aws_lambda_function" "syncer" {
  filename         = local.lambda_zip
  source_code_hash = filebase64sha256(local.lambda_zip)
  function_name    = "${var.environment}-syncer"
  role             = aws_iam_role.syncer_lambda.arn
  handler          = "index.handler"
  runtime          = "nodejs12.x"
  timeout          = var.lambda_timeout

  environment {
    variables = {
      S3_BUCKET_NAME             = aws_s3_bucket.action_dist.id
      S3_OBJECT_KEY              = local.action_runner_distribution_object_key
      GITHUB_RUNNER_ARCHITECTURE = var.runner_architecture
    }
  }

  tags = var.tags
}

resource "aws_iam_role" "syncer_lambda" {
  name                 = "${var.environment}-action-syncer-lambda-role"
  assume_role_policy   = data.aws_iam_policy_document.lambda_assume_role_policy.json
  path                 = local.role_path
  permissions_boundary = var.role_permissions_boundary

  tags = var.tags
}

data "aws_iam_policy_document" "lambda_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "lambda_logging" {
  name = "${var.environment}-lambda-logging-policy-syncer"
  role = aws_iam_role.syncer_lambda.id

  policy = templatefile("${path.module}/policies/lambda-cloudwatch.json", {})
}

resource "aws_iam_role_policy" "syncer" {
  name = "${var.environment}-lambda-syncer-s3-policy"
  role = aws_iam_role.syncer_lambda.id

  policy = templatefile("${path.module}/policies/lambda-syncer.json", {
    s3_resource_arn = "${aws_s3_bucket.action_dist.arn}/${local.action_runner_distribution_object_key}"
  })
}

resource "aws_cloudwatch_event_rule" "syncer" {
  schedule_expression = var.lambda_schedule_expression
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "syncer" {
  rule = aws_cloudwatch_event_rule.syncer.name
  arn  = aws_lambda_function.syncer.arn
}

resource "aws_lambda_permission" "syncer" {
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.syncer.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.syncer.arn
}

###################################################################################
### Extra trigger to trigger from S3 to execute the lambda after first deployment
###################################################################################

resource "aws_s3_bucket_object" "trigger" {
  bucket = aws_s3_bucket.action_dist.id
  key    = "triggers/${aws_lambda_function.syncer.id}-trigger.json"
  source = "${path.module}/trigger.json"
  etag   = filemd5("${path.module}/trigger.json")

  depends_on = [aws_s3_bucket_notification.on_deploy]
}

resource "aws_s3_bucket_notification" "on_deploy" {
  bucket = aws_s3_bucket.action_dist.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.syncer.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "triggers/"
    filter_suffix       = ".json"
  }

  depends_on = [aws_lambda_permission.on_deploy]
}

resource "aws_lambda_permission" "on_deploy" {
  statement_id  = "AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.syncer.arn
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.action_dist.arn
}
