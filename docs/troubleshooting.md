# Troubleshooting

Problemas operativos del cluster y del pipeline, con **síntoma**, **causa raíz** y **solución**. Ordenados aproximadamente en el orden en que aparecerían al operar el sistema por primera vez.

---

## Setup & cluster

### `make tunnel` falla con "Your ngrok-agent version is too old"

**Síntoma**:
```
authentication failed: Your ngrok-agent version "3.3.1" is too old.
The minimum supported agent version for your account is "3.20.0".
ERR_NGROK_121
```

**Causa**: cuentas free de ngrok ahora requieren cliente ≥ 3.20.0.

**Fix**:
```bash
ngrok update                    # autoupdater oficial
# o
winget upgrade ngrok.ngrok      # si fue instalado con winget
```

### `make tunnel` arranca pero los webhooks devuelven 404

**Síntoma**: ngrok corre OK, pero curlear su URL pública devuelve 404 desde nginx.

**Causa**: ngrok no está reescribiendo el `Host` header al hostname que nginx-ingress espera (`tekton-webhook.localhost`).

**Fix**: asegurate de que el Makefile lance ngrok con `--host-header`:
```makefile
.PHONY: tunnel
tunnel:
	ngrok http --host-header=tekton-webhook.localhost 8888
```

Verificá con:
```bash
curl -i -X POST https://<ngrok-url>/ \
  -H "X-GitHub-Event: ping" \
  -H "Content-Type: application/json" \
  -d '{"zen":"test"}'
# Esperado: HTTP/1.1 202 Accepted
```

### Pods de la app en `ImagePullBackOff` después de `make bootstrap`

**Síntoma**: ArgoCD muestra las apps como `OutOfSync`/`Degraded`, pods en `ImagePullBackOff`.

**Causa**: las imágenes `<dockerhub-user>/api01:latest` y `api02:latest` no existen aún en Docker Hub.

**Fix**:
```bash
make images-initial DOCKERHUB_USER=<tu-usuario>
kubectl -n webserver-api01-dev delete pod --all
kubectl -n webserver-api02-dev delete pod --all
```

---

## Pipeline / Tekton

### `make pipeline-run` falla con `error from server (AlreadyExists)`

**Síntoma**:
```
error from server (AlreadyExists): error when creating "STDIN":
pipelineruns.tekton.dev "webserver-api01-pipelinerun-v1.2.0" already exists
```

**Causa**: el nombre del PipelineRun es **determinístico** (`<app>-pipelinerun-<tag>`). Si intentás correr dos veces con el mismo `TAG`, falla porque ya existe un PipelineRun con ese nombre.

Es comportamiento **intencional** — fuerza disciplina de semver y evita que un re-push silencioso sobrescriba el historial.

**Fix**:
- **Recomendado**: usar un semver nuevo (`v1.2.1`, `v1.3.0`, etc.)
- **Si querés re-correr el mismo tag**: eliminar el run viejo primero:
```bash
kubectl delete pipelinerun webserver-api01-pipelinerun-v1.2.0 -n tekton-pipelines
# Después re-correr con el mismo TAG
make pipeline-run APP=webserver-api01 TAG=v1.2.0
```

Lo mismo aplica al flujo webhook: re-pushear el mismo tag a GitHub dispara el EventListener, pero la creación del PipelineRun en el cluster falla con `AlreadyExists`. Para forzar re-corrida, borrar el run viejo y re-pushear (o usar `git push --force` + nuevo commit en el tag, pero entonces es más limpio bumpear el semver).

### `kubectl create -f -` falla con `unknown field "spec.podTemplate"`

**Síntoma**:
```
PipelineRun in version "v1" cannot be handled as a PipelineRun:
strict decoding error: unknown field "spec.podTemplate"
```

**Causa**: el manifest usa la forma de v1beta1 (`spec.podTemplate`). En `tekton.dev/v1` el `podTemplate` vive bajo `spec.taskRunTemplate.podTemplate`.

