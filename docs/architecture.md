# Architecture Overview

## Introduction

This document describes the architecture of the CI/CD pipeline Proof of Concept (PoC) that demonstrates a decoupled pipeline using GitHub Actions for CI and AWX/Ansible for CD, with integrated OWASP ZAP DAST scanning. The complete environment runs on a single local workstation using containerized components.

For business objectives, scope, and requirements, see the [Business Requirements Document](../brd-poc-cd-ansible.md).

## High-Level System Architecture

The pipeline consists of two phases: a CI phase (GitHub Actions) that builds and pushes container images, and a CD phase (AWX/Ansible) that deploys the application and runs security scans.

```mermaid
graph TB
    Dev["Developer"]
    GH["GitHub Repository"]
    Runner["Self-Hosted Runner<br/><i>github-runner</i>"]
    Registry["Docker Registry v2<br/><i>poc-registry:5000</i>"]
    AWX["AWX<br/><i>awx-web:8043</i>"]
    EE["Execution Environment<br/><i>awx-ee-poc</i>"]
    App["Sample App<br/><i>sample-app:8080</i>"]
    ZAP["OWASP ZAP<br/><i>zaproxy:stable</i>"]
    Reports["ZAP Reports<br/><i>reports/</i>"]

    Dev -->|"git push"| GH
    GH -->|"triggers workflow"| Runner
    Runner -->|"docker build + push"| Registry
    Runner -->|"REST API POST"| AWX
    AWX -->|"launches EE"| EE
    EE -->|"deploy container"| App
    EE -->|"launch ZAP"| ZAP
    Registry -->|"pull image"| EE
    ZAP -->|"scan"| App
    ZAP -->|"write JSON"| Reports
    EE -->|"evaluate report"| Reports

    subgraph "CI Phase — GitHub Actions"
        Runner
    end

    subgraph "CD Phase — AWX/Ansible"
        AWX
        EE
    end

    subgraph "Target Environment"
        App
        ZAP
    end

    style Dev fill:#e1f5fe
    style GH fill:#e1f5fe
    style Runner fill:#fff3e0
    style Registry fill:#f3e5f5
    style AWX fill:#e8f5e9
    style EE fill:#e8f5e9
    style App fill:#fce4ec
    style ZAP fill:#fce4ec
    style Reports fill:#f5f5f5
```

## Docker Network Topology

All containers communicate over a single shared Docker bridge network (`cd-ansible-zap_poc-network`), created by the infrastructure compose file. Compose files that join this network reference it as `external: true`.

```mermaid
graph LR
    subgraph "cd-ansible-zap_poc-network (bridge)"
        direction TB
        registry["poc-registry<br/>:5000 → host :5000"]
        runner["github-runner"]
        postgres["awx-postgres<br/>:5432 (internal)"]
        redis["awx-redis<br/>unix socket"]
        web["awx-web<br/>:8013 → host :8043"]
        task["awx-task<br/>Docker socket"]
        app["sample-app<br/>:8080 → host :8080"]
        ee["awx-ee-poc<br/>(ephemeral)"]
        zap_b["zap-baseline<br/>(ephemeral)"]
        zap_f["zap-full<br/>(ephemeral)"]
    end

    runner -->|"docker build/push"| registry
    runner -->|"HTTP :8013"| web
    task -->|"launches"| ee
    ee -->|"pull image"| registry
    ee -->|"deploy"| app
    ee -->|"launches"| zap_b
    ee -->|"launches"| zap_f
    zap_b -->|"HTTP :8080"| app
    zap_f -->|"HTTP :8080"| app
    web --- postgres
    web --- redis
    task --- postgres
    task --- redis

    style ee fill:#e8f5e9,stroke-dasharray: 5 5
    style zap_b fill:#fce4ec,stroke-dasharray: 5 5
    style zap_f fill:#fce4ec,stroke-dasharray: 5 5
```

> **Note:** Dashed borders indicate ephemeral containers that are created and destroyed during pipeline execution. The EE container runs each Ansible job, while ZAP containers run for each scan type.

### Key Networking Details

