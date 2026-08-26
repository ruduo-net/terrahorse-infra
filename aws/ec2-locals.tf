locals {
  ec2_environments = {
    dev = {
      name                 = "${local.account_name}-dev-host"
      instance_type        = "t4g.small"
      availability_zone    = local.network.primary_az
      root_volume_size_gib = 20
      data_volume_size_gib = 2
      data_volume_type     = "gp3"
      compose_file         = "/opt/terrahorse/app/compose.ec2.yml"
      min_size             = 1
      desired_capacity     = 1
      max_size             = 1
    }
    prod = {
      name                 = "${local.account_name}-prod-host"
      instance_type        = "t4g.small"
      availability_zone    = local.network.primary_az
      root_volume_size_gib = 20
      data_volume_size_gib = 2
      data_volume_type     = "gp3"
      compose_file         = "/opt/terrahorse/app/compose.ec2.yml"
      min_size             = 0
      desired_capacity     = 0
      max_size             = 1
    }
  }
}

moved {
  from = aws_ebs_volume.data
  to   = aws_ebs_volume.data["dev"]
}

moved {
  from = aws_launch_template.ec2
  to   = aws_launch_template.ec2["dev"]
}

moved {
  from = aws_autoscaling_group.ec2
  to   = aws_autoscaling_group.ec2["dev"]
}

moved {
  from = aws_iam_role.ec2
  to   = aws_iam_role.ec2["dev"]
}

moved {
  from = aws_iam_role_policy_attachment.ec2-ssm
  to   = aws_iam_role_policy_attachment.ec2-ssm["dev"]
}

moved {
  from = aws_iam_role_policy_attachment.ec2-ecr-read-only
  to   = aws_iam_role_policy_attachment.ec2-ecr-read-only["dev"]
}

moved {
  from = aws_iam_role_policy.ec2-volume
  to   = aws_iam_role_policy.ec2-volume["dev"]
}

moved {
  from = aws_iam_role_policy.ec2-parameters
  to   = aws_iam_role_policy.ec2-parameters["dev"]
}

moved {
  from = aws_iam_instance_profile.ec2
  to   = aws_iam_instance_profile.ec2["dev"]
}