**Solución**: si escribís un PipelineRun manual custom, anidá `podTemplate` dentro de `taskRunTemplate`:
```yaml
# v1beta1 (inválido en v1)
spec:
  taskRunTemplate:
    serviceAccountName: ...
  podTemplate:
    tolerations: ...

# v1
spec:
  taskRunTemplate:
    serviceAccountName: ...
    podTemplate:
      tolerations: ...
```

### Stage 2 (kaniko) falla con `PodAdmissionFailed`

**Síntoma**:
```
pods "...-build-push-pod" is forbidden: violates PodSecurity "restricted:latest":
  allowPrivilegeEscalation != false (containers "prepare", "place-scripts", "step-build-and-push" must set securityContext.allowPrivilegeEscalation=false),
  unrestricted capabilities (...must set securityContext.capabilities.drop=["ALL"]),
  runAsNonRoot != true (...must set securityContext.runAsNonRoot=true),
  seccompProfile (...must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

**Causa**: el namespace `tekton-pipelines` tiene `pod-security.kubernetes.io/enforce=restricted` (viene del `release.yaml` oficial de Tekton). Kaniko necesita root y no puede cumplir restricted.

**Fix**:
```bash
kubectl label namespace tekton-pipelines \
  pod-security.kubernetes.io/enforce=baseline --overwrite
```

Ver [security-and-rbac.md → PodSecurity](security-and-rbac.md#1-podsecurity-standards) para el razonamiento.

### Stage 2 (kaniko) falla con `error resolving dockerfile path`

**Síntoma**:
```
Error: error resolving dockerfile path: please provide a valid path to a Dockerfile within the build context with --dockerfile
```

**Causa**: el `context` que `git-clone-app` deposita en `/workspace/source/src` no tiene un Dockerfile en el subdir que `kaniko` busca (`src/Dockerfile` por default).

**Fix**: verificá que el repo de la app tenga el Dockerfile en la **raíz** del repo. El clone hace `git clone <repo> /workspace/source/src`, así que la raíz del repo queda en `/workspace/source/src`, y el Dockerfile en `/workspace/source/src/Dockerfile`. El param `context=src` del kaniko Task apunta a ese directorio.

Si tu Dockerfile vive en un subdirectorio (e.g., `apps/api/Dockerfile`), pasá `--context=src/apps/api` al kaniko Task.

### Stage 2 (kaniko) falla con `BackendUnavailable: Cannot import 'setuptools.backends.legacy'`

**Síntoma**:
```
pip._vendor.pyproject_hooks._impl.BackendUnavailable: Cannot import 'setuptools.backends.legacy'
```

**Causa**: el `pyproject.toml` de la app declara `build-backend = "setuptools.backends.legacy:build"` que **no existe**. El nombre correcto es `setuptools.build_meta` (o `setuptools.build_meta:__legacy__` para el modo legacy).

**Fix**: en el repo de la app:
```toml
# pyproject.toml
[build-system]
requires = ["setuptools>=68"]
build-backend = "setuptools.build_meta"
```

### Stage 3 (bump-gitops) falla con `URL rejected: Port number was not a decimal number`

**Síntoma**:
```
fatal: unable to access 'https://x-access-token:ghp_xxx@github.com/org/repo/':
URL rejected: Port number was not a decimal number between 0 and 65535
```

**Causa**: una URL de git con el token inyectado dos veces (`https://x-access-token:NEW@x-access-token:OLD@github.com/...`). curl parsea el **primer** `@` como fin de userinfo e interpreta el resto como `host:port` no numérico. Pasa si un manifest custom reusa el remote del clone (que ya tiene token embebido) para volver a inyectar credenciales.

**Solución**: construir el push URL desde la URL pristine del repo (sin auth) e inyectar el token una sola vez — que es lo que hace `task-bump-gitops.yaml`:

```sh
PUSH_URL=$(echo "$(params.gitops-repo-url)" | \
  sed "s|https://|https://x-access-token:${TOKEN}@|")
git push "$PUSH_URL" main
```

### Stage 3 (bump-gitops) falla con `Authentication failed`

**Síntoma**:
```
fatal: Authentication failed for 'https://x-access-token:ghp_xxx@github.com/...'
```

