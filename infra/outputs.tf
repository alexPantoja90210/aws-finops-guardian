###############################################################################
# Outputs. What IA-3 and IA-4 need to know about the stack in order to connect.
###############################################################################

output "instance_id" {
  description = "Id of the Guardian instance."
  value       = aws_instance.guardian.id
}

output "instance_public_ip" {
  description = "Public IP of the box. This is the address report.json is served from."
  value       = aws_instance.guardian.public_ip
}

output "guardian_role_arn" {
  description = "ARN of the read-only role. This is what unblocks IA-3 and IA-4."
  value       = aws_iam_role.guardian.arn
}

output "guardian_role_name" {
  description = "Name of the read-only role."
  value       = aws_iam_role.guardian.name
}

output "instance_profile_name" {
  description = "Instance profile attached to the box. The proof that no keys are stored."
  value       = aws_iam_instance_profile.guardian.name
}

output "security_group_id" {
  description = "Id of the Guardian Security Group."
  value       = aws_security_group.guardian.id
}

output "budget_name" {
  description = "Name of the zero-spend budget watching the account."
  value       = aws_budgets_budget.zero_spend.name
}

output "ssh_command" {
  description = "Connection command, or the SSM alternative when SSH is disabled."
  value = var.enable_ssh && var.ssh_key_name != "" ? format(
    "ssh -i ~/.ssh/%s.pem ec2-user@%s", var.ssh_key_name, aws_instance.guardian.public_ip
    ) : format(
    "aws ssm start-session --target %s", aws_instance.guardian.id
  )
}

output "account_id" {
  description = "AWS account this was deployed into. Sensitive: not printed to the console by default."
  value       = data.aws_caller_identity.current.account_id
  sensitive   = true
}

###############################################################################
# IA-45 pilot
###############################################################################

output "pilot_injector_role_arn" {
  description = "ARN of the scoped injector role. Null while the pilot is off."
  value       = var.pilot_enabled ? aws_iam_role.pilot_injector[0].arn : null
}

output "pilot_target_instance_id" {
  description = "The one instance the injector may start and stop. Null while the pilot is off."
  value       = var.pilot_enabled ? aws_instance.guardian.id : null
}

###############################################################################
# IA-55 dependency chain
###############################################################################

output "chain_topology" {
  description = <<-EOT
    The declared graph, and the private addresses that make it real. This is the
    single source the bootstrap and the pilot's arm B both read, so the graph
    handed to the agent cannot drift from the graph that actually exists.
  EOT
  value = var.chain_enabled ? {
    port = var.chain_port
    nodes = {
      db = { instance_id = aws_instance.guardian.id,
        private_ip = aws_instance.guardian.private_ip,
      depends_on_node = null }
      app = { instance_id = aws_instance.chain["app"].id,
        private_ip = aws_instance.chain["app"].private_ip,
      depends_on_node = "db" }
      web = { instance_id = aws_instance.chain["web"].id,
        private_ip = aws_instance.chain["web"].private_ip,
      depends_on_node = "app" }
    }
  } : null
  sensitive = true
}