- The **self-hosted runner** connects to AWX via `awx-web:8013` (the container's internal nginx port), not `localhost:8043`, because both containers share the Docker network.
- **ZAP** targets the application as `http://sample-app:8080` using Docker DNS resolution.
- The **deploy playbook** uses an `app_host` variable (default: `localhost`) to configure the health check target. When run inside the EE, AWX overrides this to `sample-app` so the health check uses Docker DNS.

## Container Relationships and Startup Order

The PoC uses four Docker Compose files. Dependencies use `service_healthy` (healthcheck-based) or `service_completed_successfully` (init container) conditions.

```mermaid
graph TD
    subgraph "docker-compose.infra.yml"
        registry["poc-registry"]
    end

    subgraph "docker-compose.awx.yml"
        postgres["awx-postgres"]
        redis_svc["awx-redis"]
        init["awx-init"]
        web["awx-web"]
        task["awx-task"]
    end

    subgraph "docker-compose.runner.yml"
        runner["github-runner"]
    end

    subgraph "Ephemeral (created by playbooks)"
        app["sample-app"]
        zap_b["zap-baseline"]
        zap_f["zap-full"]
        ee["awx-ee-poc"]
    end

    registry -.->|"network: external"| postgres
    postgres -->|"service_healthy"| init
    redis_svc -->|"service_healthy"| init
    init -->|"service_completed_successfully"| web
    init -->|"service_completed_successfully"| task
    task -->|"launches"| ee
    ee -->|"creates"| app
    ee -->|"creates"| zap_b
    ee -->|"creates"| zap_f

    style registry fill:#f3e5f5
    style init fill:#fff3e0
    style app fill:#fce4ec,stroke-dasharray: 5 5
    style zap_b fill:#fce4ec,stroke-dasharray: 5 5
    style zap_f fill:#fce4ec,stroke-dasharray: 5 5
    style ee fill:#e8f5e9,stroke-dasharray: 5 5
```

### Startup Sequence

1. **Infrastructure** (`docker-compose.infra.yml`) — Start first. Creates the `cd-ansible-zap_poc-network` bridge network and launches the Docker registry.
2. **AWX** (`docker-compose.awx.yml`) — Start second. PostgreSQL and Redis must be healthy before `awx-init` runs migrations. Web and task containers start only after init completes successfully.
3. **Runner** (`docker-compose.runner.yml`) — Start third. Requires the network to already exist and a valid `RUNNER_TOKEN` in `.env`.
4. **Ephemeral containers** — Created dynamically by Ansible playbooks running inside the EE during pipeline execution.

## Port Mapping Reference

| Service | Container Name | Container Port | Host Port | Protocol |
|---|---|---|---|---|
| Docker Registry | `poc-registry` | 5000 | 5000 | HTTP |
| AWX Web UI/API | `awx-web` | 8013 (nginx) | 8043 | HTTP |
| Sample App | `sample-app` | 8080 | 8080 | HTTP |
| PostgreSQL | `awx-postgres` | 5432 | — | TCP (internal) |
| Redis | `awx-redis` | — | — | Unix socket |
| Receptor | `awx-task` | 2222 | — | TCP (internal) |

## Technology Stack

| Technology | Version | Role |
|---|---|---|
| GitHub Actions | — | CI orchestration (workflow runner) |
| AWX | 24.6.1 | CD orchestration (job templates, workflows, API) |
| Ansible | ansible-core 2.16+ | Automation language (playbooks) |
| Docker / Docker Compose | Latest stable | Container runtime and orchestration |
| Docker Registry v2 | 2.x | Local container image storage |
| OWASP ZAP | stable (latest) | DAST security scanning |
| Spring Boot | 3.4.1 | Sample application framework |
| Java | 17 | Sample application runtime |
| Maven | 3.9 | Sample application build tool |
| PostgreSQL | 15 | AWX database |
| Redis | 7 | AWX message broker (Unix socket) |
| Receptor | 1.6.3 | AWX job mesh transport |
| nginx | bundled with AWX | AWX reverse proxy |

---

*See also: [Pipeline Workflow](pipeline-workflow.md) | [Technical Design](technical-design.md) | [Component Reference](component-reference.md)*