**Causa**: el PAT expirando, revocado, o sin scope `repo`.

**Fix**:
1. Generar un PAT nuevo en GitHub → Settings → Developer settings → Personal access tokens → **scopes: `repo`**
2. Actualizar el secret:
```bash
kubectl create secret generic github-token \
  --from-literal=token=<NUEVO_PAT> \
  -n tekton-pipelines \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Promover un Rollout con el plugin no persiste — vuelve a Paused

**Síntoma**: corrés `kubectl argo rollouts promote ROLLOUT -n NS`, el comando reporta `rollout 'X' promoted` y exit 0, pero `kubectl get rollout` muestra `phase=BlueGreenPause` ~10s después.

**Causa**: el plugin `kubectl-argo-rollouts promote` no siempre persiste el cambio cuando ArgoCD está reconciliando el Rollout en paralelo.

**Solución**: usar `kubectl patch` directo al status subresource — los mismos patches que el plugin emite internamente ([`promote.go`](https://github.com/argoproj/argo-rollouts/blob/master/cmd/kubectl-argo-rollouts/commands/promote.go)). Es lo que hace el Stage 6 del pipeline:

```sh
# BG promote
kubectl patch rollout NAME -n NS --subresource=status --type=merge \
  -p '{"status":{"pauseConditions":null}}'

# Canary promote (full)
kubectl patch rollout NAME -n NS --subresource=status --type=merge \
  -p '{"status":{"promoteFull":true}}'

# Abort (cualquier strategy)
kubectl patch rollout NAME -n NS --type=merge \
  -p '{"spec":{"abort":true}}'
```

### Pipeline BG falla en Stage 5 — k6 reportó >5% errors

**Síntoma**: Stage 5 termina con `outcome=failed`, k6 imprime algo como `WARN[xxxx] http_req_failed.....: rate=0.07` (7% errors). Stage 6 aborta el rollout. Después del run, ves los pods `stable` (blue) sirviendo bien pero el `preview` (green) destruyéndose.

**Causa raíz**: 1000 VUs contra 1 solo pod (limit 300m CPU) saturan uvicorn antes de que el HPA reaccione. Mientras el HPA escala (~30-40s entre detección y nuevo pod ready), el pod existente responde con 5xx por overload. Si en esa ventana se acumulan >5% de errores → Stage 5 falla.

**Mitigación** (en `charts/pythonapps/apps/<app>/dev/values.yaml`):
- `replicas: 2` y `hpa.minReplicas: 2` — baseline de 2 pods = 600m CPU combinado
- `http_req_failed` threshold en `rate<0.10` en los load tests — tolera la ventana de scale-up

**Verificación**:
```bash
kubectl get rollout webserver-api01-dev -n webserver-api01-dev \
  -o jsonpath='{"replicas: "}{.spec.replicas}{"\n"}'
# Debe imprimir replicas: 2

kubectl get hpa webserver-api01-dev -n webserver-api01-dev \
  -o jsonpath='{"min: "}{.spec.minReplicas}{" max: "}{.spec.maxReplicas}{"\n"}'
# Debe imprimir min: 2 max: 5
```

### Quedaron 2 pods después de un release (stable + preview, mismo image-tag)

**Síntoma**: después de un release pipeline, `kubectl get pods` muestra dos pods de la misma versión. Uno está en el RS "stable", el otro en "preview".

**Causa**: el `scaleDownDelaySeconds: 30` en la spec del BG mantiene blue corriendo 30s después del switchover. **Es comportamiento esperado** — sirve como rollback ventana si la nueva versión falla justo después del promote.

Si pasados 30s siguen los 2 pods, entonces el switchover NO ocurrió. Ver:
```bash
kubectl argo rollouts get rollout <app>-dev -n <app>-dev
# Buscar:
#   Status:   ॥ Paused              ← problema: nunca promovió
#   Message:  BlueGreenPause
```

**Fix manual**:
```bash
# Para BG, promote manual:
kubectl patch rollout <app>-dev -n <app>-dev \
  --subresource=status --type=merge -p '{"status":{"pauseConditions":null}}'

