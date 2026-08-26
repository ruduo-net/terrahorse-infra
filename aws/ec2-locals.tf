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
      database_owned_runtime_parameters = toset([
        "SALEOR_CATALOG_APP_TOKEN",
        "SALEOR_COMMERCE_APP_TOKEN",
      ])
    }
    prod = {
      name                              = "${local.account_name}-prod-host"
      instance_type                     = "t4g.small"
      availability_zone                 = local.network.primary_az
      root_volume_size_gib              = 20
      data_volume_size_gib              = 2
      data_volume_type                  = "gp3"
      compose_file                      = "/opt/terrahorse/app/compose.ec2.yml"
      min_size                          = 0
      desired_capacity                  = 0
      max_size                          = 1
      database_owned_runtime_parameters = toset([])
    }
  }

  database_owned_runtime_parameter_arns = {
    for environment, config in local.ec2_environments : environment => [
      for name in config.database_owned_runtime_parameters :
      "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/terrahorse/${environment}/ec2/${name}"
    ]
  }
}
