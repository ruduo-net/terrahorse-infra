locals {
  dev_invoice_host_role = aws_iam_role.ec2["dev"]
  invoice_storage_by_environment = {
    for environment, prefix in {
      dev  = "test-invoices/v1/"
      prod = "invoices/v1/"
      } : environment => {
      bucket = "${local.account_name}-invoice-${environment}-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.region}"
      prefix = prefix
    }
  }
  invoice_object_prefix_arns = {
    for environment, config in local.invoice_storage_by_environment :
    environment => "arn:aws:s3:::${config.bucket}/${config.prefix}"
  }
}

resource "aws_s3_bucket" "invoice-dev" {
  bucket = local.invoice_storage_by_environment.dev.bucket

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Environment = "dev"
    Purpose     = "test-invoices"
  }
}

resource "aws_s3_bucket_public_access_block" "invoice-dev" {
  bucket = aws_s3_bucket.invoice-dev.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "invoice-dev" {
  bucket = aws_s3_bucket.invoice-dev.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "invoice-dev" {
  bucket = aws_s3_bucket.invoice-dev.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "invoice-dev" {
  bucket = aws_s3_bucket.invoice-dev.id

  versioning_configuration {
    status = "Enabled"
  }
}

data "aws_iam_policy_document" "invoice-dev-bucket" {
  statement {
    sid     = "RequireTLS"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.invoice-dev.arn,
      "${aws_s3_bucket.invoice-dev.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "invoice-dev" {
  bucket = aws_s3_bucket.invoice-dev.id
  policy = data.aws_iam_policy_document.invoice-dev-bucket.json
}

data "aws_iam_policy_document" "invoice-dev-trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [local.dev_invoice_host_role.arn]
    }
  }
}

resource "aws_iam_role" "invoice-dev" {
  name               = "${local.account_name}-invoice-dev"
  assume_role_policy = data.aws_iam_policy_document.invoice-dev-trust.json
}

data "aws_iam_policy_document" "invoice-objects" {
  for_each = local.invoice_storage_by_environment

  statement {
    sid       = "ReadInvoices"
    actions   = ["s3:GetObject"]
    resources = ["${local.invoice_object_prefix_arns[each.key]}*"]
  }

  statement {
    sid       = "CreateInvoicesOnce"
    actions   = ["s3:PutObject"]
    resources = ["${local.invoice_object_prefix_arns[each.key]}*"]

    condition {
      test     = "StringEquals"
      variable = "s3:if-none-match"
      values   = ["*"]
    }
  }

  statement {
    sid       = "AdvanceInvoiceSeriesHead"
    actions   = ["s3:PutObject"]
    resources = ["${local.invoice_object_prefix_arns[each.key]}invoice-series/head.json"]

    condition {
      test     = "Null"
      variable = "s3:if-match"
      values   = ["false"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "s3:if-match"
      values   = ["*"]
    }
  }
}

resource "aws_iam_role_policy" "invoice-dev-objects" {
  name   = "${local.account_name}-invoice-dev-objects"
  role   = aws_iam_role.invoice-dev.name
  policy = data.aws_iam_policy_document.invoice-objects["dev"].json
}

data "aws_iam_policy_document" "ec2-assume-invoice-dev" {
  statement {
    actions   = ["sts:AssumeRole"]
    resources = [aws_iam_role.invoice-dev.arn]
  }
}

resource "aws_iam_role_policy" "ec2-assume-invoice-dev" {
  name   = "${local.account_name}-assume-invoice-dev"
  role   = local.dev_invoice_host_role.name
  policy = data.aws_iam_policy_document.ec2-assume-invoice-dev.json
}

resource "aws_ssm_document" "invoice-dev-credentials" {
  name            = "${local.account_name}-invoice-dev-credentials"
  document_type   = "Command"
  document_format = "JSON"
  target_type     = "/AWS::EC2::Instance"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Install short-lived S3 role credential rotation on the TerraHorse dev host"
    mainSteps = [{
      action       = "aws:runShellScript"
      name         = "installInvoiceCredentialsTimer"
      precondition = { StringEquals = ["platformType", "Linux"] }
      inputs = {
        timeoutSeconds = "90"
        runCommand = [templatefile("${path.module}/invoice/install-dev-credentials.sh.tftpl", {
          account_id     = data.aws_caller_identity.current.account_id
          region         = data.aws_region.current.region
          host_role_name = local.dev_invoice_host_role.name
          role_arn       = aws_iam_role.invoice-dev.arn
          refresh_script = file("${path.module}/invoice/refresh-dev-credentials.sh")
        })]
      }
    }]
  })
}

resource "aws_ssm_association" "invoice-dev-credentials" {
  association_name = "${local.account_name}-invoice-dev-credentials"
  name             = aws_ssm_document.invoice-dev-credentials.name
  document_version = aws_ssm_document.invoice-dev-credentials.latest_version

  targets {
    key    = "tag:Name"
    values = [local.ec2_environments.dev.name]
  }

  depends_on = [
    aws_iam_role_policy.ec2-assume-invoice-dev,
    aws_iam_role_policy.invoice-dev-objects,
  ]
}
