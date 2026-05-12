# Architecture

> La documentación de arquitectura se movió a **[docs/architecture.md](docs/architecture.md)**.
>
> Ese archivo contiene los diagramas Mermaid:
> 1. **Topología del cluster k3d** (nodos, roles, taints)
> 2. **Componentes internos del cluster** (namespaces, services)
> 3. **Flujo CI/CD completo end-to-end** (sequence diagram de las 6 stages, con la fix del race condition ArgoCD ↔ Pipeline)
> 4. **Modelo de promote-rollback** (kubectl patch directo, sin plugin externo)
>
> Documentos complementarios:
> - [docs/pipeline-internals.md](docs/pipeline-internals.md) — detalle técnico por Task
> - [docs/security-and-rbac.md](docs/security-and-rbac.md) — PodSecurity, securityContext, ClusterRoles
> - [docs/troubleshooting.md](docs/troubleshooting.md) — gotchas y fixes
