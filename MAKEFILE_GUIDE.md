# Guía rápida del Makefile — belo-infrabase-k3d

> Cluster local k3d que replica el stack de EKS para desarrollo sin AWS.
> Todos los comandos desde la **raíz de este repo**.

---

## Flujo completo — levantar desde cero

```bash
# 1. Levantar cluster k3d + instalar todos los addons
make cluster-up

# 2. Crear secretos (Kaniko + GitHub) — ver instrucciones
make secrets
# o directamente:
make secrets-apply DOCKERHUB_USER=<user> DOCKERHUB_TOKEN=<token> GITHUB_TOKEN=<token>

# 3. Publicar las imágenes iniciales (las apps no levantan sin esto)
docker login -u <user> --password-stdin <<< "<token>"
make images-initial DOCKERHUB_USER=<user>

# 4. Bootstrap ArgoCD + aplicar pipeline Tekton
make bootstrap

# 5. Instalar Tekton Dashboard (UI visual de PipelineRuns — tipo OpenShift)
kubectl apply -f https://storage.googleapis.com/tekton-releases/dashboard/latest/release.yaml
kubectl apply -f manifests/tekton/dashboard-ingress.yaml

# 6. (Opcional) Exponer el EventListener a internet para recibir webhooks
make tunnel
```

> `make all` hace cluster-up + bootstrap en un solo comando, pero **omite** los pasos 2, 3 y 5.
> Corré `make secrets-apply`, `make images-initial` y la instalación del Dashboard **antes** del primer pipeline.

---

## Tear down y volver a levantar

```bash
make cluster-down   # elimina cluster y volúmenes Docker
make cluster-up     # levanta de cero — los addons se reinstalan automáticamente
make secrets-apply DOCKERHUB_USER=<user> DOCKERHUB_TOKEN=<token> GITHUB_TOKEN=<token>
make images-initial DOCKERHUB_USER=<user>
make bootstrap
# Re-instalar Tekton Dashboard (no se persiste con cluster-down)
kubectl apply -f https://storage.googleapis.com/tekton-releases/dashboard/latest/release.yaml
kubectl apply -f manifests/tekton/dashboard-ingress.yaml
```

> **Importante después de cualquier reinstalación de Tekton**: el namespace `tekton-pipelines` vuelve a `pod-security.kubernetes.io/enforce=restricted`. Hay que bajarlo a `baseline` para que kaniko funcione:
> ```bash
> kubectl label namespace tekton-pipelines \
>   pod-security.kubernetes.io/enforce=baseline --overwrite
> ```

---

## Referencia rápida de targets

| Target | Qué hace | Cuándo usarlo |
|--------|----------|---------------|
| `make help` | Lista todos los targets | Siempre |
| `make all` | cluster-up + bootstrap completo | Atajo para la primera vez |
| `make cluster-up` | Crea cluster k3d + labels + addons | Primera vez o después de cluster-down |
| `make cluster-stop` | **Apaga preservando estado** (etcd, PVCs, configs) | Final del día — uso diario |
| `make cluster-start` | **Reanuda** cluster apagado con cluster-stop | Al día siguiente — uso diario |
| `make cluster-down` | Elimina cluster y volúmenes (destructivo) | Teardown completo |
| `make cluster-status` | Estado del cluster: nodos, apps, rollouts | Debug |
| `make cluster-info` | URLs de UIs, passwords, comandos útiles | Quick reference |
| `make addons` | Instala/actualiza todos los addons Helm | Re-instalar addons sin recrear el cluster |
| `make helm-repos` | Agrega y actualiza repos Helm | Lo hace automáticamente cluster-up |
| `make bootstrap` | Aplica root ArgoCD App + pipeline Tekton | Después de cluster-up |
| `make tekton-apply` | Aplica Tasks, Pipeline y Triggers | Re-aplicar si cambian los templates |
| `make secrets` | Muestra instrucciones para crear secretos | Referencia |
| `make secrets-apply` | Crea secretos de DockerHub y GitHub | Antes del primer pipeline-run |
| `make pipeline-run` | Dispara pipeline manual | Testing del CI/CD sin webhook |
| `make tunnel` | ngrok con `--host-header=tekton-webhook.localhost` | Exponer EventListener a internet |
| `make images-initial` | Build + push de api01:latest y api02:latest | Antes del bootstrap |
| `make port-forward` | Port-forward a todas las UIs | Acceso local de fallback (si nginx no anda) |
| `make argocd-password` | Muestra password inicial de ArgoCD | Login en la UI |
| `make demo-bluegreen` | Guía interactiva de demo BlueGreen | Demo de api01 |
| `make demo-canary` | Guía interactiva de demo Canary | Demo de api02 |
| `make rollout-status` | Estado del rollout | Monitor de deployment |
| `make rollout-promote` | Promover rollout al siguiente step | BlueGreen/Canary manual |
| `make rollout-abort` | Abortar rollout (rollback) | Si algo sale mal |
| `make build` | Build local de imagen Docker | Testing sin CI |
| `make push` | Push de imagen a DockerHub | Testing sin CI |
| `make build-push` | Build + push en un paso | Ídem |
| `make load-test-smoke` | Smoke test k6 (clona el repo de la app a `/tmp` y corre k6) | Validar que la app responde |
| `make load-test-bluegreen` | Load test contra preview service (api01) | Testing BlueGreen |
| `make load-test-canary` | Load test de canary (api02) | Testing Canary |

