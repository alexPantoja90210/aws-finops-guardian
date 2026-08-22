###############################################################################
# Variables del stack Guardian.
# Ningún valor sensible vive aquí. Los valores reales van en terraform.tfvars,
# que está en .gitignore y nunca se commitea.
###############################################################################

variable "aws_region" {
  description = "Región donde vive el Guardian. Free tier disponible en todas las estándar."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefijo de nombres y tags para todos los recursos del stack."
  type        = string
  default     = "finops-guardian"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,32}$", var.project_name))
    error_message = "project_name debe ser minúsculas, dígitos o guiones, de 3 a 32 caracteres."
  }
}

variable "instance_type" {
  description = "Tipo de instancia EC2. Se restringe a free tier a propósito: este proyecto no debe generar gasto."
  type        = string
  default     = "t2.micro"

  validation {
    condition     = contains(["t2.micro", "t3.micro"], var.instance_type)
    error_message = "Solo se permiten tipos de free tier (t2.micro o t3.micro). Cambiar esto rompe la premisa zero-spend del proyecto."
  }
}

variable "ssh_ingress_cidr" {
  description = <<-EOT
    CIDR autorizado para SSH. Debe ser la IP pública de Alejandro en /32.
    Se deja vacío por defecto a propósito: obliga a declararlo y evita
    que un descuido abra el puerto 22 al mundo.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.ssh_ingress_cidr == "" || can(cidrhost(var.ssh_ingress_cidr, 0))
    error_message = "ssh_ingress_cidr debe ser un CIDR válido, por ejemplo 189.203.44.17/32."
  }

  validation {
    condition     = var.ssh_ingress_cidr != "0.0.0.0/0"
    error_message = "0.0.0.0/0 abre SSH a todo internet. Usa tu IP en /32."
  }
}

variable "enable_ssh" {
  description = "Si es false, el Security Group no abre el puerto 22 en absoluto. Preferible si administras la caja por SSM."
  type        = bool
  default     = true
}

variable "http_ingress_cidr" {
  description = "CIDR autorizado para leer el report.json por nginx. Por defecto, misma restricción que SSH."
  type        = string
  default     = ""
}

variable "budget_notification_email" {
  description = "Email que recibe la alerta del budget zero-spend. Sin esto el guard no avisa a nadie."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.budget_notification_email))
    error_message = "budget_notification_email debe ser una dirección de correo válida."
  }
}

variable "budget_limit_usd" {
  description = "Techo del presupuesto mensual en USD. 1.00 actúa como zero-spend: cualquier gasto real dispara la alerta."
  type        = string
  default     = "1.0"
}

variable "budget_alert_threshold_percent" {
  description = "Porcentaje del techo que dispara la notificación. 1% de 1 USD avisa prácticamente al primer centavo."
  type        = number
  default     = 1

  validation {
    condition     = var.budget_alert_threshold_percent > 0 && var.budget_alert_threshold_percent <= 100
    error_message = "El umbral debe estar entre 1 y 100."
  }
}

variable "root_volume_size_gb" {
  description = "Tamaño del volumen raíz. El free tier cubre hasta 30 GB de EBS gp3 al mes."
  type        = number
  default     = 8

  validation {
    condition     = var.root_volume_size_gb >= 8 && var.root_volume_size_gb <= 30
    error_message = "Mantente entre 8 y 30 GB para no salir del free tier de EBS."
  }
}

variable "ssh_key_name" {
  description = "Nombre de un key pair EC2 ya existente. Vacío = sin key pair (acceso por SSM Session Manager)."
  type        = string
  default     = ""
}
