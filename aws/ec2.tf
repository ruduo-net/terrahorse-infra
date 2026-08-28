data "aws_ami" "amazon-linux-2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*-arm64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_security_group" "ec2" {
  name        = "${local.account_name}-ec2"
  description = "TerraHorse EC2 host with outbound HTTPS only"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.account_name}-ec2"
  }
}

resource "aws_vpc_security_group_egress_rule" "ec2-https" {
  security_group_id = aws_security_group.ec2.id
  description       = "HTTPS egress"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "ec2-smtp-tls" {
  security_group_id = aws_security_group.ec2.id
  description       = "SMTP implicit TLS egress"
  ip_protocol       = "tcp"
  from_port         = 465
  to_port           = 465
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "ec2-cloudflare-http2" {
  security_group_id = aws_security_group.ec2.id
  description       = "Cloudflare Tunnel HTTP/2 egress"
  ip_protocol       = "tcp"
  from_port         = 7844
  to_port           = 7844
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "ec2-cloudflare-quic" {
  security_group_id = aws_security_group.ec2.id
  description       = "Cloudflare Tunnel QUIC egress"
  ip_protocol       = "udp"
  from_port         = 7844
  to_port           = 7844
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_ebs_volume" "data" {
  for_each          = local.ec2_environments
  availability_zone = each.value.availability_zone
  encrypted         = true
  size              = each.value.data_volume_size_gib
  type              = each.value.data_volume_type

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name        = "${each.value.name}-data"
    Environment = each.key
  }
}

locals {
  ec2_cloud_init = {
    for environment, config in local.ec2_environments : environment => "#cloud-config\n${yamlencode({
      write_files = [
        {
          path        = "/usr/local/sbin/terrahorse-bootstrap"
          owner       = "root:root"
          permissions = "0755"
          content = templatefile("${path.module}/user_data/ec2.sh.tftpl", {
            environment           = environment
            data_volume_id        = aws_ebs_volume.data[environment].id
            compose_file          = config.compose_file
            dashboard_admin_email = config.dashboard_admin_email
          })
        }
      ]
      runcmd = [
        ["/usr/local/sbin/terrahorse-bootstrap"]
      ]
    })}"
  }
}

resource "aws_launch_template" "ec2" {
  for_each      = local.ec2_environments
  name_prefix   = "${each.value.name}-"
  image_id      = data.aws_ami.amazon-linux-2023.id
  instance_type = each.value.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2[each.key].name
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      encrypted             = true
      volume_type           = "gp3"
      volume_size           = each.value.root_volume_size_gib
      delete_on_termination = true
    }
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.ec2.id]
  }

  # EC2 caps decoded user data at 16 KiB; cloud-init transparently expands gzip payloads.
  user_data = base64gzip(local.ec2_cloud_init[each.key])

  tag_specifications {
    resource_type = "instance"

    tags = merge(
      {
        Name        = each.value.name
        Environment = each.key
      },
      length([
        aws_iam_role_policy_attachment.ec2-ssm[each.key].id,
        aws_iam_role_policy_attachment.ec2-ecr-read-only[each.key].id,
      ]) > 0 ? {} : {}
    )
  }
}

resource "aws_autoscaling_group" "ec2" {
  for_each            = local.ec2_environments
  name                = each.value.name
  min_size            = each.value.min_size
  desired_capacity    = each.value.desired_capacity
  max_size            = each.value.max_size
  vpc_zone_identifier = [aws_subnet.dmz[each.value.availability_zone].id]

  health_check_type         = "EC2"
  health_check_grace_period = 900

  launch_template {
    id      = aws_launch_template.ec2[each.key].id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"

    preferences {
      instance_warmup        = 900
      min_healthy_percentage = 0
    }

  }

  tag {
    key                 = "Name"
    value               = each.value.name
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = each.key
    propagate_at_launch = true
  }
}
