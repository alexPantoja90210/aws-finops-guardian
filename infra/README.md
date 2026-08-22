# `infra/` — Stack del FinOps Guardian en Terraform

Infraestructura como código del servicio que produce `report.json`.

El principio rector del proyecto — **el agente propone, un humano aprueba** — no empieza en el código del agente. Empieza aquí, en el IAM: la instancia no puede modificar nada de la cuenta aunque alguien se lo pida.

---

## Qué provisiona

| Recurso | Para qué |
|---|---|
| EC2 `t3.micro` + EBS gp3 8 GB cifrado | La caja que corre el colector y sirve `report.json` |
| Rol IAM read-only + instance profile | Credenciales temporales, sin llaves en disco |
| Security Group mínimo | HTTP/80 solo desde la IP del operador; salida abierta a las APIs de AWS |
| Budget zero-spend | Alerta por email sobre consumo real **y** proyectado |

Diez recursos en total, contando los attachments de policy y las reglas del SG.

---

## Uso

### Requisitos

- Terraform >= 1.6
- AWS CLI configurado con credenciales que puedan crear IAM, EC2 y Budgets

### Primera vez

```bash
cp terraform.tfvars.example terraform.tfvars
curl -s https://checkip.amazonaws.com          # tu IP pública
# edita terraform.tfvars: tu IP en /32 y tu email
terraform init
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

`plan` no crea nada y no cuesta nada. **Revísalo siempre antes de aplicar.**

### Qué revisar en el plan

1. `aws_iam_policy.guardian_readonly` — que ningún statement con `Effect: "Allow"` contenga acciones `Put*`, `Create*`, `Delete*`, `Modify*` o `Terminate*`.
2. `cidr_ipv4` en las reglas de ingress — debe ser tu `/32`. Si ves `0.0.0.0/0`, detente.
3. `aws_budgets_budget.zero_spend` — dos bloques `notification` (`ACTUAL` y `FORECASTED`) y `cost_types.include_credit = false`.
4. El conteo final — puro `to add`. Cualquier `destroy` inesperado es señal de que el state no está limpio.

### Acceso a la instancia

No hay SSH por defecto. La administración va por Session Manager:

```bash
aws ssm start-session --target $(terraform output -raw instance_id)
```

Requiere el [plugin de Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html), o entrar desde la consola web de EC2 → Conectar → Session Manager.

Para habilitar SSH, pon `enable_ssh = true` y un `ssh_key_name` de un key pair existente. No se recomienda: SSM cubre el caso sin abrir puertos ni custodiar llaves privadas.

### Destruir

```bash
terraform destroy
```

---

## Verificar el invariante de seguridad

Esta es la prueba de que el stack hace lo que promete. Desde dentro de la instancia:

```bash
aws sts get-caller-identity
# → assumed-role/finops-guardian-readonly-role/<instance-id>
#   La instancia asumió el rol sola. No hay credenciales en disco.

aws ec2 describe-instances --region us-east-1
# → funciona. La caja ve toda la cuenta.

