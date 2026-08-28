locals {
  github_owner                     = "ruduo-net"
  github_owner_id                  = 166593019
  github_repository                = "terrahorse-web"
  github_repository_id             = 1297533275
  github_infrastructure_repository = "terrahorse-infra"
  github_oidc_subject_prefix       = "repo:${local.github_owner}@${local.github_owner_id}/${local.github_repository}@${local.github_repository_id}"

  github_repository_variables = {
    AWS_BUILD_ROLE_ARN  = aws_iam_role.github-actions.arn
    PROD_DEPLOY_ENABLED = "false"
  }

  github_environment_variables = {
    "aws-dev" = {
      NUXT_PUBLIC_SITE_URL                   = "https://dev.terrahorse.lt"
      NUXT_PUBLIC_I18N_BASE_URL              = "https://dev.terrahorse.lt"
      SALEOR_API_URL                         = "https://api:8443/graphql/"
      SALEOR_CHANNEL                         = "terrahorse-eur"
      SALEOR_STOCK_AVAILABILITY_MODE         = "channel-aggregate"
      SALEOR_STOCK_COUNTRY_CODE              = "LT"
      LOG_LEVEL                              = "info"
      SALEOR_PAYMENT_GATEWAY_ID              = "terrahorse.local-commerce"
      SALEOR_PAYMENT_APP_ID                  = "QXBwOjI="
      PAYMENT_CALLBACK_ORIGIN                = "https://dev.terrahorse.lt"
      MONTONIO_SHIPPING_API_URL              = "https://sandbox-shipping.montonio.com"
      MONTONIO_PAYMENTS_API_URL              = "https://sandbox-stargate.montonio.com/api"
      SALEOR_VENIPAK_PARCEL_LOCKER_METHOD_ID = "U2hpcHBpbmdNZXRob2Q6Mg=="
      SALEOR_VENIPAK_COURIER_METHOD_ID       = "U2hpcHBpbmdNZXRob2Q6Mw=="
      SALEOR_PUBLIC_URL                      = "https://api-dev.terrahorse.lt"
      SALEOR_DASHBOARD_URL                   = "https://dashboard-dev.terrahorse.lt/"
      SALEOR_DASHBOARD_API_URL               = "https://api-dev.terrahorse.lt/graphql/"
      STOREFRONT_PUBLIC_URL                  = "https://dev.terrahorse.lt"
      SALEOR_ALLOWED_HOSTS                   = "localhost,127.0.0.1,api,dev.terrahorse.lt,api-dev.terrahorse.lt"
      SALEOR_ALLOWED_CLIENT_HOSTS            = "localhost,127.0.0.1,dev.terrahorse.lt,api-dev.terrahorse.lt,dashboard-dev.terrahorse.lt"
      ORDER_EMAIL_SMTP_HOST                  = "smtp.purelymail.com"
      ORDER_EMAIL_SMTP_PORT                  = "465"
      ORDER_EMAIL_SMTP_SECURITY              = "tls"
      ORDER_EMAIL_SMTP_USERNAME              = "info@terrahorse.lt"
      ORDER_EMAIL_FROM_ADDRESS               = "info@terrahorse.lt"
      ORDER_EMAIL_FROM_NAME                  = "TerraHorse"
      AWS_DEPLOY_ROLE_ARN                    = aws_iam_role.github-actions-deploy["dev"].arn
    }
    "aws-prod" = {
      NUXT_PUBLIC_SITE_URL                   = "https://terrahorse.lt"
      NUXT_PUBLIC_I18N_BASE_URL              = "https://terrahorse.lt"
      SALEOR_API_URL                         = "https://api:8443/graphql/"
      SALEOR_CHANNEL                         = "terrahorse-eur"
      SALEOR_STOCK_AVAILABILITY_MODE         = "channel-aggregate"
      SALEOR_STOCK_COUNTRY_CODE              = "LT"
      LOG_LEVEL                              = "info"
      SALEOR_PAYMENT_GATEWAY_ID              = "terrahorse.local-commerce"
      SALEOR_PAYMENT_APP_ID                  = "QXBwOjI="
      PAYMENT_CALLBACK_ORIGIN                = "https://terrahorse.lt"
      MONTONIO_SHIPPING_API_URL              = "https://sandbox-shipping.montonio.com"
      MONTONIO_PAYMENTS_API_URL              = "https://stargate.montonio.com/api"
      SALEOR_VENIPAK_PARCEL_LOCKER_METHOD_ID = "U2hpcHBpbmdNZXRob2Q6Mg=="
      SALEOR_VENIPAK_COURIER_METHOD_ID       = "U2hpcHBpbmdNZXRob2Q6Mw=="
      SALEOR_PUBLIC_URL                      = "https://api.terrahorse.lt"
      SALEOR_DASHBOARD_URL                   = "https://dashboard.terrahorse.lt/"
      SALEOR_DASHBOARD_API_URL               = "https://api.terrahorse.lt/graphql/"
      STOREFRONT_PUBLIC_URL                  = "https://terrahorse.lt"
      SALEOR_ALLOWED_HOSTS                   = "localhost,127.0.0.1,api,terrahorse.lt,api.terrahorse.lt"
      SALEOR_ALLOWED_CLIENT_HOSTS            = "localhost,127.0.0.1,terrahorse.lt,dashboard.terrahorse.lt"
      ORDER_EMAIL_SMTP_HOST                  = "smtp.purelymail.com"
      ORDER_EMAIL_SMTP_PORT                  = "465"
      ORDER_EMAIL_SMTP_SECURITY              = "tls"
      ORDER_EMAIL_SMTP_USERNAME              = "info@terrahorse.lt"
      ORDER_EMAIL_FROM_ADDRESS               = "info@terrahorse.lt"
      ORDER_EMAIL_FROM_NAME                  = "TerraHorse"
      AWS_DEPLOY_ROLE_ARN                    = aws_iam_role.github-actions-deploy["prod"].arn
    }
  }

  github_environment_secret_names = {
    "aws-dev" = [
      "COMMERCE_EVENT_HMAC_KEY",
      "MONTONIO_ACCESS_KEY",
      "MONTONIO_SECRET_KEY",
      "CLOUDFLARED_TUNNEL_TOKEN",
      "POSTGRES_PASSWORD",
      "SECRET_KEY",
      "RSA_PRIVATE_KEY",
      "ORDER_EMAIL_SMTP_PASSWORD",
    ]
    "aws-prod" = [
      "SALEOR_COMMERCE_APP_TOKEN",
      "COMMERCE_EVENT_HMAC_KEY",
      "MONTONIO_ACCESS_KEY",
      "MONTONIO_SECRET_KEY",
      "CLOUDFLARED_TUNNEL_TOKEN",
      "POSTGRES_PASSWORD",
      "SECRET_KEY",
      "RSA_PRIVATE_KEY",
      "ORDER_EMAIL_SMTP_PASSWORD",
    ]
  }

  github_environments = setunion(
    toset(keys(local.github_environment_variables)),
    toset(keys(local.github_environment_secret_names)),
  )

  github_variable_keys = merge([
    for environment, variables in local.github_environment_variables : {
      for name, value in variables : "${environment}:${name}" => {
        environment = environment
        name        = name
        value       = value
      }
    }
  ]...)

  github_secret_keys = merge([
    for environment, names in local.github_environment_secret_names : {
      for name in names : "${environment}:${name}" => {
        environment = environment
        name        = name
      }
    }
  ]...)
}
