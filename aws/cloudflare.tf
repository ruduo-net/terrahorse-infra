locals {
  cloudflare_tunnel_hostnames = {
    dev  = "dev.terrahorse.lt"
    prod = "terrahorse.lt"
  }

  cloudflare_api_hostnames = {
    dev  = "api-dev.terrahorse.lt"
    prod = "api.terrahorse.lt"
  }

  cloudflare_dashboard_hostnames = {
    dev  = "dashboard-dev.terrahorse.lt"
    prod = "dashboard.terrahorse.lt"
  }

  cloudflare_editor_hostnames = {
    dev = "editor-dev.terrahorse.lt"
  }

  cloudflare_tunnels = {
    for environment in ["dev", "prod"] : environment => {
      name               = "terrahorse-${environment}"
      hostname           = local.cloudflare_tunnel_hostnames[environment]
      api_hostname       = local.cloudflare_api_hostnames[environment]
      dashboard_hostname = local.cloudflare_dashboard_hostnames[environment]
      editor_hostname    = lookup(local.cloudflare_editor_hostnames, environment, null)
    }
  }
}

data "cloudflare_zone" "terrahorse" {
  filter = {
    name = "terrahorse.lt"

    account = {
      id = var.cloudflare_account_id
    }
  }
}

resource "cloudflare_zone_setting" "brotli" {
  zone_id    = data.cloudflare_zone.terrahorse.id
  setting_id = "brotli"
  value      = "on"
}

resource "random_password" "cloudflare-tunnel-secret" {
  for_each = local.cloudflare_tunnels

  length  = 32
  special = false
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "terrahorse" {
  for_each = local.cloudflare_tunnels

  account_id    = var.cloudflare_account_id
  name          = each.value.name
  tunnel_secret = base64encode(random_password.cloudflare-tunnel-secret[each.key].result)
  config_src    = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "terrahorse" {
  for_each = local.cloudflare_tunnels

  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.terrahorse[each.key].id

  config = {
    ingress = concat(
      [
        {
          hostname = each.value.hostname
          service  = "http://localhost:3000"
        },
        {
          hostname = each.value.dashboard_hostname
          service  = "http://localhost:9000"
        },
      ],
      each.value.editor_hostname == null ? [] : [
        {
          hostname = each.value.editor_hostname
          service  = "http://localhost:3100"
        },
      ],
      [
        {
          hostname = each.value.api_hostname
          path     = "/media/.*"
          service  = "http://localhost:8080"
        },
        {
          hostname = each.value.api_hostname
          service  = "https://localhost:8443"
          origin_request = {
            no_tls_verify = true
          }
        },
        {
          service = "http_status:404"
        },
      ],
    )
  }
}

resource "cloudflare_dns_record" "terrahorse-tunnel" {
  for_each = local.cloudflare_tunnels

  zone_id = data.cloudflare_zone.terrahorse.id
  name    = each.value.hostname
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.terrahorse[each.key].id}.cfargotunnel.com"
  ttl     = 1
  proxied = true
  comment = "TerraHorse ${each.key} Cloudflare Tunnel"
}

resource "cloudflare_dns_record" "terrahorse-api-tunnel" {
  for_each = local.cloudflare_tunnels

  zone_id = data.cloudflare_zone.terrahorse.id
  name    = each.value.api_hostname
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.terrahorse[each.key].id}.cfargotunnel.com"
  ttl     = 1
  proxied = true
  comment = "TerraHorse ${each.key} API Cloudflare Tunnel"
}

resource "cloudflare_dns_record" "terrahorse-dashboard-tunnel" {
  for_each = local.cloudflare_tunnels

  zone_id = data.cloudflare_zone.terrahorse.id
  name    = each.value.dashboard_hostname
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.terrahorse[each.key].id}.cfargotunnel.com"
  ttl     = 1
  proxied = true
  comment = "TerraHorse ${each.key} Dashboard Cloudflare Tunnel"
}

resource "cloudflare_dns_record" "terrahorse-editor-tunnel" {
  for_each = local.cloudflare_editor_hostnames

  zone_id = data.cloudflare_zone.terrahorse.id
  name    = each.value
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.terrahorse[each.key].id}.cfargotunnel.com"
  ttl     = 1
  proxied = true
  comment = "TerraHorse ${each.key} Product Editor Cloudflare Tunnel"
}

moved {
  from = random_password.cloudflare_tunnel_secret
  to   = random_password.cloudflare-tunnel-secret
}

moved {
  from = cloudflare_dns_record.terrahorse_tunnel
  to   = cloudflare_dns_record.terrahorse-tunnel
}

moved {
  from = cloudflare_dns_record.terrahorse_api_tunnel
  to   = cloudflare_dns_record.terrahorse-api-tunnel
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "terrahorse" {
  for_each = local.cloudflare_tunnels

  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.terrahorse[each.key].id
}

output "cloudflare_tunnel_ids" {
  description = "Cloudflare tunnel IDs for the TerraHorse environments"
  value = {
    for environment, tunnel in cloudflare_zero_trust_tunnel_cloudflared.terrahorse : environment => tunnel.id
  }
}
