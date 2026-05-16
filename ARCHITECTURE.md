# Architecture

> La documentación de arquitectura está en **[docs/architecture.md](docs/architecture.md)**.
>
> Ese archivo contiene los diagramas Mermaid:
> 1. **Topología del cluster k3d** (nodos, roles, taints)
> 2. **Componentes internos del cluster** (namespaces, services)
> 3. **Flujo CI/CD completo end-to-end** (sequence diagram de las 6 stages)
> 4. **Modelo de promote-rollback** (kubectl patch directo al status subresource)
>
> Documentos complementarios:
> - [docs/pipeline-internals.md](docs/pipeline-internals.md) — detalle técnico por Task
> - [docs/security-and-rbac.md](docs/security-and-rbac.md) — PodSecurity, securityContext, ClusterRoles
> - [docs/troubleshooting.md](docs/troubleshooting.md) — diagnóstico y soluciones operativas
