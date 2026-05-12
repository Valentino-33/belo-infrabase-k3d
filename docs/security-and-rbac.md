# Security & RBAC

Documentación de los controles de seguridad en el pipeline: PodSecurity Standards a nivel namespace, `securityContext` a nivel Task, y los `ClusterRole`s que necesitan los ServiceAccounts del pipeline.

---

## 1. PodSecurity Standards

### Estado actual

El cluster tiene **PodSecurity Admission** activo (built-in en k3s ≥ 1.25). Cada namespace puede declarar un nivel: `privileged` (sin restricciones), `baseline` (sin hostPath/hostNetwork/privileged), o `restricted` (todo lo de baseline + runAsNonRoot, drop ALL capabilities, seccompProfile, etc.).

| Namespace | Enforce label | Razón |
|-----------|---------------|-------|
| `tekton-pipelines` | **`baseline`** | Kaniko necesita root. Baseline lo permite. El bootstrap inicial deja `restricted` (viene del `release.yaml` oficial de Tekton) — hay que bajar a `baseline` manualmente. |
| `webserver-api01-dev`, `webserver-api02-dev` | (sin label) | Apps no necesitan root; corren con la securityContext del helm chart |
| `argocd`, `argo-rollouts` | (sin label) | Sus charts oficiales declaran su propio securityContext |

### Configurar `tekton-pipelines` en baseline

```bash
kubectl label namespace tekton-pipelines \
  pod-security.kubernetes.io/enforce=baseline --overwrite

# Verificar
kubectl get ns tekton-pipelines -o jsonpath='{.metadata.labels}'
# Esperado: ..."pod-security.kubernetes.io/enforce":"baseline"...
```

> **Si re-instalás Tekton** (e.g., `kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml`), el label vuelve a `restricted` y kaniko falla con `PodAdmissionFailed`. Re-aplicá el comando de arriba.

### Por qué no `restricted`

Kaniko (`gcr.io/kaniko-project/executor`) escribe en `/` durante el build (snapshots del rootfs). Eso requiere:
- `runAsUser: 0` (root)
- `runAsNonRoot: false`
- Capacidad de escribir en filesystem del container sin restricciones

`restricted` PSA bloquea todo eso. No existe una imagen oficial rootless de kaniko. Las alternativas que mantienen `restricted` requieren reemplazar kaniko por BuildKit rootless — más invasivo de lo justificable para este proyecto.

### Por qué no `privileged`

`baseline` ya permite root (que es lo que kaniko necesita), pero bloquea:
- `hostPath` volumes
- `hostNetwork: true`
- `hostPID/hostIPC`
- `privileged: true`
- Capacidades `SYS_ADMIN` y similares

Eso es defense-in-depth contra un kaniko comprometido o una Task maliciosa.

---

## 2. `securityContext` por Task (defense in depth)

Aunque el namespace está en `baseline` (que permite root), las **5 Tasks no-kaniko** declaran su propio `stepTemplate.securityContext` compliant con `restricted`. Si en el futuro se quisiera mover el namespace a `restricted` y replace kaniko con BuildKit, esas Tasks ya cumplen.

```yaml
# En task-clone.yaml, task-bump-gitops.yaml, task-wait-argocd.yaml,
# task-load-test.yaml, task-promote-rollback.yaml:
spec:
  stepTemplate:
    env:
    - name: HOME
      value: /tekton/home
    securityContext:
      runAsNonRoot: true
      runAsUser: 65532
      runAsGroup: 65532
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
      seccompProfile:
        type: RuntimeDefault
```

### Por qué UID 65532

UID/GID 65532 es la convención común de **nonroot** en distros minimal (distroless, Wolfi, Chainguard). Los binarios de `alpine/git`, `mikefarah/yq`, `bitnami/kubectl`, y `grafana/k6` pueden ejecutarse bajo este UID sin problemas porque no necesitan files con ownership específico.

### Por qué `HOME=/tekton/home` siempre

Las imágenes minimal definen HOME=/root por default. Como nonroot, no se puede escribir a `/root`. Tekton monta `/tekton/home` como writable para cualquier UID y muchos scripts del pipeline necesitan HOME (e.g., git escribe `~/.gitconfig`).

### Caso especial: `task-promote-rollback`

El script descargaba originalmente `kubectl-argo-rollouts` plugin y lo instalaba en `/usr/local/bin` — falla como nonroot. La fix en su momento fue:

