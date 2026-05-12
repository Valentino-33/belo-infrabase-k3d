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

# 3. Bootstrap ArgoCD + aplicar pipeline Tekton
make bootstrap

# 4. (Opcional) Ver UIs en el browser
make port-forward
```

> `make all` hace cluster-up + bootstrap en un solo comando, pero omite el paso de secretos.
> Corré `make secrets-apply ...` antes de disparar el primer pipeline.

---

## Tear down y volver a levantar

```bash
make cluster-down   # elimina cluster y volúmenes Docker
make cluster-up     # levanta de cero — los addons se reinstalan automáticamente
make secrets-apply DOCKERHUB_USER=<user> DOCKERHUB_TOKEN=<token> GITHUB_TOKEN=<token>
make bootstrap
```

---

## Referencia rápida de targets

| Target | Qué hace | Cuándo usarlo |
|--------|----------|---------------|
| `make help` | Lista todos los targets | Siempre |
| `make all` | cluster-up + bootstrap completo | Atajo para la primera vez |
| `make cluster-up` | Crea cluster k3d + labels + addons | Primera vez o después de cluster-down |
| `make cluster-down` | Elimina cluster y volúmenes | Teardown |
| `make cluster-status` | Estado del cluster: nodos, apps, rollouts | Debug |
| `make addons` | Instala/actualiza todos los addons Helm | Re-instalar addons sin recrear el cluster |
| `make helm-repos` | Agrega y actualiza repos Helm | Lo hace automáticamente cluster-up |
| `make bootstrap` | Aplica root ArgoCD App + pipeline Tekton | Después de cluster-up |
| `make tekton-apply` | Aplica Tasks, Pipeline y Triggers | Re-aplicar si cambian los templates |
| `make secrets` | Muestra instrucciones para crear secretos | Referencia |
| `make secrets-apply` | Crea secretos de DockerHub y GitHub | Antes del primer pipeline-run |
| `make pipeline-run` | Dispara pipeline manual | Testing del CI/CD sin webhook |
| `make port-forward` | Port-forward a todas las UIs | Acceso local a ArgoCD, Grafana, etc. |
| `make argocd-password` | Muestra password inicial de ArgoCD | Login en la UI |
| `make demo-bluegreen` | Guía interactiva de demo BlueGreen | Demo de api01 |
| `make demo-canary` | Guía interactiva de demo Canary | Demo de api02 |
| `make rollout-status` | Estado del rollout | Monitor de deployment |
| `make rollout-promote` | Promover rollout al siguiente step | BlueGreen/Canary manual |
| `make rollout-abort` | Abortar rollout (rollback) | Si algo sale mal |
| `make build` | Build local de imagen Docker | Testing sin CI |
| `make push` | Push de imagen a DockerHub | Testing sin CI |
| `make build-push` | Build + push en un paso | Ídem |
| `make load-test-smoke` | Smoke test k6 | Validar que la app responde |
| `make load-test-bluegreen` | Load test contra preview service | Testing BlueGreen |
| `make load-test-canary` | Load test de canary | Testing Canary |

---

## Variables override-ables

| Variable | Default | Ejemplo |
|----------|---------|---------|
| `APP` | `webserver-api01` | `make pipeline-run APP=webserver-api02 TAG=v1.0.0` |
| `TAG` | `latest` | `make build TAG=v0.2.0` |
| `DOCKERHUB_USER` | `valentinobruno` | `make build DOCKERHUB_USER=miuser` |
| `NAMESPACE` | `dev` | `make rollout-status NAMESPACE=staging` |

---

## URLs de las UIs (todas accesibles vía nginx en puerto 8888)

> **Pre-requisito**: agregar las entradas al archivo `hosts` de Windows
> (`C:\Windows\System32\drivers\etc\hosts`) con permisos de Administrador:
> ```
> 127.0.0.1 argocd.localhost
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
| ArgoCD | http://argocd.localhost:8888 | admin / `make argocd-password` |
| Grafana | http://grafana.localhost:8888 | admin / belo-challenge |
| Kibana | http://kibana.localhost:8888 | sin auth (security off en dev) |
| Headlamp | http://headlamp.localhost:8888 | token: ver abajo |
| api01 (stable) | http://api01.localhost:8888 | — |
| api01 (preview) | http://preview-api01.localhost:8888 | — |
| api02 (stable) | http://api02.localhost:8888 | — |
| api02 (preview) | http://preview-api02.localhost:8888 | — |
| Tekton webhook | http://tekton-webhook.localhost:8888 | GitHub secret configurado en webhook |

### Token de Headlamp

El token se genera con el `ServiceAccount` que instala el chart y expira en 1 hora:

```bash
kubectl create token headlamp --namespace kube-system
```

Pegá el token en la pantalla de login de Headlamp. Para regenerarlo cuando expire, ejecutá el mismo comando.