# O si fue un release que falló y querés volver a stable:
kubectl patch rollout <app>-dev -n <app>-dev \
  --type=merge -p '{"spec":{"abort":true}}'
```

### Burn pipeline corre verde pero `outcome=failed` ("HPA no escaló")

**Síntoma**: `<app>-burn-<env>-XXXXX` termina Succeeded pero el result `outcome` dice `failed` y `max-replicas` queda igual a `baseline-replicas`.

**Causas probables**:
1. **HPA no está habilitado**: `kubectl get hpa <app>-<env> -n <app>-<env>` no devuelve nada → habilitar con `hpa.enabled: true` en `charts/pythonapps/apps/<app>/<env>/values.yaml`.
2. **`targetCPUUtilizationPercentage` muy alto**: si está en 90% y el cluster no llega, no escala. Ver dashboard de Grafana → "HPA CPU utilization vs target".
3. **`resources.requests.cpu` muy alto**: el HPA calcula utilización contra el `request`, no el `limit`. Si request=300m y el pod usa 150m, utilización = 50% (debajo del target 70%) → no escala. Bajar `requests.cpu` a 100m fuerza utilización alta más rápido.
4. **`maxReplicas: 1`**: el HPA querría escalar pero el max no se lo permite. Subir a 3-5.
5. **Cluster sin capacidad**: si los nodos no tienen CPU libre, los pods nuevos quedan `Pending`. `kubectl describe nodes` para verificar.

**Fix típico** para una POC:
```yaml
# charts/pythonapps/apps/webserver-api01/dev/values.yaml
hpa:
  enabled: true
  minReplicas: 1
  maxReplicas: 5
  targetCPUUtilizationPercentage: 70
resources:
  requests:
    cpu: "100m"   # bajo a propósito — el burn lleva utilización arriba rápido
    memory: "128Mi"
  limits:
    cpu: "300m"
    memory: "256Mi"
```

### Burn pipeline tag se ignora

**Síntoma**: `git push origin burn/dev` no dispara nada en Tekton, no aparece run en el dashboard.

**Causas**:
1. **EventListener no se aplicó después del cambio**: corré `make tekton-apply` para re-renderizar los triggers.
2. **El tag tiene segmentos extra**: `burn/dev/extra` no matchea (el filter exige exactamente 4 segmentos `refs/tags/burn/<env>`).
3. **Webhook sin path correcto**: el ngrok tunnel apunta a `tekton-webhook.localhost` y nginx-ingress lo enruta al EventListener. Verificar el delivery en GitHub → Webhooks → Recent Deliveries.

**Verificación**:
```bash
# Listar runs del burn pipeline
kubectl get pipelinerun -n tekton-pipelines -l pipeline=burn

# Logs del EventListener
kubectl -n tekton-pipelines logs -l eventlistener=github-tag-listener --tail=30
```

### Stage 5 (load-test) falla con `ERROR: ... no encontrado en el repo de la app`

**Síntoma**:
```
ERROR: /workspace/source/src/loadtest/load-canary.js no encontrado en el repo de la app.
       strategy=canary requiere el script: load-canary.js
       Agregalo al repo de la app en loadtest/load-canary.js y re-disparar.
```

**Causa**: el Helm chart de la app declara `rollout.strategy: canary` (o `bluegreen`), pero el repo de la app no tiene el `loadtest/<script>.js` correspondiente. El Stage 5 hace **fail-fast** en ese caso: emite `outcome=failed` y `exit 1` en lugar de promover un rollout sin testear.

**Fix**:
1. En el repo de la app, agregar el script faltante en `loadtest/`. Modelo:
```js
// loadtest/load-canary.js
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  stages: [
    { duration: '10s', target: 5 },
    { duration: '20s', target: 5 },
    { duration: '10s', target: 0 },
  ],
  thresholds: { http_req_duration: ['p(95)<600'], errors: ['rate<0.005'] },
};

const BASE_URL = __ENV.BASE_URL || 'http://<release>-stable.<ns>.svc.cluster.local:8080';