---

## Variables override-ables

| Variable | Default | Ejemplo |
|----------|---------|---------|
| `APP` | `webserver-api01` | `make pipeline-run APP=webserver-api02 TAG=v1.0.0` |
| `TAG` | `latest` | `make build TAG=v0.2.0` |
| `ENV` | `dev` | `make rollout-status APP=webserver-api01 ENV=staging` |
| `DOCKERHUB_USER` | `valentinobruno` | `make build DOCKERHUB_USER=miuser` |
| `APP_REPO_BASE` | `https://github.com/Valentino-33` | `make load-test-smoke APP_REPO_BASE=https://github.com/otrouser` (de dónde clonar el repo de la app para los load tests locales) |

El `NAMESPACE` se computa automáticamente como `$(APP)-$(ENV)` (e.g., `webserver-api01-dev`).

---

## URLs de las UIs (todas accesibles vía nginx en puerto 8888)

> **Pre-requisito**: agregar las entradas al archivo `hosts` de Windows
> (`C:\Windows\System32\drivers\etc\hosts`) con permisos de Administrador:
> ```
> 127.0.0.1 argocd.localhost
> 127.0.0.1 tekton.localhost
> 127.0.0.1 kibana.localhost
> 127.0.0.1 grafana.localhost
> 127.0.0.1 headlamp.localhost
> 127.0.0.1 api01.localhost
> 127.0.0.1 preview-api01.localhost
> 127.0.0.1 api02.localhost
> 127.0.0.1 preview-api02.localhost
> 127.0.0.1 tekton-webhook.localhost
> ```

| Servicio | URL | Credenciales |
|----------|-----|--------------|
| **ArgoCD** | http://argocd.localhost:8888 | admin / `make argocd-password` |
| **Tekton Dashboard** | http://tekton.localhost:8888 | — (sin auth en local) |
| Grafana | http://grafana.localhost:8888 | admin / belo-challenge |
| Kibana | http://kibana.localhost:8888 | sin auth (security off en dev) |
| Headlamp | http://headlamp.localhost:8888 | token: ver abajo |
| api01 (stable) | http://api01.localhost:8888 | — |
| api01 (preview) | http://preview-api01.localhost:8888 | — |
| api02 (stable) | http://api02.localhost:8888 | — |
| api02 (preview) | http://preview-api02.localhost:8888 | — |
| Tekton webhook | http://tekton-webhook.localhost:8888 | GitHub secret configurado en webhook |

### Token de Headlamp

Expira en 1 hora:

```bash
kubectl create token headlamp --namespace kube-system
```

### Direct links útiles del Tekton Dashboard

- Lista de PipelineRuns: http://tekton.localhost:8888/#/pipelineruns
- Detalle de un run: http://tekton.localhost:8888/#/namespaces/tekton-pipelines/pipelineruns/`<app>-pipelinerun-<tag>`
  - Ejemplo: http://tekton.localhost:8888/#/namespaces/tekton-pipelines/pipelineruns/webserver-api01-pipelinerun-v1.2.0
- Lista de Tasks: http://tekton.localhost:8888/#/namespaces/tekton-pipelines/tasks
- Lista de EventListeners: http://tekton.localhost:8888/#/namespaces/tekton-pipelines/eventlisteners

### Nombre del PipelineRun

El TriggerTemplate (webhook) y el manifest manual usan **nombre determinístico**:

```
<app-name>-pipelinerun-<image-tag>
```

Ventajas:
- Trivial identificar qué deploy corresponde a cada run (sin sufijos random)
- Los pods de TaskRuns heredan el prefix: `webserver-api01-pipelinerun-v1.2.0-build-push-pod`
- Re-pushear el mismo tag falla con `AlreadyExists` (force a un semver nuevo o cleanup explícito)

Para limpiar un run y poder re-correr el mismo tag:

```bash
kubectl delete pipelinerun webserver-api01-pipelinerun-v1.2.0 -n tekton-pipelines
```

---

## Comandos de emergencia (fuera del Makefile)

### Forzar refresh de ArgoCD para que pickee cambios del gitops

```bash
kubectl annotate app webserver-api01-dev -n argocd \
  argocd.argoproj.io/refresh=normal --overwrite
```

### Promover un Rollout BlueGreen manualmente (sin el plugin)

```bash
kubectl patch rollout webserver-api01-dev -n webserver-api01-dev \
  --subresource=status --type=merge \
  -p '{"status":{"pauseConditions":null}}'
```

### Promover canary --full manualmente

```bash
kubectl patch rollout webserver-api02-dev -n webserver-api02-dev \
  --subresource=status --type=merge \
  -p '{"status":{"promoteFull":true}}'
```

### Abort cualquier Rollout

```bash
kubectl patch rollout <ROLLOUT> -n <NS> \
  --type=merge -p '{"spec":{"abort":true}}'
```

### Limpiar PipelineRuns viejos

```bash
# Borrar todos los PipelineRuns que ya terminaron (Succeeded o Failed)
kubectl delete pipelinerun -n tekton-pipelines \
  -l "tekton.dev/pipeline=pythonapps-pipeline" \
  --field-selector='status.completionTime!=null'
```
