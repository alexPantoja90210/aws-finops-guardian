###############################################################################
# aws-finops-guardian / infra / chain.tf
#
# IA-55. A real dependency chain for the IA-45 pilot:
#
#     web  ──pulls from──▶  app  ──pulls from──▶  db
#
# The point is not to have three machines. It is that the SYMPTOM and the CAUSE
# land on different hosts: stop `app` and it is `web` whose traffic collapses,
# while `db` stays perfectly healthy. With a single instance the root cause is
# always that instance and the agent cannot pick the wrong subject, which makes
# the question nearly free to answer and nearly worthless to ask.
#
# Two deliberate absences:
#
#   No user_data anywhere. The existing instance would be REPLACED by adding it,
#   and IA-46 pinned that instance precisely so no plan could rebuild it under
#   us. The chain is installed over SSM instead, as a systemd unit, which also
#   satisfies the requirement that it survive a restart -- an instance coming
#   back from an injection rejoins the chain by itself.
#
#   No new inbound port to the world. The payload moves over private addresses
#   inside the default VPC, and the security group accepts it only from ITSELF.
###############################################################################

locals {
  chain_count = var.chain_enabled ? 1 : 0

  # The graph, declared once. It becomes tags on the instances, which is what
  # makes it DISCOVERABLE: the topology handed to the agent is read back from
  # the account rather than retyped into a prompt, so the graph it reasons over
  # and the graph that exists cannot drift apart.
  chain_upstream = {
    app = "db"
    web = "app"
  }
}

# The three nodes speak to each other and to nobody else. `self = true` means
# "sources in this same security group", so membership is the whole ACL.
resource "aws_vpc_security_group_ingress_rule" "chain" {
  count = local.chain_count

  security_group_id            = aws_security_group.guardian.id
  description                  = "IA-55 chain: payload pulls between pilot nodes only"
  referenced_security_group_id = aws_security_group.guardian.id
  from_port                    = var.chain_port
  to_port                      = var.chain_port
  ip_protocol                  = "tcp"
}

# app and web. `db` is the instance that already exists: it keeps its identity,
# its pinned AMI and its history, and only gains a role tag.
resource "aws_instance" "chain" {
  for_each = var.chain_enabled ? toset(["app", "web"]) : toset([])

  ami           = var.pinned_ami_id != "" ? var.pinned_ami_id : data.aws_ami.al2023.id
  instance_type = var.instance_type

  iam_instance_profile   = aws_iam_instance_profile.guardian.name
  vpc_security_group_ids = [aws_security_group.guardian.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size           = var.root_volume_size_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  monitoring = false

  # Same reasoning as IA-46: standard, chosen rather than inherited. Under
  # "unlimited" a CPU fault becomes a charge instead of a signal.
  credit_specification {
    cpu_credits = "standard"
  }

  tags = {
    Name      = "${var.project_name}-${each.key}"
    Role      = "pilot-chain"
    Pilot     = var.pilot_tag_value
    ChainRole = each.key
    DependsOn = local.chain_upstream[each.key]
  }

  lifecycle {
    precondition {
      condition     = var.pinned_ami_id != ""
      error_message = "chain_enabled is true but pinned_ami_id is empty. The chain nodes must be pinned for the same reason the original target is: an experiment whose machines any plan can rebuild is not a controlled experiment."
    }
  }
}
