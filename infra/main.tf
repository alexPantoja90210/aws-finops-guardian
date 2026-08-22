###############################################################################
# Stack del FinOps Guardian.
#
# Principio del proyecto: el agente PROPONE, un humano APRUEBA. Ese principio
# empieza aquí, en el IAM: la caja no puede modificar nada en la cuenta, ni
# aunque alguien se lo pida. Solo lee.
###############################################################################

data "aws_caller_identity" "current" {}

# AMI Amazon Linux 2023 más reciente, resuelta en tiempo de plan.
# Se busca por filtro en vez de hardcodear un id: los ids de AMI cambian por
# región y quedan obsoletos.
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_vpc" "default" {
  default = true
}

###############################################################################
# IAM — el corazón de esta tarea.
# Este es el rol que IA-3 e IA-4 necesitan para leer datos reales de AWS.
###############################################################################

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "guardian" {
  name               = "${var.project_name}-readonly-role"
  description        = "Rol read-only del FinOps Guardian. Sin permisos de escritura por diseño (IA-7)."
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

# Permisos exactos que el Guardian necesita para producir report.json.
# Cada bloque existe por una razón concreta; no hay comodines de conveniencia.
data "aws_iam_policy_document" "guardian_readonly" {

  # Costos y desperdicio. Es la materia prima del FinOps Copilot.
  statement {
    sid    = "CostExplorerRead"
    effect = "Allow"
    actions = [
      "ce:GetCostAndUsage",
      "ce:GetCostForecast",
      "ce:GetDimensionValues",
      "ce:GetReservationUtilization",
      "ce:GetRightsizingRecommendation",
      "ce:GetSavingsPlansUtilization",
      "ce:GetTags",
      "ce:GetUsageForecast",
      "ce:DescribeCostCategoryDefinition",
      "ce:ListCostCategoryDefinitions",
    ]
    resources = ["*"]
  }

  # Métricas de utilización. Alimenta tanto el ranking de waste del FinOps
  # Copilot como las señales del Ops Triage (IA-4).
  statement {
    sid    = "CloudWatchRead"
    effect = "Allow"
    actions = [
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:ListMetrics",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:DescribeAlarmHistory",
    ]
    resources = ["*"]
  }

  # Logs, para que el colector de IA-4 pueda leer eventos sin poder escribirlos.
  statement {
    sid    = "CloudWatchLogsRead"
    effect = "Allow"
    actions = [
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:FilterLogEvents",
      "logs:GetLogEvents",
    ]
    resources = ["*"]
  }

  # Inventario de recursos. Sin esto no se sabe qué está encendido y ocioso.
  statement {
    sid    = "EC2Inventory"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeVolumes",
      "ec2:DescribeAddresses",
      "ec2:DescribeSnapshots",
      "ec2:DescribeRegions",
      "ec2:DescribeInstanceTypes",
    ]
    resources = ["*"]
  }

  # Estado del presupuesto, para que el reporte sepa cuánto margen queda.
  statement {
    sid    = "BudgetsRead"
    effect = "Allow"
    actions = [
      "budgets:DescribeBudget",
      "budgets:DescribeBudgets",
      "budgets:ViewBudget",
    ]
    resources = ["*"]
  }

  # Cinturón y tirantes: aunque una policy futura concediera escritura por error,
  # este Deny explícito gana. En IAM, un Deny nunca puede ser sobrescrito por un
  # Allow. Es la garantía de que la caja jamás modificará la cuenta.
  statement {
    sid    = "DenyAllMutations"
    effect = "Deny"
    actions = [
      "ec2:RunInstances",
      "ec2:TerminateInstances",
      "ec2:StopInstances",
      "ec2:StartInstances",
      "ec2:CreateVolume",
      "ec2:DeleteVolume",
      "ec2:ModifyInstanceAttribute",
      "iam:*",
      "budgets:ModifyBudget",
      "budgets:DeleteBudget",
      "budgets:CreateBudget",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "guardian_readonly" {
  name        = "${var.project_name}-readonly-policy"
  description = "Lectura de Cost Explorer, CloudWatch, EC2 y Budgets. Deny explícito sobre toda mutación."
  policy      = data.aws_iam_policy_document.guardian_readonly.json
}

resource "aws_iam_role_policy_attachment" "guardian_readonly" {
  role       = aws_iam_role.guardian.name
  policy_arn = aws_iam_policy.guardian_readonly.arn
}

# Permite administrar la caja por SSM Session Manager, sin abrir SSH ni guardar
# llaves. Es política administrada de AWS, de solo operación de sesión.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.guardian.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# El instance profile es lo que hace que NO haya llaves en la caja: la instancia
# obtiene credenciales temporales rotadas por AWS.
resource "aws_iam_instance_profile" "guardian" {
  name = "${var.project_name}-instance-profile"
  role = aws_iam_role.guardian.name
}

###############################################################################
# Red — Security Group mínimo.
###############################################################################

resource "aws_security_group" "guardian" {
  name        = "${var.project_name}-sg"
  # OJO: la API de EC2 rechaza cualquier carácter fuera de ASCII en
  # GroupDescription. No es capricho de estilo: un acento aquí hace fallar el
  # apply con InvalidParameterValue. Por eso esta descripcion va en ASCII plano
  # mientras los comentarios del archivo siguen en español.
  description = "Minimal access for the Guardian. Egress open to AWS APIs; ingress restricted to a single operator IP."
  vpc_id      = data.aws_vpc.default.id

  lifecycle {
    precondition {
      condition     = !var.enable_ssh || var.ssh_ingress_cidr != ""
      error_message = "enable_ssh está en true pero ssh_ingress_cidr está vacío. Declara tu IP en /32 o pon enable_ssh = false."
    }
  }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  count = var.enable_ssh && var.ssh_ingress_cidr != "" ? 1 : 0

  security_group_id = aws_security_group.guardian.id
  description       = "SSH solo desde la IP del operador"
  cidr_ipv4         = var.ssh_ingress_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  count = var.http_ingress_cidr != "" ? 1 : 0

  security_group_id = aws_security_group.guardian.id
  description       = "nginx sirviendo report.json, solo desde la IP del operador"
  cidr_ipv4         = var.http_ingress_cidr
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

# Salida abierta: la instancia necesita alcanzar los endpoints de Cost Explorer,
# CloudWatch y EC2. Restringirla exigiría VPC endpoints, que cuestan dinero y
# romperían la premisa zero-spend.
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.guardian.id
  description       = "Salida a las APIs de AWS"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

###############################################################################
# Cómputo.
###############################################################################

resource "aws_instance" "guardian" {
  ami           = data.aws_ami.al2023.id
  instance_type = var.instance_type
  key_name      = var.ssh_key_name != "" ? var.ssh_key_name : null

  iam_instance_profile   = aws_iam_instance_profile.guardian.name
  vpc_security_group_ids = [aws_security_group.guardian.id]

  # IMDSv2 obligatorio: cierra el vector clásico de robo de credenciales del
  # rol vía SSRF. Con un rol de solo lectura el daño sería menor, pero la
  # postura correcta no depende de que el blast radius sea chico.
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

  tags = {
    Name = "${var.project_name}-ec2"
    Role = "guardian-collector"
  }
}

###############################################################################
# Budget zero-spend — el guard que hace seguro hacer apply.
###############################################################################

resource "aws_budgets_budget" "zero_spend" {
  provider = aws.us_east_1

  name         = "${var.project_name}-zero-spend"
  budget_type  = "COST"
  limit_amount = var.budget_limit_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Bajo el Free Plan de AWS los créditos absorben el consumo, así que el costo
  # NETO sería cero y este budget no alertaría nunca — el guardián de costos
  # ciego justo en la cuenta que debe vigilar. Excluir los créditos hace que
  # mida el consumo BRUTO, que es la señal real de cuánto se está quemando.
  cost_types {
    include_credit = false
  }

  # Avisa cuando el gasto REAL cruza el umbral.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = var.budget_alert_threshold_percent
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_notification_email]
  }

  # Y avisa también cuando la PROYECCIÓN del mes lo cruzaría: llega la alerta
  # antes de que el dinero se gaste, no después.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = var.budget_alert_threshold_percent
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_notification_email]
  }
}
