# Configuración del Webhook — GitHub → Tekton

El EventListener de Tekton recibe webhooks de GitHub en `tekton-webhook.localhost:8888`. Para que GitHub pueda alcanzar esa URL desde internet, necesitás exponerla con un tunnel.

---

## Opción A — ngrok (recomendada para demo)

### 1. Instalar ngrok

```bash
# Windows
winget install ngrok.ngrok

# Mac
brew install ngrok/ngrok/ngrok
```

### 2. Autenticar ngrok (primera vez)

```bash
ngrok config add-authtoken <tu-token>
# Token gratuito disponible en https://dashboard.ngrok.com
```

### 3. Exponer el puerto 8888

```bash
make tunnel
# equivalente a: ngrok http 8888
```

ngrok va a mostrar algo como:
```
Forwarding  https://abc123.ngrok-free.app → http://localhost:8888
```

Copiá esa URL `https://abc123.ngrok-free.app`.

### 4. Configurar el webhook en GitHub

1. Ir al repo de la app (ej: `github.com/Valentino-33/webserver-api01`)
2. **Settings → Webhooks → Add webhook**
3. Completar:
   - **Payload URL**: `https://abc123.ngrok-free.app` (la URL de ngrok)
   - **Content type**: `application/json`
   - **Secret**: dejar vacío (o configurar — ver sección de HMAC abajo)
   - **Which events?**: `Just the push event`
4. Guardar y verificar que GitHub muestre ✓ (ping exitoso)

---

## Opción B — smee.io (alternativa gratuita)

smee.io es un proxy de webhooks sin instalación local. Útil cuando ngrok no está disponible.

### 1. Obtener canal smee

```bash
# Instalar smee-client
npm install -g smee-client

# O con npx (sin instalación)
npx smee-client --url https://smee.io/nuevo-canal --target http://localhost:8888
```

Ir a `https://smee.io` y hacer click en **Start a new channel** para obtener una URL del tipo `https://smee.io/AbCdEfGhIjKlMnOp`.

### 2. Iniciar el cliente local

```bash
smee --url https://smee.io/AbCdEfGhIjKlMnOp --path / --port 8888
```

### 3. Configurar el webhook en GitHub

Igual que con ngrok, pero usar la URL de smee como Payload URL.

---

## Opción C — Acceso directo (red local / VPN)

Si GitHub puede alcanzar tu máquina directamente (IP pública, VPN corporativa, etc.):

```bash
# Obtener tu IP pública
curl -s https://api.ipify.org

# El webhook en GitHub debe apuntar a:
# http://<tu-ip>:8888
```

En este caso también necesitás que el puerto 8888 esté abierto en tu firewall/router.

---

## Verificar que el webhook funciona

### 1. Hacer un push de tag de prueba

```bash
cd /ruta/a/webserver-api01

git tag dev/rollingupdate/v0.0.1
git push origin dev/rollingupdate/v0.0.1
```

### 2. Verificar el delivery en GitHub

Settings → Webhooks → el webhook → **Recent Deliveries**

Debería aparecer un request con status 200 o 2xx.

### 3. Verificar que Tekton creó el PipelineRun

```bash
kubectl -n tekton-pipelines get pipelineruns --watch
```

Si no aparece, verificar los logs del EventListener:

```bash
kubectl -n tekton-pipelines logs -l eventlistener=github-tag-listener -f
```

---

## Formato del tag (recordatorio)

El CEL filter solo acepta tags con formato de 5 segmentos:

```
refs/tags/<env>/<strategy>/<semver>
```

| Tag pusheado | Dispara pipeline | Motivo |
|--------------|-----------------|--------|
| `dev/bluegreen/v1.0.0` | ✅ Sí | 5 segmentos, formato correcto |
| `dev/canary/v1.0.0` | ✅ Sí | 5 segmentos, formato correcto |
| `dev/rollingupdate/v1.0.0` | ✅ Sí | 5 segmentos, formato correcto |
| `v1.0.0` | ❌ No | Solo 3 segmentos |
| `release/v1.0.0` | ❌ No | Solo 4 segmentos |

---

## HMAC (opcional — validar origen del webhook)

Para agregar validación de firma HMAC en el webhook de GitHub:

### 1. Generar un secret

```bash
openssl rand -hex 20
# Ejemplo: a3f8b2c1d4e5...
```

### 2. Configurarlo en GitHub

Settings → Webhooks → el webhook → **Secret** → pegar el valor generado.

### 3. Configurarlo en Tekton

Tekton Triggers soporta validación HMAC vía `github` interceptor. Editar el EventListener para agregar la validación:

```yaml
interceptors:
- ref:
    name: "github"
  params:
  - name: "secretRef"
    value:
      secretName: github-webhook-secret
      secretKey: secretToken
  - name: "eventTypes"
    value: ["push"]
- ref:
    name: "cel"
  params:
  - name: filter
    value: "body.ref.startsWith('refs/tags/') && body.ref.split('/').size() >= 5"
```

```bash
kubectl create secret generic github-webhook-secret \
  --from-literal=secretToken=<el-valor-generado> \
  -n tekton-pipelines
```

> Para la POC, el interceptor CEL sin HMAC es suficiente.

---

## Troubleshooting

| Síntoma | Causa probable | Solución |
|---------|---------------|----------|
| GitHub muestra error 5xx en delivery | EventListener no está listo | `kubectl -n tekton-pipelines get pods` → esperar a que el pod esté Running |
| GitHub muestra error de conexión | ngrok/smee no está corriendo | Reiniciar `make tunnel` o el cliente smee |
| PipelineRun no aparece | Tag con formato incorrecto | Verificar que sea `env/strategy/semver` |
| PipelineRun falla en Stage 1 | El repo de la app no es accesible | Verificar que el repo sea público o agregar deploy key |
| PipelineRun falla en Stage 2 | Secret `dockerhub-credentials` faltante | `make secrets-apply DOCKERHUB_USER=... DOCKERHUB_TOKEN=...` |
| PipelineRun falla en Stage 3 | Secret `github-token` faltante o expirado | `make secrets-apply ... GITHUB_TOKEN=...` |
| PipelineRun falla en Stage 4 | ArgoCD no sincronizó en tiempo | Verificar ArgoCD Application; aumentar timeout en task-wait-argocd |
