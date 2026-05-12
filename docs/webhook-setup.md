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

> **Importante**: las cuentas gratuitas requieren cliente ≥ 3.20.0. Si tenés una versión anterior:
> ```bash
> ngrok update
> # o
> winget upgrade ngrok.ngrok
> ```

### 2. Autenticar ngrok (primera vez)

```bash
ngrok config add-authtoken <tu-token>
# Token gratuito disponible en https://dashboard.ngrok.com
```

### 3. Exponer el puerto 8888

```bash
make tunnel
# equivalente a: ngrok http --host-header=tekton-webhook.localhost 8888
```

El flag `--host-header` es **crítico**: rewrite del Host header al hostname que nginx-ingress espera (`tekton-webhook.localhost`), porque GitHub no permite setear Host arbitrarios en su webhook.

ngrok va a mostrar algo como:
```
Forwarding  https://abc123.ngrok-free.app → http://localhost:8888
```

Copiá esa URL `https://abc123.ngrok-free.app`.

### 4. Verificar que el tunnel funciona

```bash
curl -i -X POST https://abc123.ngrok-free.app/ \
  -H "Content-Type: application/json" \
  -H "X-GitHub-Event: ping" \
  -d '{"zen":"test"}'

# Esperado: HTTP/1.1 202 Accepted
# Body: {"eventListener":"github-tag-listener", ...}
```

Si devuelve 404, falta el `--host-header` o ngrok no está apuntando al puerto 8888 correcto.

### 5. Configurar el webhook en GitHub

1. Ir al repo de la app (ej: `github.com/Valentino-33/webserver-api01`)
2. **Settings → Webhooks → Add webhook**
3. Completar:
   - **Payload URL**: `https://abc123.ngrok-free.app` (la URL de ngrok)
   - **Content type**: `application/json`
   - **Secret**: dejar vacío (o configurar — ver sección de HMAC abajo)
   - **Which events?**: `Just the push event` (cubre push de tags)
4. Guardar y verificar que GitHub muestre ✓ (ping exitoso)

---

## Opción B — smee.io (alternativa gratuita)

smee.io es un proxy de webhooks sin instalación local. Útil cuando ngrok no está disponible.

### 1. Obtener canal smee

```bash
# Instalar smee-client
npm install -g smee-client

# O con npx (sin instalación)
npx smee-client --url https://smee.io/nuevo-canal --target http://tekton-webhook.localhost:8888
```

Ir a `https://smee.io` y hacer click en **Start a new channel** para obtener una URL del tipo `https://smee.io/AbCdEfGhIjKlMnOp`.

### 2. Iniciar el cliente local

```bash
smee --url https://smee.io/AbCdEfGhIjKlMnOp --target http://tekton-webhook.localhost:8888
```

> Si tu Host file resuelve `tekton-webhook.localhost`, esto manda los webhooks directo al ingress. Si no, usá `http://localhost:8888` y el cliente smee debería preservar el Host header (depende de la versión).

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

En este caso también necesitás que el puerto 8888 esté abierto en tu firewall/router. Para el `Host` header, podés agregar un `proxy_pass` con `proxy_set_header Host tekton-webhook.localhost` en algún nginx upstream, o aceptar que GitHub mande el Host por defecto (la IP pública) y ajustar el Ingress.

---

## Verificar que el webhook funciona end-to-end

### 1. Hacer un push de tag de prueba

```bash
cd /ruta/a/webserver-api01

git tag release/v0.0.1/dev
git push origin release/v0.0.1/dev
```

### 2. Verificar el delivery en GitHub

Settings → Webhooks → el webhook → **Recent Deliveries**

Debería aparecer un request con status **202 Accepted** y el response body:
```json
{"eventListener":"github-tag-listener","namespace":"tekton-pipelines","eventListenerUID":"...","eventID":"..."}
```

### 3. Verificar que Tekton creó el PipelineRun

```bash
# CLI
kubectl -n tekton-pipelines get pipelineruns --watch

# o en el Dashboard
# http://tekton.localhost:8888/#/pipelineruns
```

Si no aparece, verificar los logs del EventListener:

```bash
kubectl -n tekton-pipelines logs -l eventlistener=github-tag-listener -f
```

---

## Formato del tag (real)

El CEL filter solo acepta tags con formato:

```
refs/tags/release/<semver>/<envs>
```