export default function () {
  const res = http.get(`${BASE_URL}/health`);
  check(res, { 'status 200': (r) => r.status === 200 });
  sleep(0.5);
}
```

2. Commit + push al repo de la app
3. Re-pushear el tag (con un semver nuevo, o borrar el PipelineRun viejo primero)

| strategy | Script requerido en `loadtest/` |
|----------|---------------------------------|
| `bluegreen` | `load-bluegreen.js` |
| `canary` | `load-canary.js` |
| `rollingupdate` | `smoke.js` |

### EventListener `MinimumReplicasUnavailable`

**Síntoma**: después de `make tekton-apply`, `kubectl get eventlisteners` muestra `Ready=False`.

**Causa**: el operator de Tekton Triggers tarda ~30-60s en crear el Deployment `el-github-tag-listener` y esperar a que el pod esté Ready.

**Fix**: esperá un minuto. Verificá con:
```bash
kubectl -n tekton-pipelines get pods -l eventlistener=github-tag-listener
kubectl -n tekton-pipelines describe eventlistener github-tag-listener
```

Si después de 2 minutos sigue Down, revisar logs:
```bash
kubectl -n tekton-pipelines logs deployment/tekton-triggers-controller --tail=50
```

---

## ArgoCD / GitOps

### ArgoCD muestra `OutOfSync` para apps después de tocar el chart

**Síntoma**: editaste algo en `charts/pythonapps/` pero ArgoCD no detecta el cambio.

**Causa**: ArgoCD polea cada ~3 minutos. Si no querés esperar:

**Fix**:
```bash
kubectl annotate application webserver-api01-dev -n argocd \
  argocd.argoproj.io/refresh=normal --overwrite
```

> Eso es exactamente lo que hace el `wait-argocd` Task en su step 1.

### Las apps siguen en `OutOfSync` después del refresh

**Síntoma**: el refresh muestra Sync OK pero el Rollout no se actualiza.

**Causa**: los Tekton CRDs (Tasks, Pipeline, EventListener) **no** están en el árbol de gitops que sigue ArgoCD — los gestiona `make tekton-apply`. Si una Task la prunaron desde ArgoCD por error:

**Fix**:
```bash
make tekton-apply
```

---

## Rollout / Argo Rollouts

> Para promover/abortar un Rollout manualmente con `kubectl patch`, ver [Promover un Rollout con el plugin no persiste](#promover-un-rollout-con-el-plugin-no-persiste--vuelve-a-paused) en la sección Pipeline / Tekton.

### Cómo determinar qué RS es stable vs preview/canary

```bash
kubectl get rollout ROLLOUT -n NS -o jsonpath='\
phase={.status.phase}
stableRS={.status.stableRS}
currentPodHash={.status.currentPodHash}
activeSelector={.status.blueGreen.activeSelector}
previewSelector={.status.blueGreen.previewSelector}
'
```

- `stableRS == currentPodHash` → no hay deploy en curso, Rollout Healthy
- `stableRS != currentPodHash AND phase=Paused` → green/canary RS levantado, esperando promote
- `activeSelector` apunta al RS que recibe tráfico productivo

### Pods quedan corriendo de versiones viejas

**Síntoma**: después de promover, ves pods del stable viejo seguir corriendo.

**Causa**: `scaleDownDelaySeconds: 30` en el BlueGreen spec. El stable viejo queda 30s después del promote (rollback ventana).

**Fix**: no hace falta — es comportamiento esperado. Pasados 30s los pods desaparecen.

---

## ngrok / webhook

### "Webhook delivery failed: connection refused"

**Síntoma**: GitHub Settings → Webhooks → Recent Deliveries muestra error.

**Causa**: ngrok no está corriendo o cerró la sesión.

**Fix**:
```bash
make tunnel
```

> ngrok free expira la sesión cada ~2 horas. Si necesitás algo más persistente, considerá smee.io (ver [webhook-setup.md → Opción B](webhook-setup.md#opción-b--smeeio-alternativa-gratuita)).

### Webhook llega pero Tekton no crea PipelineRun

**Síntoma**: GitHub muestra 202 en delivery, pero `kubectl get pipelineruns` no muestra runs nuevos.

**Causa probable**: tag con formato incorrecto. El EventListener tiene dos triggers con CEL filters:

- `release/<semver>/<envs>` → release pipeline (6 stages). Ejemplo: `release/v1.0.0/dev` o `release/v1.0.0/dev,staging`.
- `burn/<env>` → burn pipeline (2 stages, HPA capacity test). Ejemplo: `burn/dev`.

Cualquier otro formato es descartado por el CEL filter.

**Fix**: ver logs del EventListener:
```bash
kubectl -n tekton-pipelines logs -l eventlistener=github-tag-listener -f --tail=50
```

Si el CEL filter rechazó el evento, vas a ver algo como:
```
event 12345 didn't pass interceptor cel (filter)
```

Solución: usar uno de los formatos válidos:
```bash
git tag release/v1.0.0/dev && git push origin release/v1.0.0/dev                # release rápido (sin k6)
git tag release/v1.0.0/dev/loadtest=true && git push origin release/v1.0.0/dev/loadtest=true  # release + k6
git tag burn/dev && git push origin burn/dev                                    # burn (HPA test, pipeline aparte)
```

> El 5º segmento del tag de release debe matchear **exactamente** `loadtest=true` para activar k6. Cualquier otra variante (`loadtest=1`, `loadtest`, `LOADTEST=TRUE`) cae al default `false` (fail-closed). Más de 5 segmentos hace que el filtro CEL rechace el tag.

---

## Tekton Dashboard

### `tekton.localhost:8888` devuelve 404

**Síntoma**: la URL no carga, el browser muestra "site not found" o nginx 404.

**Causa(s)**:
1. Falta la entrada en hosts file: `127.0.0.1 tekton.localhost`
2. El Ingress no está aplicado
3. El Dashboard no está instalado

**Fix**:
```bash
# Verificar instalación del Dashboard
kubectl -n tekton-pipelines get deployment tekton-dashboard
# Si no existe:
kubectl apply -f https://storage.googleapis.com/tekton-releases/dashboard/latest/release.yaml