```sh
mkdir -p "$HOME/bin"
curl -sL ... -o "$HOME/bin/kubectl-argo-rollouts"
chmod +x "$HOME/bin/kubectl-argo-rollouts"
export PATH="$HOME/bin:$PATH"   # ← prepend en el script, NO override global en stepTemplate
```

Después se eliminó el plugin completo (ver [pipeline-internals.md → promote-or-rollback](pipeline-internals.md#6-promote-or-rollback)), pero el `export PATH` quedó por si una futura Task necesita binarios en $HOME/bin.

> **Trampa**: setear `env: PATH=...` a nivel `stepTemplate` (global del task) **rompe** `kubectl` en la imagen `bitnami/kubectl`, cuya bin vive en `/opt/bitnami/kubectl/bin` y no está en el PATH default. Hay que hacer el override solo en el script específico que lo necesita.

### Kaniko sí corre como root

`task-build-kaniko.yaml` **NO** declara `securityContext` — así hereda los defaults del pod template, que con `enforce=baseline` permiten root. El init container de Tekton (`prepare`, `place-scripts`) también corre como root (cosa que `restricted` bloquearía).

---

## 3. RBAC

### ServiceAccounts

Dos SAs viven en el namespace `tekton-pipelines`:

| SA | Quién la usa | Para qué |
|----|--------------|----------|
| `tekton-triggers-sa` | EventListener pod | Recibe el webhook, valida, crea PipelineRun |
| `tekton-pipeline-runner` | Cada PipelineRun pod (los workers de cada Task) | Ejecuta los kubectl del pipeline |

### `tekton-triggers-sa` (Role + ClusterRole)

**Role `tekton-triggers-role`** en `tekton-pipelines`:
```yaml
rules:
- apiGroups: ["triggers.tekton.dev"]
  resources: ["eventlisteners", "triggerbindings", "triggertemplates", "triggers", "interceptors"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["tekton.dev"]
  resources: ["pipelineruns", "pipelineresources"]
  verbs: ["create", "get", "list", "watch"]
- apiGroups: [""]
  resources: ["configmaps", "secrets", "serviceaccounts"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["persistentvolumeclaims"]
  verbs: ["create", "get", "list", "watch", "delete"]
```

**ClusterRole `tekton-triggers-clusterrole`** (cluster-scope para interceptors):
```yaml
rules:
- apiGroups: ["triggers.tekton.dev"]
  resources: ["clusterinterceptors", "clustertriggerbindings"]
  verbs: ["get", "list", "watch"]
```

### `tekton-pipeline-runner` (ClusterRole)

**ClusterRole `tekton-pipeline-runner-clusterrole`**:
```yaml
rules:
- apiGroups: ["argoproj.io"]
  resources: ["rollouts", "rollouts/status"]
  verbs: ["get", "list", "watch", "update", "patch"]
- apiGroups: ["argoproj.io"]
  resources: ["applications"]
  verbs: ["get", "list", "watch", "patch", "update"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch", "patch"]
- apiGroups: ["apps"]
  resources: ["deployments/rollback"]
  verbs: ["create"]
```

### Por qué cada permiso

| Permiso | Para qué |
|---------|----------|
| `rollouts: get, list, watch` | `wait-argocd` inspecciona spec/status del Rollout (image-tag, phase, strategy) |
| `rollouts: update, patch` | `promote-rollback` patchea `spec.abort=true` para abortar |
| `rollouts/status: patch` | `promote-rollback` patchea `status.pauseConditions=null` (BG) y `status.promoteFull=true` (canary) — **requiere `--subresource=status`** |
| `applications: get, list, watch` | `wait-argocd` lee `app.status.sync.status` y `app.status.sync.revision` |
| `applications: patch, update` | `wait-argocd` hace `kubectl annotate ... argocd.argoproj.io/refresh=normal` para forzar polling inmediato |
| `deployments: patch` | Legacy — para rollback de RollingUpdate via Deployment (no usado actualmente) |

### Por qué ClusterRole y no Role

Los Rollouts viven en namespaces específicos (`webserver-api01-dev`, `webserver-api02-dev`), distintos al namespace del pipeline (`tekton-pipelines`). Una `Role` solo da permisos dentro de su propio namespace, así que usamos `ClusterRole` + `ClusterRoleBinding` para que la SA del pipeline pueda actuar en cualquier namespace de apps.

Para producción, esto se ajustaría con:
- `RoleBinding` en cada namespace de app específico (en lugar de ClusterRoleBinding cluster-wide)
- O un OPA/Kyverno policy que limite qué resources puede tocar

### Verificación rápida

```bash
# Listar SAs del namespace
kubectl get sa -n tekton-pipelines

# Verificar permisos efectivos
kubectl auth can-i patch rollouts/status \
  --as=system:serviceaccount:tekton-pipelines:tekton-pipeline-runner \
  -n webserver-api01-dev
# Esperado: yes

kubectl auth can-i patch applications \
  --as=system:serviceaccount:tekton-pipelines:tekton-pipeline-runner \
  -n argocd
# Esperado: yes
```

---

## 4. Secrets del pipeline

### `dockerhub-credentials` (kubernetes.io/dockerconfigjson)

Usado por `task-build-kaniko` montado como Volume en `/kaniko/.docker/config.json`.

Creación:
```bash
kubectl create secret docker-registry dockerhub-credentials \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=<DOCKERHUB_USER> \
  --docker-password=<DOCKERHUB_TOKEN> \
  -n tekton-pipelines
```

### `github-token` (Opaque)

Usado por `task-bump-gitops` (steps clone-gitops y commit-and-push) montado como Volume read-only en `/workspace/git-token`.

Creación:
```bash
kubectl create secret generic github-token \
  --from-literal=token=<GITHUB_PAT> \
  -n tekton-pipelines
```

**Importante sobre el formato**: el script hace `tr -d '[:space:]'` antes de usar el token, así que un trailing newline no debería romper nada. Pero evitar `--from-file=token=<(echo "ghp_xxx")` porque `echo` mete newline; usar `--from-literal` o `printf` sin newline.

**Scopes del PAT** (mínimos):
- `repo` (para push al gitops repo)
- No necesita `workflow` ni `admin:org`

### `github-webhook-secret` (opcional, para HMAC)

Solo si activás validación HMAC en el EventListener (ver [webhook-setup.md → HMAC](webhook-setup.md#hmac-opcional--validar-origen-del-webhook)).

```bash
kubectl create secret generic github-webhook-secret \
  --from-literal=secretToken=<random-20-bytes> \
  -n tekton-pipelines
```

---

## 5. Network policies (futuro)

Actualmente **no hay NetworkPolicies** definidas. En un cluster de producción se debería:

- Restringir egress del namespace `tekton-pipelines` solo a: `github.com:443`, `*.docker.io:443`, `*.googleapis.com:443` (kaniko base images), `argocd.svc:443`, los namespaces de apps
- Restringir ingress al `EventListener` desde el ingress-nginx solamente
- Aislar `webserver-api01-dev` y `webserver-api02-dev` entre sí (no necesitan comunicarse)

Implementación pendiente con `Cilium NetworkPolicy` o el built-in `NetworkPolicy` (requiere CNI compatible — k3d con flannel default no soporta).

---

## 6. Resumen — checklist de seguridad

| Capa | Implementado | Comentario |
|------|--------------|------------|
| PodSecurity Admission (PSA) namespace | ✅ `tekton-pipelines=baseline` | Bloquea hostPath/hostNetwork/privileged |
| securityContext compliant con `restricted` en Tasks | ✅ 5 de 6 Tasks (no kaniko) | UID 65532, drop ALL, seccompProfile=RuntimeDefault |
| Sin descargas externas en runtime | ✅ kubectl patch directo en lugar del plugin | Reduce attack surface y tiempo |
| Token GitHub en Secret (no en image/spec) | ✅ secret `github-token` | Montado read-only |
| RBAC mínimo por SA | ✅ ClusterRole por uso específico | Sin `cluster-admin` ni `*` permisos |
| Validación HMAC del webhook | ⚠️ Opcional | Documentado pero no activado por default |
| NetworkPolicies | ❌ No implementado | Trabajo futuro |
| External Secrets Operator | ❌ No implementado | Tokens viven como K8s Secrets — para prod migrar a Vault/AWS SM |
| Image signing / cosign | ❌ No implementado | Trabajo futuro |
| Pod admission con OPA/Kyverno | ❌ No implementado | PSA es suficiente para esta POC |