Donde `<envs>` puede ser un solo env (`dev`) o varios separados por coma (`dev,staging`).

| Tag pusheado | Dispara pipeline | Motivo |
|--------------|-----------------|--------|
| `release/v1.0.0/dev` | ✅ Sí | formato correcto |
| `release/v1.0.0/dev,staging` | ✅ Sí | multi-env soportado |
| `release/v0.0.1/test` | ✅ Sí | cualquier env name |
| `v1.0.0` | ❌ No | no empieza con `release/` |
| `release/v1.0.0` | ❌ No | falta segmento de env |
| `release/dev/v1.0.0` | ❌ No | orden invertido (env antes que version) |

> **Nota**: la **strategy** (bluegreen/canary/rollingupdate) **NO** se especifica en el tag. Viene fija del `rollout.strategy` del chart Helm de cada app y la `task-wait-argocd` la auto-detecta en vivo.

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

### 3. Crear el secret en el cluster

```bash
kubectl create secret generic github-webhook-secret \
  --from-literal=secretToken=<el-valor-generado> \
  -n tekton-pipelines
```

### 4. Agregar el interceptor `github` antes del CEL

Editar `charts/pythonapps/templates/pipeline-templates/event-listener.yaml`:

```yaml
interceptors:
- ref:
    name: "github"
    kind: ClusterInterceptor
  params:
  - name: "secretRef"
    value:
      secretName: github-webhook-secret
      secretKey: secretToken
  - name: "eventTypes"
    value: ["push"]
- ref:
    name: "cel"
    kind: ClusterInterceptor
  params:
  - name: filter
    value: "body.ref.startsWith('refs/tags/release/') && body.ref.split('/').size() >= 4"
  # ...resto del CEL filter actual
```

Re-aplicar:

```bash
make tekton-apply
```

> Para la POC, el interceptor CEL sin HMAC es suficiente. La validación HMAC se justifica cuando el EventListener está expuesto a internet en producción.

---

## Troubleshooting

| Síntoma | Causa probable | Solución |
|---------|---------------|----------|
| ngrok dice `Your ngrok-agent version is too old` | Cliente < 3.20.0 | `ngrok update` (o `winget upgrade ngrok.ngrok`) |
| ngrok devuelve 404 al curlear | Host header incorrecto | Verificar que `make tunnel` haya seteado `--host-header=tekton-webhook.localhost` |
| GitHub muestra error 5xx en delivery | EventListener no está listo | `kubectl -n tekton-pipelines get pods -l eventlistener=github-tag-listener` → esperar a Running |
| GitHub muestra error de conexión | ngrok/smee no está corriendo | Reiniciar `make tunnel` o el cliente smee |
| PipelineRun no aparece | Tag con formato incorrecto | El tag debe ser `release/<semver>/<env>` exacto |
| PipelineRun falla en Stage 1 | El repo de la app no es accesible | Verificar que el repo sea público o agregar deploy key |
| PipelineRun falla en Stage 2 | Secret `dockerhub-credentials` faltante | `make secrets-apply DOCKERHUB_USER=... DOCKERHUB_TOKEN=...` |
| PipelineRun falla en Stage 3 con `URL rejected: Port number was not a decimal number` | Token con whitespace (\n, tab) en el secret, O bug pre-fix del token doble en URL | Recrear el secret usando `--from-literal` (sin trailing newline); el step ya hace `tr -d '[:space:]'` |
| PipelineRun falla en Stage 3 con `Authentication failed` | Token GitHub expirado o sin permisos `repo` | Generar PAT nuevo en GitHub → Settings → Developer settings → Personal access tokens; actualizar el secret `github-token` |
| PipelineRun falla en Stage 4 (timeout esperando sync) | ArgoCD no recibió el refresh, o el repo gitops no es accesible | Ver `kubectl -n argocd logs deployment/argocd-repo-server`; verificar que el commit del bump esté en `main` del gitops |
| Pipeline corre verde pero no se desplegó nada | (Era el race condition — ya fixed) Si lo ves: el Pipeline no está pasando `commit-sha` a `wait-argocd` | Verificar que `task-bump-gitops` declare `results: - name: commit-sha` y que `pipeline-pythonapps.yaml` mapee `tasks.bump-gitops.results.commit-sha` → `wait-argocd.params.expected-commit-sha` |