aws ec2 stop-instances --instance-ids <su-propio-id> --region us-east-1
# → UnauthorizedOperation ... with an explicit deny in an identity-based policy
```

Fíjate en la frase exacta del error: **"explicit deny"**. AWS no dice "no te concedí ese permiso", dice "te lo negué". Es la diferencia que sostiene el diseño.

---

## Decisiones de diseño

Cada una existe por una razón concreta.

### `Deny` explícito además de no conceder escritura

La policy podría limitarse a otorgar solo lecturas. Lleva además un statement `DenyAllMutations` que niega explícitamente las acciones destructivas.

En IAM, **un `Deny` nunca puede ser sobrescrito por un `Allow`**. Si alguien adjunta mañana una policy permisiva a este rol por error, el rol sigue sin poder tocar la cuenta. El invariante no depende de que nadie se equivoque después — que es la única clase de invariante que aguanta.

### IMDSv2 obligatorio

`http_tokens = "required"` y `http_put_response_hop_limit = 1`.

Cierra el vector clásico de robo de credenciales del rol vía SSRF. Con un rol de solo lectura el daño sería menor, pero la postura correcta no debe depender de que el blast radius sea pequeño.

### `validation` en las variables

- `instance_type` solo acepta tipos de free tier.
- `ssh_ingress_cidr` rechaza explícitamente `0.0.0.0/0`.
- `budget_notification_email` exige forma de correo válida.

El error aparece en `plan` — gratis — en vez de en la factura o en un puerto abierto. Estas validaciones ya se ganaron el sueldo: cuando `t2.micro` resultó no ser elegible, el arreglo fue de una línea en el `tfvars` porque `t3.micro` ya estaba dentro de lo permitido.

### Budget con `include_credit = false`

Bajo el Free Plan de AWS los créditos absorben el consumo y el costo neto es cero. Un budget con la configuración por defecto **nunca alertaría** — el guardián de costos ciego justo en la cuenta que vigila.

Excluir los créditos hace que mida consumo bruto, que es la señal real de cuánto se está quemando.

### AMI resuelta por filtro

`data.aws_ami.al2023` busca la más reciente en tiempo de plan, en vez de hardcodear un id. Los ids de AMI cambian por región y quedan obsoletos.

### Salida de red abierta, a propósito

Restringirla exigiría VPC endpoints, que cuestan dinero y romperían la premisa zero-spend. Es un intercambio consciente, no un descuido.

### `AmazonSSMManagedInstanceCore` — el matiz honesto

Esta policy administrada incluye tres acciones con forma de escritura: `ssm:UpdateInstanceInformation`, `ssmmessages:CreateControlChannel` y `ssmmessages:CreateDataChannel`. No mutan recursos de la cuenta — abren el canal de sesión.

Se acepta conscientemente: es el precio de no tener llaves privadas ni puertos de administración abiertos. Un rol perfectamente read-only sobre el papel, con una llave SSH guardada en un disco, sería peor postura real.

---

## Restricciones de la API que no detecta `terraform validate`

Dos defectos encontrados durante el primer `apply`, ambos invisibles para `validate` y `plan`:

- **`GroupDescription` de un Security Group solo acepta ASCII.** Un acento hace fallar el `apply` con `InvalidParameterValue`. IAM sí acepta no-ASCII, así que la restricción no es transversal — por eso el error aparece a la mitad de la ejecución.
- **La elegibilidad de free tier de un tipo de instancia se evalúa en `RunInstances`.** No hay forma de saberlo antes. Consúltala con `aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true`.

La lección general: **`validate` verifica forma, `plan` verifica el diff contra el state, y solo `apply` verifica que el proveedor acepte los valores.** Es el argumento a favor de aplicar de forma supervisada y no automatizada — cada fallo dejó el state consistente y permitió continuar exactamente donde se rompió, sin recursos huérfanos.

---

## Archivos que nunca se commitean

`terraform.tfvars` · `terraform.tfstate*` · `.terraform/` · `tfplan` · `plan-*.txt`

Los dos últimos importan más de lo que parece: **contienen la IP pública del operador** en las reglas del security group. Este es un repositorio público; publicarlos sería servir un mapa de superficie de ataque. La evidencia de los planes vive en los adjuntos de Jira, no aquí.

`.terraform.lock.hcl` **sí se versiona**: fija el hash del provider y es lo que hace reproducible el plan.

---

## Advertencia sobre el Free Plan

La cuenta opera bajo el **Free Plan** de AWS: 6 meses o hasta agotar los créditos, lo que ocurra primero.

Al expirar, **AWS cierra la cuenta automáticamente** y se pierde el acceso a los recursos y datos; el contenido se retiene 90 días antes del borrado definitivo. Migrar a un plan de pago dentro de esa ventana es lo único que lo evita.

Toda la infraestructura descrita aquí tiene esa fecha de caducidad.

---

## Referencias

- Issue de origen: **IA-7**
- Defectos encontrados: **IA-23** (ASCII en `GroupDescription`), **IA-24** (tipo de instancia no elegible)
- Consumidores del `guardian_role_arn`: **IA-3** (FinOps Copilot), **IA-4** (Ops Triage)
