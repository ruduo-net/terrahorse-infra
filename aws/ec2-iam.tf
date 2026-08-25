data "aws_iam_policy_document" "ec2-trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${local.account_name}-ec2"
  assume_role_policy = data.aws_iam_policy_document.ec2-trust.json
}

resource "aws_iam_role_policy_attachment" "ec2-ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ec2-ecr-read-only" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

data "aws_iam_policy_document" "ec2-volume" {
  statement {
    effect = "Allow"

    actions = [
      "ec2:AttachVolume",
      "ec2:DescribeVolumes",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ec2-volume" {
  name   = "${local.account_name}-ec2-volume"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.ec2-volume.json
}

data "aws_iam_policy_document" "ec2-parameters" {
  statement {
    effect = "Allow"

    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]

    resources = [
      "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/terrahorse/*",
    ]
  }

  statement {
    effect  = "Allow"
    actions = ["ssm:PutParameter"]

    resources = [
      "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/terrahorse/*/ec2/deploy/status",
    ]
  }

  statement {
    sid     = "PublishDevSaleorAppTokens"
    effect  = "Allow"
    actions = ["ssm:PutParameter"]

    resources = [
      "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/terrahorse/dev/ec2/SALEOR_CATALOG_APP_TOKEN",
      "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/terrahorse/dev/ec2/SALEOR_COMMERCE_APP_TOKEN",
    ]
  }

  statement {
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ec2-parameters" {
  name   = "${local.account_name}-ec2-parameters"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.ec2-parameters.json
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${local.account_name}-ec2"
  role = aws_iam_role.ec2.name
}
