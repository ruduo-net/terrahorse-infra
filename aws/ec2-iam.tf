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
  for_each = local.ec2_environments

  name               = "${local.account_name}-ec2-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.ec2-trust.json
}

resource "aws_iam_role_policy_attachment" "ec2-ssm" {
  for_each = local.ec2_environments

  role       = aws_iam_role.ec2[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ec2-ecr-read-only" {
  for_each = local.ec2_environments

  role       = aws_iam_role.ec2[each.key].name
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
  for_each = local.ec2_environments

  name   = "${local.account_name}-ec2-volume-${each.key}"
  role   = aws_iam_role.ec2[each.key].id
  policy = data.aws_iam_policy_document.ec2-volume.json
}

data "aws_iam_policy_document" "ec2-parameters" {
  for_each = local.ec2_environments

  statement {
    effect = "Allow"

    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]

    resources = [
      "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/terrahorse/${each.key}/*",
    ]
  }

  statement {
    effect  = "Allow"
    actions = ["ssm:PutParameter"]

    resources = [
      "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/terrahorse/${each.key}/ec2/deploy/status",
    ]
  }

  dynamic "statement" {
    for_each = each.key == "dev" ? [true] : []

    content {
      sid     = "PublishDevSaleorAppTokens"
      effect  = "Allow"
      actions = ["ssm:PutParameter"]

      resources = [
        "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/terrahorse/dev/ec2/SALEOR_CATALOG_APP_TOKEN",
        "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/terrahorse/dev/ec2/SALEOR_COMMERCE_APP_TOKEN",
      ]
    }
  }

  statement {
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ec2-parameters" {
  for_each = local.ec2_environments

  name   = "${local.account_name}-ec2-parameters-${each.key}"
  role   = aws_iam_role.ec2[each.key].id
  policy = data.aws_iam_policy_document.ec2-parameters[each.key].json
}

resource "aws_iam_instance_profile" "ec2" {
  for_each = local.ec2_environments

  name = "${local.account_name}-ec2-${each.key}"
  role = aws_iam_role.ec2[each.key].name
}