# Aplicar Ingress
kubectl apply -f manifests/tekton/dashboard-ingress.yaml

# Verificar el Ingress
kubectl -n tekton-pipelines get ingress tekton-dashboard
```

Luego agregá a `C:\Windows\System32\drivers\etc\hosts` (como Admin):
```
127.0.0.1 tekton.localhost
```

---

## Diagnóstico general

### Comandos rápidos

```bash
# Estado global del cluster
make cluster-status

# Todos los PipelineRuns con su outcome
kubectl -n tekton-pipelines get pipelineruns -o custom-columns=\
NAME:.metadata.name,SUCCEEDED:.status.conditions[0].status,REASON:.status.conditions[0].reason,AGE:.metadata.creationTimestamp

# Logs del PipelineRun más reciente (toda la pipeline)
tkn pipelinerun logs -n tekton-pipelines --last -f

# Sin tkn: logs de un step específico
POD=$(kubectl get taskrun -n tekton-pipelines -l tekton.dev/pipelineRun=<NAME> -o jsonpath='{.items[0].metadata.name}')-pod
kubectl logs -n tekton-pipelines $POD -c step-<step-name>

# Estado del Rollout
kubectl argo rollouts get rollout <NAME> -n <NS> --watch

# Eventos recientes del namespace de la app
kubectl get events -n <NS> --sort-by='.lastTimestamp' | tail -20

# Forzar re-sync de ArgoCD
kubectl annotate app <APP> -n argocd \
  argocd.argoproj.io/refresh=normal --overwrite
```

### Logs estructurados de la app

Las apps emiten JSON con structlog. Filtrar con `jq`:

```bash
kubectl logs -n webserver-api01-dev deployment/webserver-api01-dev | \
  jq 'select(.level == "error")'
```

O desde Kibana (`http://kibana.localhost:8888`): crear index pattern `k8s-*` y filtrar por `kubernetes.labels.app_kubernetes_io_name: webserver-api01-dev`.
