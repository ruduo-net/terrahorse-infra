resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  thumbprint_list = [
    "1b511abead59c6ce207077c0bf0e0043b1382612",
  ]
}

data "aws_iam_policy_document" "github-actions-trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.github_oidc_subject_prefix}:ref:refs/heads/*"]
    }
  }
}

data "aws_iam_policy_document" "github-actions-deploy-trust" {
  for_each = local.ec2_environments

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.github_oidc_subject_prefix}:environment:aws-${each.key}"]
    }
  }
}

resource "aws_iam_role" "github-actions" {
  name               = "${local.account_name}-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github-actions-trust.json
}

data "aws_iam_policy_document" "github-actions" {
  statement {
    sid       = "EcrPush"
    effect    = "Allow"
    resources = [aws_ecr_repository.terrahorse.arn, aws_ecr_repository.terrahorse-release.arn]

    actions = [
      "ecr:DescribeImages",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
  }

  statement {
    sid       = "EcrLogin"
    effect    = "Allow"
    resources = ["*"]
    actions   = ["ecr:GetAuthorizationToken"]
  }
}

data "aws_iam_policy_document" "github-actions-deploy" {
  for_each = local.ec2_environments

  statement {
    sid       = "Ec2FindDeploymentHost"
    effect    = "Allow"
    resources = ["*"]
    actions   = ["ec2:DescribeInstances"]
  }

  statement {
    sid       = "SsmDeployDocument"
    effect    = "Allow"
    resources = ["arn:aws:ssm:${data.aws_region.current.region}::document/AWS-RunShellScript"]
    actions   = ["ssm:SendCommand"]
  }

  statement {
    sid       = "SsmDeployToTerraHorseHost"
    effect    = "Allow"
    resources = ["arn:aws:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:instance/*"]
    actions   = ["ssm:SendCommand"]

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Name"
      values   = [local.ec2_environments[each.key].name]
    }
  }

  statement {
    sid       = "SsmCommandStatus"
    effect    = "Allow"
    resources = ["*"]
    actions   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
  }

  statement {
    sid       = "Ec2DeploymentStatus"
    effect    = "Allow"
    resources = ["arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/terrahorse/${each.key}/ec2/deploy/status"]
    actions   = ["ssm:GetParameter"]
  }

  dynamic "statement" {
    for_each = length(local.database_owned_runtime_parameter_arns[each.key]) == 0 ? [] : [local.database_owned_runtime_parameter_arns[each.key]]

    content {
      sid       = "Ec2DatabaseOwnedRuntimeParameters"
      resources = statement.value
      actions   = ["ssm:GetParameter"]
    }
  }

  statement {
    sid       = "Ec2RuntimeParameterSync"
    effect    = "Allow"
    resources = ["arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/terrahorse/${each.key}/ec2/*"]
    actions   = ["ssm:PutParameter"]
  }

  dynamic "statement" {
    for_each = each.key == "dev" ? [true] : []

    content {
      sid    = "ResetProductEditorCredentials"
      effect = "Allow"
      resources = [
        "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/terrahorse/dev/ec2/SALEOR_EDITOR_APP_ID",
        "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/terrahorse/dev/ec2/SALEOR_EDITOR_APP_TOKEN"
      ]
      actions = ["ssm:DeleteParameters"]
    }
  }

  dynamic "statement" {
    for_each = length(local.database_owned_runtime_parameter_arns[each.key]) == 0 ? [] : [local.database_owned_runtime_parameter_arns[each.key]]

    content {
      sid       = "ProtectDatabaseOwnedRuntimeParameters"
      effect    = "Deny"
      resources = statement.value
      actions   = ["ssm:PutParameter"]
    }
  }
}

resource "aws_iam_policy" "github-actions" {
  name   = "${local.account_name}-github-actions"
  policy = data.aws_iam_policy_document.github-actions.json
}

resource "aws_iam_role_policy_attachment" "github-actions" {
  role       = aws_iam_role.github-actions.name
  policy_arn = aws_iam_policy.github-actions.arn
}

resource "aws_iam_role" "github-actions-deploy" {
  for_each           = local.ec2_environments
  name               = "${local.account_name}-github-actions-deploy-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.github-actions-deploy-trust[each.key].json
}

resource "aws_iam_role_policy" "github-actions-deploy" {
  for_each = local.ec2_environments
  name     = "${local.account_name}-github-actions-deploy-${each.key}"
  role     = aws_iam_role.github-actions-deploy[each.key].id
  policy   = data.aws_iam_policy_document.github-actions-deploy[each.key].json
}
