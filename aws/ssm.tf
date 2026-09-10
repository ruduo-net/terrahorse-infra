resource "aws_ssm_parameter" "cloudflared-tunnel-token" {
  for_each = local.cloudflare_tunnels

  name        = "/terrahorse/${each.key}/cloudflared/tunnel-token"
  description = "Cloudflare Tunnel token for the ${each.key} ECS task"
  type        = "SecureString"
  value       = data.cloudflare_zero_trust_tunnel_cloudflared_token.terrahorse[each.key].token

  tags = {
    Name        = "/terrahorse/${each.key}/cloudflared/tunnel-token"
    Environment = each.key
  }
}
