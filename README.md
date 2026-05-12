# belo-infrabase-k3d

Stack completo de CI/CD y deployment strategies sobre Kubernetes local con **k3d**.
Demuestra BlueGreen, Canary y RollingUpdate con ArgoRollouts, GitOps con ArgoCD, y pipelines de 6 stages completamente automatizados con Tekton — sin dependencias de nube.

---

## Índice

- [Stack de tecnologías](#stack-de-tecnologías)
- [Pre-requisitos](#pre-requisitos)
- [Levantado desde cero](#levantado-desde-cero)
- [Acceso a los dashboards](#acceso-a-los-dashboards)
- [Configurar el webhook](#configurar-el-webhook)
- [Correr el pipeline](#correr-el-pipeline)
- [Deployment strategies](#deployment-strategies)
- [Estructura del repo](#estructura-del-repo)
- [Documentación adicional](#documentación-adicional)

---

## Stack de tecnologías

| Capa | Tecnología |
|------|-----------|
| Kubernetes local | k3d (k3s en Docker) |
| Deployment strategies | Argo Rollouts — BlueGreen, Canary, RollingUpdate |
| GitOps | ArgoCD (apps-of-apps) |
| CI/CD | Tekton Pipelines + Triggers |
| Build de imágenes | Kaniko (sin Docker daemon) |
| Ingress | nginx-ingress (NodePort :8888→:80) |
| Logging | EFK — Elasticsearch + Fluent-bit + Kibana |
| Monitoring | kube-prometheus-stack — Prometheus + Grafana |
| Dashboard | Headlamp |
| Load testing | k6 (in-cluster) |
| Apps de demo | Python FastAPI + structlog + prometheus-client |
| Packaging | Helm (chart maestro `pythonapps`) |
| Storage | local-path (provisioner nativo de k3s) |

---

## Pre-requisitos

| Herramienta | Versión mínima | Instalación en Windows |
|-------------|----------------|------------------------|
| Docker Desktop | 24+ | https://docs.docker.com/get-docker/ |
| k3d | v5.6+ | `winget install k3d` |
| kubectl | 1.28+ | `winget install Kubernetes.kubectl` |
| helm | v3.14+ | `winget install Helm.Helm` |
| make | cualquiera | incluido en Git Bash / `winget install GnuWin32.Make` |
| k6 (opcional) | v0.50+ | `winget install k6` |
| tkn CLI (opcional) | latest | `winget install tektoncd.cli` |
| ngrok (para webhook) | latest | `winget install ngrok.ngrok` |

> **Recursos mínimos**: 8 GB RAM, 4 CPU cores, 20 GB de disco libre.
>
> **Windows**: después de instalar k3d con winget, reiniciá la terminal para que el PATH se actualice.
> Si usás `make` desde Git Bash, todos los comandos de esta guía asumen Git Bash o WSL2.
>
> **Docker Desktop debe estar corriendo** antes de cualquier comando. Si `k3d cluster list` da error de conexión, abrí Docker Desktop y esperá a que esté activo.
>
> **Token de DockerHub**: creá un Access Token en hub.docker.com → Account Settings → Security (no uses la contraseña directamente).

---

## Levantado desde cero

> **Antes de empezar**: asegurate de que Docker Desktop esté corriendo. Sin el daemon de Docker activo, k3d no puede crear el cluster.

```bash
# 1. Clonar este repo
git clone https://github.com/Valentino-33/belo-infrabase-k3d
cd belo-infrabase-k3d

# 2. Crear el cluster k3d e instalar todos los addons (~10-15 min)
make cluster-up
```

```bash
# 3. Crear los secretos necesarios para el pipeline
make secrets-apply \
  DOCKERHUB_USER=<tu-usuario-dockerhub> \
  DOCKERHUB_TOKEN=<tu-token-dockerhub> \
  GITHUB_TOKEN=<tu-personal-access-token>
```

```bash
# 4. Publicar las imágenes iniciales en Docker Hub
#    (ArgoCD las necesita para levantar los pods la primera vez)
docker login -u <tu-usuario-dockerhub> --password-stdin <<< "<tu-token-dockerhub>"
make images-initial DOCKERHUB_USER=<tu-usuario-dockerhub>
```

```bash
# 5. Bootstrap: aplicar root Application de ArgoCD + manifests de Tekton
make bootstrap
```

```bash
# 6. Verificar el estado (esperar ~2 min después del bootstrap)
make cluster-status
make cluster-info
```

Después de `make bootstrap`, ArgoCD sincroniza las apps automáticamente. En ~2 minutos todos los pods deben estar corriendo:

```bash
kubectl -n argocd get applications
# NAME                   SYNC STATUS   HEALTH STATUS
# apps-of-apps           Synced        Healthy
# gitops-core-dev        Synced        Healthy
# webserver-api01-dev    Synced        Healthy
# webserver-api02-dev    Synced        Healthy

kubectl -n dev get pods
# NAME                                   READY   STATUS    RESTARTS   AGE
# webserver-api01-dev-xxx-xxx            1/1     Running   0          2m
# webserver-api02-dev-xxx-xxx            1/1     Running   0          2m
```

> **Nota sobre Kibana**: el pod de Kibana puede tardar hasta 3-5 minutos en responder luego de que aparezca como `Running`. Es normal — el proceso de inicialización de Kibana 8.x es lento.

> **Nota sobre `make all`**: hace `cluster-up + bootstrap` en un solo comando, pero **omite** el paso de secretos y el push de imágenes iniciales. Corré siempre los pasos 3 y 4 antes o las apps van a quedar en `ImagePullBackOff`.

---

## Acceso a los dashboards

### 1. Agregar entradas al archivo hosts

Editar `C:\Windows\System32\drivers\etc\hosts` **como Administrador**:

```
127.0.0.1 argocd.localhost
127.0.0.1 grafana.localhost
127.0.0.1 kibana.localhost
127.0.0.1 headlamp.localhost
127.0.0.1 api01.localhost
127.0.0.1 preview-api01.localhost
127.0.0.1 api02.localhost
127.0.0.1 preview-api02.localhost
127.0.0.1 tekton-webhook.localhost
```

### 2. Abrir en el browser

Todos los servicios son accesibles en el puerto **:8888** a través de nginx-ingress:

| Servicio | URL | Credenciales |
|----------|-----|--------------|
| **ArgoCD** | http://argocd.localhost:8888 | admin / `make argocd-password` |
| **Grafana** | http://grafana.localhost:8888 | admin / belo-challenge |
| **Kibana** | http://kibana.localhost:8888 | sin autenticación (dev) |
| **Headlamp** | http://headlamp.localhost:8888 | token: ver abajo |
| **api01** (stable) | http://api01.localhost:8888 | — |
| **api01** (preview) | http://preview-api01.localhost:8888 | — |
| **api02** (stable) | http://api02.localhost:8888 | — |
| **api02** (preview) | http://preview-api02.localhost:8888 | — |
| **Tekton webhook** | http://tekton-webhook.localhost:8888 | configurar en GitHub |

**Token de Headlamp** (expira en 1 hora):

```bash
kubectl create token headlamp --namespace kube-system
```

---

## Configurar el webhook

Para que el pipeline se dispare automáticamente al pushear un tag de Git, necesitás exponer el EventListener de Tekton a internet.

### Opción rápida — ngrok

```bash
# Iniciar tunnel (en una terminal aparte)
make tunnel

# ngrok muestra: Forwarding https://abc123.ngrok-free.app → http://localhost:8888
# Copiar esa URL
```

En GitHub → repo de la app → **Settings → Webhooks → Add webhook**:
- **Payload URL**: `https://abc123.ngrok-free.app`
- **Content type**: `application/json`
- **Events**: `Just the push event`

Ver la [guía completa de webhook](docs/webhook-setup.md) para otras opciones (smee.io, IP directa, HMAC).

---

## Correr el pipeline

### Automático (vía webhook + git tag)

El formato del tag es `<env>/<strategy>/<semver>`:

```bash
# Ir al repo de la app
cd /ruta/a/webserver-api01

# BlueGreen
git tag dev/bluegreen/v1.2.0
git push origin dev/bluegreen/v1.2.0

# Canary
git tag dev/canary/v1.2.0
git push origin dev/canary/v1.2.0

# Rolling Update
git tag dev/rollingupdate/v1.2.0
git push origin dev/rollingupdate/v1.2.0
```

El tag dispara el webhook → CEL extrae `env`, `strategy` e `image_tag` → crea el PipelineRun.

> **Importante**: el nombre del repo de la app en GitHub debe coincidir con el `app-name` en ArgoCD (`webserver-api01` / `webserver-api02`).

### Manual (sin webhook)

```bash
# Sin pushear tags — dispara el pipeline directamente
make pipeline-run APP=webserver-api01 TAG=v1.2.0

# Monitorear
tkn pipelinerun logs -n tekton-pipelines --last -f
```

### Stages del pipeline

```
Stage 1  git-clone-app       → clona el repo de la app (tag ref exacto)
Stage 2  kaniko-build-push   → build Dockerfile + push a Docker Hub
Stage 3  bump-gitops-image   → yq actualiza image.tag y rollout.strategy → git commit+push
Stage 4  wait-argocd-sync    → espera ArgoCD Synced+Healthy y Rollout Paused/Healthy
Stage 5  run-load-test       → k6 contra preview/stable (siempre exits 0; emite outcome)
Stage 6  promote-rollback    → promote si outcome=passed; abort/undo si outcome=failed
```

---

## Deployment strategies

### Blue/Green — webserver-api01

La nueva versión (Green) se despliega en paralelo al stable (Blue). El tráfico no cambia hasta que el k6 pase y el Stage 6 ejecute el promote.

```bash
# Guía interactiva
make demo-bluegreen

# Monitorear el rollout
kubectl argo rollouts get rollout webserver-api01 -n dev --watch

# Verificar que el preview responde
curl http://preview-api01.localhost:8888/version

# El pipeline promueve automáticamente si k6 pasa
# Si querés hacerlo a mano:
make rollout-promote APP=webserver-api01

# Rollback
make rollout-abort APP=webserver-api01
```

### Canary — webserver-api02

El tráfico se mueve gradualmente: **5% → 25% → 50% → promote-full** con k6 en cada step.

```bash
# Guía interactiva
make demo-canary

# Monitorear la distribución de tráfico en vivo
kubectl argo rollouts get rollout webserver-api02 -n dev --watch

# Avanzar steps manualmente (si no usás el pipeline automatizado)
make rollout-promote APP=webserver-api02  # step 5%→25%
make rollout-promote APP=webserver-api02  # step 25%→50%
make rollout-promote APP=webserver-api02  # step 50%→100%

# Rollback en cualquier momento
make rollout-abort APP=webserver-api02
```

### RollingUpdate — cualquier app

Deployment estándar. Los pods se actualizan uno a uno sin pauses. El pipeline corre un smoke test al final y hace rollback si falla.

```bash
git tag dev/rollingupdate/v1.2.0
git push origin dev/rollingupdate/v1.2.0
# El Rollout completa directamente (fase Healthy, sin Paused)
```

---

## Estructura del repo

```
belo-infrabase-k3d/
├── Makefile                            ← Entrada principal (make help)
├── k3d/
│   └── config.yaml                     ← Definición del cluster k3d (4 nodos)
├── apps/
│   ├── webserver-api01/
│   │   ├── src/                        ← Código Python FastAPI
│   │   ├── Dockerfile
│   │   └── loadtest/
│   │       ├── smoke.js
│   │       ├── load-bluegreen.js
│   │       └── load-canary.js
│   └── webserver-api02/
│       ├── src/
│       ├── Dockerfile
│       └── loadtest/
│           ├── smoke.js
│           ├── load-bluegreen.js
│           └── load-canary.js
├── charts/
│   └── pythonapps/                     ← Helm chart maestro
│       ├── templates/
│       │   ├── rollout.yaml            ← ArgoRollout (BG/Canary/Rolling)
│       │   ├── service.yaml            ← stable + preview (siempre)
│       │   ├── ingress.yaml            ← stable + preview (siempre)
│       │   └── pipeline-templates/     ← Tekton Tasks, Pipeline, Triggers
│       └── apps/
│           ├── webserver-api01/
│           │   ├── build-time/app.yaml ← image.repository, rollout defaults
│           │   └── dev/values-*.yaml   ← image.tag actualizado por el pipeline
│           └── webserver-api02/
│               ├── build-time/app.yaml
│               └── dev/values-*.yaml
├── gitops/
│   ├── apps-of-apps.yaml               ← Root Application de ArgoCD
│   └── gitops-core-dev/
│       ├── webserver-api01.yaml        ← Application CR (apunta a charts/pythonapps)
│       └── webserver-api02.yaml
├── helm/addons/                        ← Values de cada addon Helm
│   ├── argocd/values.yaml
│   ├── nginx-ingress/values.yaml
│   ├── elasticsearch/values.yaml
│   ├── fluent-bit/values.yaml
│   ├── kibana/values.yaml
│   ├── kube-prometheus/values.yaml
│   └── headlamp/values.yaml
├── manifests/
│   ├── argocd/bootstrap.yaml           ← Root Application (make bootstrap)
│   └── tekton/
│       ├── pipelinerun-manual.yaml     ← Pipeline manual sin webhook
│       └── github-secret.yaml.example ← Template de secret de GitHub
└── docs/
    ├── architecture.md                 ← Diagramas Mermaid de la arquitectura
    ├── demo-guide.md                   ← Guía paso a paso de cada estrategia
    └── webhook-setup.md               ← Configuración del webhook GitHub → Tekton
```

---

## Troubleshooting

### Pods en `ImagePullBackOff` al hacer bootstrap

Las imágenes `<dockerhub-user>/api01:latest` y `api02:latest` deben existir en Docker Hub **antes** de que ArgoCD haga el primer sync. Si los pods arrancan en error:

```bash
# Verificar el error exacto
kubectl -n dev describe pod <pod-name> | grep -A5 "Events:"

# Solución: publicar las imágenes y forzar un retry
make images-initial DOCKERHUB_USER=<tu-usuario>
kubectl -n dev delete pod --all   # fuerza re-pull inmediato
```

### Kibana en `CrashLoopBackOff` o `OOMKilled`

Kibana 8.x requiere al menos **1Gi de RAM**. Si el pod crashea:

```bash
# Ver el error exacto
kubectl -n logging logs -l app=kibana --tail=20

# Si dice "definition for this key is missing" con xpack.security.enabled:
# Esa opción fue eliminada en Kibana 8.x — ya está corregida en helm/addons/kibana/values.yaml

# Re-aplicar con los valores correctos
helm upgrade --install kibana elastic/kibana \
  --namespace logging \
  --values helm/addons/kibana/values.yaml \
  --no-hooks --timeout 6m
```

### ArgoCD muestra `OutOfSync` para las webserver apps

Si ambas apps (api01-dev, api02-dev) muestran `SharedResourceWarning` o `OutOfSync`:

```bash
# Forzar refresh desde Git
kubectl -n argocd annotate app webserver-api01-dev argocd.argoproj.io/refresh=normal --overwrite
kubectl -n argocd annotate app webserver-api02-dev argocd.argoproj.io/refresh=normal --overwrite
```

Los recursos de Tekton (Tasks, Pipeline, EventListener) son gestionados exclusivamente por `make tekton-apply` y **no** por ArgoCD. Si los Tekton resources fueron prunados:

```bash
make tekton-apply
```

### EventListener no disponible (`MinimumReplicasUnavailable`)

Normal durante el primer minuto después de `make tekton-apply`. Esperá 60 segundos y verificá:

```bash
kubectl -n tekton-pipelines get eventlisteners
kubectl -n tekton-pipelines get pods | grep el-github
```

---

## Documentación adicional

| Documento | Descripción |
|-----------|-------------|
| [docs/architecture.md](docs/architecture.md) | Diagramas de topología del cluster, componentes y flujo CI/CD completo |
| [docs/demo-guide.md](docs/demo-guide.md) | Guía paso a paso para demostrar cada estrategia |
| [docs/webhook-setup.md](docs/webhook-setup.md) | Configuración del webhook GitHub → Tekton (ngrok, smee.io, HMAC) |
| [MAKEFILE_GUIDE.md](MAKEFILE_GUIDE.md) | Referencia completa de todos los targets del Makefile |
| [ROADMAP.md](ROADMAP.md) | Fases completadas y deuda técnica conocida |

---

## Comandos de referencia rápida

```bash
make help                                    # todos los targets
make cluster-up                              # crear cluster + instalar addons
make cluster-down                            # destruir todo
make cluster-status                          # nodos + apps + rollouts
make cluster-info                            # URLs, hosts, passwords
make secrets-apply DOCKERHUB_USER=x DOCKERHUB_TOKEN=x GITHUB_TOKEN=x
make bootstrap                               # aplicar ArgoCD root + Tekton
make tekton-apply                            # re-aplicar tasks/pipeline (si cambia el chart)
make argocd-password                         # password de ArgoCD
make pipeline-run APP=webserver-api01 TAG=v1.0.0
make demo-bluegreen                          # guía interactiva BlueGreen
make demo-canary                             # guía interactiva Canary
make rollout-status APP=webserver-api01      # estado en vivo
make rollout-promote APP=webserver-api01     # promover
make rollout-abort APP=webserver-api01       # rollback
make load-test-smoke APP=webserver-api01     # smoke test k6
make load-test-bluegreen                     # load test contra preview
make load-test-canary                        # load test canary
make tunnel                                  # ngrok → exponer EventListener
make port-forward                            # port-forward de fallback
```
