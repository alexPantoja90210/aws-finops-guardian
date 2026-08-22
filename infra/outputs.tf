###############################################################################
# Salidas. Lo que IA-3 e IA-4 necesitan saber del stack para conectarse.
###############################################################################

output "instance_id" {
  description = "Id de la instancia del Guardian."
  value       = aws_instance.guardian.id
}

output "instance_public_ip" {
  description = "IP pública de la caja. Es la dirección por la que se sirve report.json."
  value       = aws_instance.guardian.public_ip
}

output "guardian_role_arn" {
  description = "ARN del rol read-only. Este es el desbloqueo de IA-3 e IA-4."
  value       = aws_iam_role.guardian.arn
}

output "guardian_role_name" {
  description = "Nombre del rol read-only."
  value       = aws_iam_role.guardian.name
}

output "instance_profile_name" {
  description = "Instance profile adjunto a la caja. La prueba de que no hay llaves guardadas."
  value       = aws_iam_instance_profile.guardian.name
}

output "security_group_id" {
  description = "Id del Security Group del Guardian."
  value       = aws_security_group.guardian.id
}

output "budget_name" {
  description = "Nombre del budget zero-spend que vigila la cuenta."
  value       = aws_budgets_budget.zero_spend.name
}

output "ssh_command" {
  description = "Comando de conexión, o la alternativa por SSM si SSH está deshabilitado."
  value = var.enable_ssh && var.ssh_key_name != "" ? format(
    "ssh -i ~/.ssh/%s.pem ec2-user@%s", var.ssh_key_name, aws_instance.guardian.public_ip
    ) : format(
    "aws ssm start-session --target %s", aws_instance.guardian.id
  )
}

output "account_id" {
  description = "Cuenta AWS donde se desplegó. Sensible: no se imprime en consola por defecto."
  value       = data.aws_caller_identity.current.account_id
  sensitive   = true
}
