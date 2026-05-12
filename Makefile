# ──────────────────────────────────────────────────────────────────────────────
# belo-infrabase-k3d — Makefile
# ──────────────────────────────────────────────────────────────────────────────
# Cluster local k3d con el stack completo: ArgoRollouts + Tekton + ArgoCD + EFK.
# make cluster-up  → levanta todo en ~10 minutos
# make cluster-down → limpia todo
# ──────────────────────────────────────────────────────────────────────────────

SHELL := /bin/bash
# Fijar contexto k3d para evitar interferencia con sesión EKS
export KUBECONFIG := $(HOME)/.kube/config
K3D_CONTEXT := k3d-belo-challenge
.DEFAULT_GOAL := help

K3D_CLUSTER   := belo-challenge
DOCKERHUB_USER ?= valentinobruno
APP            ?= webserver-api01
TAG            ?= latest
ENVS          ?= dev
# Namespace = app + env (e.g. webserver-api01-dev). Override: make rollout-status APP=webserver-api02 ENV=staging
ENV           ?= dev
NAMESPACE     := $(APP)-$(ENV)

GREEN  := \033[0;32m
YELLOW := \033[0;33m
RED    := \033[0;31m
NC     := \033[0m

# Directorio raíz del repo — siempre relativo al Makefile, sin importar desde dónde se corra make.
ROOT_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

# ──────────────────────────────────────────────────────────────────────────────
# Help
# ──────────────────────────────────────────────────────────────────────────────
.PHONY: help
help:  ## Mostrar todos los targets
	@echo ""
	@echo "$(GREEN)belo-infrabase-k3d$(NC)"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | sort \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-22s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo "Override-ables: APP ($(APP))  ENV ($(ENV))  TAG ($(TAG))  DOCKERHUB_USER ($(DOCKERHUB_USER))"
	@echo "  Namespace resuelto: $(NAMESPACE)  (APP-ENV)"
	@echo ""

# ──────────────────────────────────────────────────────────────────────────────
# Cluster lifecycle
# ──────────────────────────────────────────────────────────────────────────────
.PHONY: all
all: cluster-up bootstrap  ## Levantar cluster + instalar addons + bootstrap ArgoCD (todo)

.PHONY: cluster-up
cluster-up: helm-repos  ## Crear cluster k3d, labeling de nodos e instalar addons
	@echo "$(YELLOW)→ Creando cluster k3d '$(K3D_CLUSTER)'...$(NC)"
	k3d cluster create --config $(ROOT_DIR)k3d/config.yaml
	kubectl config use-context $(K3D_CONTEXT)
	@echo "$(YELLOW)→ Aplicando labels y taints a los nodos...$(NC)"
	kubectl label node k3d-$(K3D_CLUSTER)-agent-0 role=statefulls workload=statefulls --overwrite
	kubectl taint node k3d-$(K3D_CLUSTER)-agent-0 workload=statefulls:NoSchedule --overwrite
	kubectl label node k3d-$(K3D_CLUSTER)-agent-1 role=stateless workload=stateless --overwrite
	kubectl label node k3d-$(K3D_CLUSTER)-agent-2 role=cicd workload=cicd --overwrite
	kubectl taint node k3d-$(K3D_CLUSTER)-agent-2 workload=cicd:NoSchedule --overwrite
	"$(MAKE)" addons
	@echo ""
	@echo "$(GREEN)✓ Cluster k3d listo. Siguiente: make secrets && make bootstrap$(NC)"

.PHONY: cluster-down
cluster-down:  ## Eliminar cluster k3d y volumen Docker
	@echo "$(YELLOW)→ Eliminando cluster '$(K3D_CLUSTER)'...$(NC)"
	k3d cluster delete $(K3D_CLUSTER)
	docker volume rm belo-statefull-data 2>/dev/null || true
	@echo "$(GREEN)✓ Cluster y volúmenes eliminados$(NC)"

.PHONY: cluster-status
cluster-status:  ## Estado del cluster: nodos + apps + rollouts
	@echo "$(YELLOW)→ Nodos:$(NC)"
	kubectl get nodes -L role,workload
	@echo "$(YELLOW)→ ArgoCD Applications:$(NC)"
	kubectl -n argocd get applications 2>/dev/null || echo "ArgoCD no instalado aún"
	@echo "$(YELLOW)→ Rollouts en namespaces de dev:$(NC)"
	kubectl get rollouts -n webserver-api01-dev 2>/dev/null || true
	kubectl get rollouts -n webserver-api02-dev 2>/dev/null || true

# ──────────────────────────────────────────────────────────────────────────────
# Helm repos y addons
# ──────────────────────────────────────────────────────────────────────────────
.PHONY: helm-repos
helm-repos:  ## Agregar y actualizar repos Helm (idempotente)
	@echo "$(YELLOW)→ Configurando repos Helm...$(NC)"
	helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
	helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
	helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
	helm repo add elastic https://helm.elastic.co 2>/dev/null || true
	helm repo add fluent https://fluent.github.io/helm-charts 2>/dev/null || true
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
	helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/ 2>/dev/null || true
	helm repo update
	@echo "$(GREEN)✓ Repos Helm actualizados$(NC)"

.PHONY: addons
addons: helm-repos  ## Instalar todos los addons en el cluster k3d
	@echo "$(YELLOW)→ 1/8 metrics-server (incluido en k3s, skip)...$(NC)"

	@echo "$(YELLOW)→ 2/8 nginx-ingress (NodePort 8888→80)...$(NC)"
	kubectl create namespace ingress-nginx 2>/dev/null || true
	helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
	  --namespace ingress-nginx \
	  --values $(ROOT_DIR)helm/addons/nginx-ingress/values.yaml \
	  --wait --timeout 2m

	@echo "$(YELLOW)→ 3/8 ArgoCD...$(NC)"
	kubectl create namespace argocd 2>/dev/null || true
	helm upgrade --install argocd argo/argo-cd \
	  --namespace argocd \
	  --values $(ROOT_DIR)helm/addons/argocd/values.yaml \
	  --wait --timeout 5m

	@echo "$(YELLOW)→ 4/8 Argo Rollouts...$(NC)"
	kubectl create namespace argo-rollouts 2>/dev/null || true
	helm upgrade --install argo-rollouts argo/argo-rollouts \
	  --namespace argo-rollouts \
	  --wait --timeout 2m

	@echo "$(YELLOW)→ 5/8 Tekton Pipelines + Triggers...$(NC)"
	kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
	kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml
	kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/interceptors.yaml
	kubectl -n tekton-pipelines rollout status deployment/tekton-pipelines-controller --timeout=3m

	@echo "$(YELLOW)→ 6/8 EFK stack (local-path, TLS deshabilitado para dev)...$(NC)"
	kubectl create namespace logging 2>/dev/null || true
	helm upgrade --install elasticsearch elastic/elasticsearch \
	  --namespace logging \
	  --values $(ROOT_DIR)helm/addons/elasticsearch/values.yaml \
	  --wait --timeout 6m
	helm upgrade --install fluent-bit fluent/fluent-bit \
	  --namespace logging \
	  --values $(ROOT_DIR)helm/addons/fluent-bit/values.yaml \
	  --wait --timeout 2m
	kubectl create secret generic elasticsearch-master-certs \
	  --from-literal=tls.crt="" --from-literal=tls.key="" --from-literal=ca.crt="" \
	  -n logging --dry-run=client -o yaml | kubectl apply -f -
	kubectl create secret generic kibana-kibana-es-token \
	  --from-literal=token="" -n logging --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install kibana elastic/kibana \
	  --namespace logging \
	  --values $(ROOT_DIR)helm/addons/kibana/values.yaml \
	  --no-hooks \
	  --wait --timeout 4m

	@echo "$(YELLOW)→ 7/8 kube-prometheus-stack...$(NC)"
	kubectl create namespace monitoring 2>/dev/null || true
	helm upgrade --install kube-prometheus prometheus-community/kube-prometheus-stack \
	  --namespace monitoring \
	  --values $(ROOT_DIR)helm/addons/kube-prometheus/values.yaml \
	  --wait --timeout 5m

	@echo "$(YELLOW)→ 8/8 Headlamp...$(NC)"
	helm upgrade --install headlamp headlamp/headlamp \
	  --namespace kube-system \
	  --values $(ROOT_DIR)helm/addons/headlamp/values.yaml \
	  --wait --timeout 2m

	@echo "$(GREEN)✓ Todos los addons instalados$(NC)"

# ──────────────────────────────────────────────────────────────────────────────
# GitOps Bootstrap
# ──────────────────────────────────────────────────────────────────────────────
.PHONY: bootstrap
bootstrap: tekton-apply  ## Aplicar root ArgoCD Application + Tekton pipeline manifests
	@echo "$(YELLOW)→ Aplicando root Application de ArgoCD...$(NC)"
	kubectl apply -f $(ROOT_DIR)manifests/argocd/bootstrap.yaml -n argocd
	@echo "$(GREEN)✓ Bootstrap aplicado$(NC)"
	@echo ""
	@echo "ArgoCD sincronizará gitops/ → crea webserver-api01-dev y webserver-api02-dev"
	@echo "Monitoreá en: http://argocd.localhost:8888  (user: admin)"
	@echo "Password:     $$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo 'ver: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath={.data.password} | base64 -d')"

.PHONY: tekton-apply
tekton-apply:  ## Aplicar Tasks, Pipeline y Triggers de Tekton
	@echo "$(YELLOW)→ Aplicando manifests de Tekton desde el chart...$(NC)"
	kubectl create namespace tekton-pipelines 2>/dev/null || true
	helm template tekton-pipeline $(ROOT_DIR)charts/pythonapps \
	  -f $(ROOT_DIR)charts/pythonapps/apps/webserver-api01/build-time/app.yaml \
	  --set tekton.enabled=true \
	  --set tekton.dockerhubUser=$(DOCKERHUB_USER) \
	  --set tekton.gitopsRepoUrl=https://github.com/Valentino-33/belo-infrabase-k3d \
	  -s templates/pipeline-templates/tekton-sa.yaml \
	  -s templates/pipeline-templates/task-clone.yaml \
	  -s templates/pipeline-templates/task-build-kaniko.yaml \
	  -s templates/pipeline-templates/task-bump-gitops.yaml \
	  -s templates/pipeline-templates/task-wait-argocd.yaml \
	  -s templates/pipeline-templates/task-load-test.yaml \
	  -s templates/pipeline-templates/task-promote-rollback.yaml \
	  -s templates/pipeline-templates/pipeline-pythonapps.yaml \
	  -s templates/pipeline-templates/trigger-binding.yaml \
	  -s templates/pipeline-templates/trigger-template.yaml \
	  -s templates/pipeline-templates/event-listener.yaml \
	  | kubectl apply -f -
	@echo "$(GREEN)✓ Tekton pipeline aplicado$(NC)"

# ──────────────────────────────────────────────────────────────────────────────
# Secretos requeridos
# ──────────────────────────────────────────────────────────────────────────────
.PHONY: secrets
secrets:  ## Instrucciones para crear los secretos necesarios (Kaniko + GitHub)
	@echo ""
	@echo "$(YELLOW)=== Secretos necesarios ===$(NC)"
	@echo ""
	@echo "1. DockerHub (para Kaniko build+push):"
	@echo "   kubectl create secret docker-registry dockerhub-credentials \\"
	@echo "     --docker-server=https://index.docker.io/v1/ \\"
	@echo "     --docker-username=<DOCKERHUB_USER> \\"
	@echo "     --docker-password=<DOCKERHUB_TOKEN> \\"
	@echo "     -n tekton-pipelines"
	@echo ""
	@echo "2. GitHub (para bump-gitops push):"
	@echo "   cp manifests/tekton/github-secret.yaml.example manifests/tekton/github-secret.yaml"
	@echo "   # Editar con tu token de GitHub"
	@echo "   kubectl apply -f manifests/tekton/github-secret.yaml -n tekton-pipelines"
	@echo ""
	@echo "O usar el helper:"
	@echo "   make secrets-apply DOCKERHUB_USER=<user> DOCKERHUB_TOKEN=<token> GITHUB_TOKEN=<token>"
	@echo ""

.PHONY: secrets-apply
secrets-apply:  ## Crear secretos: make secrets-apply DOCKERHUB_USER=x DOCKERHUB_TOKEN=x GITHUB_TOKEN=x
	@if [ -z "$(DOCKERHUB_TOKEN)" ] || [ -z "$(GITHUB_TOKEN)" ]; then \
		echo "$(RED)Faltan DOCKERHUB_TOKEN y/o GITHUB_TOKEN$(NC)"; exit 1; \
	fi
	kubectl create secret docker-registry dockerhub-credentials \
	  --docker-server=https://index.docker.io/v1/ \
	  --docker-username=$(DOCKERHUB_USER) \
	  --docker-password=$(DOCKERHUB_TOKEN) \
	  -n tekton-pipelines --dry-run=client -o yaml | kubectl apply -f -
	kubectl create secret generic github-token \
	  --from-literal=token=$(GITHUB_TOKEN) \
	  -n tekton-pipelines --dry-run=client -o yaml | kubectl apply -f -
	@echo "$(GREEN)✓ Secretos creados$(NC)"

# ──────────────────────────────────────────────────────────────────────────────
# Pipeline manual
# ──────────────────────────────────────────────────────────────────────────────
.PHONY: pipeline-run
pipeline-run:  ## Disparar pipeline manual: make pipeline-run APP=webserver-api01 TAG=v0.1.0
	@echo "$(YELLOW)→ Iniciando PipelineRun para $(APP):$(TAG)...$(NC)"
	APP=$(APP) TAG=$(TAG) DOCKERHUB_USER=$(DOCKERHUB_USER) \
	  envsubst < $(ROOT_DIR)manifests/tekton/pipelinerun-manual.yaml | kubectl apply -f -
	@echo "$(GREEN)✓ PipelineRun creado — monitoreá con:$(NC)"
	@echo "   tkn pipelinerun logs -n tekton-pipelines --last -f"

.PHONY: release
release:  ## Crear y pushear tag de release: make release APP=webserver-api01 TAG=v1.0.0 ENVS=dev
	@if [ -z "$(TAG)" ]; then echo "$(RED)Falta TAG (ej: make release TAG=v1.0.0)$(NC)"; exit 1; fi
	@echo "$(YELLOW)→ Creando tag release/$(TAG)/$(ENVS) para $(APP)...$(NC)"
	@echo "  Repo de la app: corré esto DESDE el repo de la app, no desde el gitops repo"
	@echo ""
	@echo "  git tag release/$(TAG)/$(ENVS)"
	@echo "  git push origin release/$(TAG)/$(ENVS)"
	@echo ""
	@echo "$(GREEN)Eso dispara el webhook → pipeline para $(APP) en ambiente(s): $(ENVS)$(NC)"

# ──────────────────────────────────────────────────────────────────────────────
# Demos
# ──────────────────────────────────────────────────────────────────────────────
.PHONY: demo-bluegreen
demo-bluegreen:  ## Guía interactiva de demo Blue/Green (api01) — ENV=dev por default
	@echo ""
	@echo "$(GREEN)=== Demo Blue/Green — webserver-api01-$(ENV) ===$(NC)"
	@echo ""
	@echo "Estado actual del rollout (namespace: webserver-api01-$(ENV)):"
	kubectl argo rollouts get rollout webserver-api01-$(ENV) -n webserver-api01-$(ENV) 2>/dev/null || \
	  echo "  (rollout no encontrado — ejecutá make bootstrap primero)"
	@echo ""
	@echo "$(YELLOW)Pasos para promover una nueva versión:$(NC)"
	@echo ""
	@echo "  1. Crear tag de release desde el repo de la app:"
	@echo "     git tag release/v1.1.0/$(ENV)"
	@echo "     git push origin release/v1.1.0/$(ENV)"
	@echo ""
	@echo "  2. El pipeline construye la imagen, corre k6 contra el preview service,"
	@echo "     actualiza image.tag en charts/pythonapps/apps/webserver-api01/$(ENV)/values.yaml."
	@echo ""
	@echo "  3. ArgoCD detecta el commit → actualiza el Rollout → aparece el pod GREEN."
	@echo ""
	@echo "  4. Verificar que el preview (green) responde:"
	@echo "     curl http://preview-api01.localhost:8888/version"
	@echo ""
	@echo "  5. Promover (switchear tráfico a green):"
	@echo "     kubectl argo rollouts promote webserver-api01-$(ENV) -n webserver-api01-$(ENV)"
	@echo ""
	@echo "  6. Verificar que el stable (ahora green) sirve 100% del tráfico:"
	@echo "     curl http://api01.localhost:8888/version"
	@echo ""
	@echo "  7. Rollback (si fuera necesario):"
	@echo "     kubectl argo rollouts abort webserver-api01-$(ENV) -n webserver-api01-$(ENV)"
	@echo ""

.PHONY: demo-canary
demo-canary:  ## Guía interactiva de demo Canary (api02) — ENV=dev por default
	@echo ""
	@echo "$(GREEN)=== Demo Canary — webserver-api02-$(ENV) ===$(NC)"
	@echo ""
	@echo "Estado actual del rollout (namespace: webserver-api02-$(ENV)):"
	kubectl argo rollouts get rollout webserver-api02-$(ENV) -n webserver-api02-$(ENV) 2>/dev/null || \
	  echo "  (rollout no encontrado — ejecutá make bootstrap primero)"
	@echo ""
	@echo "$(YELLOW)Pasos para avanzar el canary:$(NC)"
	@echo ""
	@echo "  1. Crear tag de release desde el repo de la app:"
	@echo "     git tag release/v1.1.0/$(ENV)"
	@echo "     git push origin release/v1.1.0/$(ENV)"
	@echo ""
	@echo "  2. ArgoCD actualiza el Rollout → canary arranca con 5% del tráfico."
	@echo ""
	@echo "  3. Monitorear distribución en tiempo real:"
	@echo "     kubectl argo rollouts get rollout webserver-api02-$(ENV) -n webserver-api02-$(ENV) --watch"
	@echo ""
	@echo "  4. Avanzar al siguiente step (25%):"
	@echo "     kubectl argo rollouts promote webserver-api02-$(ENV) -n webserver-api02-$(ENV)"
	@echo ""
	@echo "  5. Avanzar a 50%:"
	@echo "     kubectl argo rollouts promote webserver-api02-$(ENV) -n webserver-api02-$(ENV)"
	@echo ""
	@echo "  6. Promover completo (100%):"
	@echo "     kubectl argo rollouts promote webserver-api02-$(ENV) -n webserver-api02-$(ENV)"
	@echo ""
	@echo "  7. Rollback a stable:"
	@echo "     kubectl argo rollouts abort webserver-api02-$(ENV) -n webserver-api02-$(ENV)"
	@echo ""

# ──────────────────────────────────────────────────────────────────────────────
# Rollout status
# ──────────────────────────────────────────────────────────────────────────────
.PHONY: rollout-status
rollout-status:  ## Ver estado del rollout: make rollout-status APP=webserver-api01 ENV=dev
	kubectl argo rollouts get rollout $(APP)-$(ENV) -n $(NAMESPACE) --watch

.PHONY: rollout-promote
rollout-promote:  ## Promover rollout: make rollout-promote APP=webserver-api01 ENV=dev
	kubectl argo rollouts promote $(APP)-$(ENV) -n $(NAMESPACE)

.PHONY: rollout-abort
rollout-abort:  ## Abortar rollout (rollback): make rollout-abort APP=webserver-api01 ENV=dev
	kubectl argo rollouts abort $(APP)-$(ENV) -n $(NAMESPACE)

# ──────────────────────────────────────────────────────────────────────────────
# Build local de imágenes (sin k3d)
# ──────────────────────────────────────────────────────────────────────────────
.PHONY: build
build:  ## Build local: make build APP=webserver-api01 TAG=v0.1.0
	docker build -t $(DOCKERHUB_USER)/$(APP):$(TAG) $(ROOT_DIR)apps/$(APP)/

.PHONY: push
push:  ## Push a DockerHub: make push APP=webserver-api01 TAG=v0.1.0
	docker push $(DOCKERHUB_USER)/$(APP):$(TAG)

.PHONY: build-push
build-push: build push  ## Build + push en un paso

.PHONY: images-initial
images-initial:  ## Build y push de ambas apps con tag latest (requerido antes de make bootstrap)
	@echo "$(YELLOW)→ Build y push de imágenes iniciales...$(NC)"
	docker build -t $(DOCKERHUB_USER)/api01:latest $(ROOT_DIR)apps/webserver-api01/
	docker push $(DOCKERHUB_USER)/api01:latest
	docker build -t $(DOCKERHUB_USER)/api02:latest $(ROOT_DIR)apps/webserver-api02/
	docker push $(DOCKERHUB_USER)/api02:latest
	@echo "$(GREEN)✓ Imágenes iniciales publicadas en Docker Hub$(NC)"

# ──────────────────────────────────────────────────────────────────────────────
# Acceso a UIs
# ──────────────────────────────────────────────────────────────────────────────
.PHONY: port-forward
port-forward:  ## Port-forward de fallback (usar URLs :8888 es preferible)
	@echo "$(YELLOW)→ Iniciando port-forwards de fallback...$(NC)"
	kubectl -n argocd port-forward svc/argocd-server 8080:80 > /tmp/pf-argocd.log 2>&1 &
	kubectl -n monitoring port-forward svc/kube-prometheus-grafana 8082:80 > /tmp/pf-grafana.log 2>&1 &
	kubectl -n logging port-forward svc/kibana-kibana 8083:5601 > /tmp/pf-kibana.log 2>&1 &
	kubectl -n kube-system port-forward svc/headlamp 8081:80 > /tmp/pf-headlamp.log 2>&1 &
	@echo ""
	@echo "$(GREEN)Acceso preferido vía nginx (requiere entradas en /etc/hosts):$(NC)"
	@echo "  ArgoCD   → http://argocd.localhost:8888   (admin / make argocd-password)"
	@echo "  Grafana  → http://grafana.localhost:8888  (admin / belo-challenge)"
	@echo "  Kibana   → http://kibana.localhost:8888"
	@echo "  Headlamp → http://headlamp.localhost:8888 (token: kubectl create token headlamp -n kube-system)"
	@echo ""
	@echo "$(YELLOW)Fallback port-forward:$(NC)"
	@echo "  ArgoCD   → http://localhost:8080"
	@echo "  Grafana  → http://localhost:8082"
	@echo "  Kibana   → http://localhost:8083"
	@echo "  Headlamp → http://localhost:8081"
	@echo ""
	@echo "Para detener: pkill -f 'kubectl.*port-forward'"

.PHONY: argocd-password
argocd-password:  ## Mostrar password inicial de ArgoCD
	@kubectl -n argocd get secret argocd-initial-admin-secret \
	  -o jsonpath='{.data.password}' | base64 -d
	@echo ""

# ──────────────────────────────────────────────────────────────────────────────
# Load testing
# ──────────────────────────────────────────────────────────────────────────────
.PHONY: cluster-info
cluster-info:  ## Mostrar URLs, passwords y comandos útiles de un vistazo
	@echo ""
	@echo "$(GREEN)=== Acceso a dashboards (agregar al archivo hosts primero) ===$(NC)"
	@echo "  ArgoCD   → http://argocd.localhost:8888   (admin / $$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo 'ver: make argocd-password'))"
	@echo "  Grafana  → http://grafana.localhost:8888  (admin / belo-challenge)"
	@echo "  Kibana   → http://kibana.localhost:8888"
	@echo "  Headlamp → http://headlamp.localhost:8888 (token: kubectl create token headlamp -n kube-system)"
	@echo "  api01    → http://api01.localhost:8888"
	@echo "  api02    → http://api02.localhost:8888"
	@echo ""
	@echo "$(GREEN)=== Hosts que deben estar en C:\\Windows\\System32\\drivers\\etc\\hosts ===$(NC)"
	@echo "  127.0.0.1 argocd.localhost grafana.localhost kibana.localhost headlamp.localhost"
	@echo "  127.0.0.1 api01.localhost preview-api01.localhost"
	@echo "  127.0.0.1 api02.localhost preview-api02.localhost"
	@echo "  127.0.0.1 tekton-webhook.localhost"
	@echo ""
	@echo "$(GREEN)=== Estado del cluster ===$(NC)"
	kubectl get nodes -L role,workload 2>/dev/null || echo "Cluster no disponible"
	@echo ""

.PHONY: tunnel
tunnel:  ## Exponer EventListener a internet con ngrok (requiere ngrok instalado)
	@echo "$(YELLOW)→ Iniciando ngrok en puerto 8888...$(NC)"
	@echo "$(YELLOW)  Una vez activo, copiá la URL https:// y configurala en GitHub:"$(NC)
	@echo "  Settings → Webhooks → Payload URL: <ngrok-url>"
	@echo "  Content type: application/json  |  Events: Push"
	@echo ""
	ngrok http 8888

.PHONY: load-test-smoke
load-test-smoke:  ## Smoke test: make load-test-smoke APP=webserver-api01
	k6 run -e BASE_URL=http://$(APP).localhost:8888 $(ROOT_DIR)apps/$(APP)/loadtest/smoke.js

.PHONY: load-test-bluegreen
load-test-bluegreen:  ## Load test BlueGreen (contra preview): make load-test-bluegreen
	k6 run -e PREVIEW_URL=http://preview-api01.localhost:8888 \
	  $(ROOT_DIR)apps/webserver-api01/loadtest/load-bluegreen.js

.PHONY: load-test-canary
load-test-canary:  ## Load test Canary (contra stable con canary activo): make load-test-canary
	k6 run -e BASE_URL=http://api02.localhost:8888 \
	  $(ROOT_DIR)apps/webserver-api02/loadtest/load-canary.js
