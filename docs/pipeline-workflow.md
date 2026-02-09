# Pipeline Workflow

## Pipeline Overview

The CI/CD pipeline executes in two phases triggered by a `git push` to the `main` branch:

| Phase | Orchestrator | Duration | Steps |
|---|---|---|---|
| **CI** | GitHub Actions (self-hosted runner) | ~12s | Checkout, build image, push to registry, trigger AWX |
| **CD** | AWX Workflow Template | ~99s | Deploy (~13s), ZAP Scan (~82s), Evaluate (~4s) |

The CI phase builds and pushes the container image, then hands off to the CD phase via REST API. The CD phase deploys the application, runs security scans, and enforces the security gate.

## End-to-End Pipeline Flow

```mermaid
flowchart TD
    push["git push to main"]
    checkout["Checkout code"]
    build["Build Docker image<br/><i>~3s</i>"]
    push_img["Push to local registry<br/><i>~2s</i>"]
    trigger["Trigger AWX workflow<br/><i>REST API POST</i>"]
    deploy["Deploy Sample App<br/><i>~13s</i>"]
    zap["ZAP Baseline + Full Scan<br/><i>~82s</i>"]
    evaluate["Evaluate ZAP Report<br/><i>~4s</i>"]
    pass["Pipeline PASSED"]
    fail["Pipeline FAILED"]

    push --> checkout --> build --> push_img --> trigger
    trigger -->|"CI → CD handoff"| deploy
    deploy --> zap --> evaluate
    evaluate -->|"No High/Critical findings"| pass
    evaluate -->|"High/Critical findings found"| fail

    style push fill:#e1f5fe
    style trigger fill:#fff3e0
    style pass fill:#c8e6c9
    style fail fill:#ffcdd2
```

## CI Phase — GitHub Actions

The CI workflow is defined in `.github/workflows/ci.yml`. It runs on a self-hosted runner registered with the `local-poc` label.

```mermaid
flowchart LR
    checkout["Checkout<br/>actions/checkout@v4"]
    build["docker build<br/>-t localhost:5000/sample-app:SHA"]
    push["docker push<br/>localhost:5000/sample-app:SHA"]
    trigger["curl POST<br/>awx-web:8013/api/v2/..."]

    checkout --> build --> push --> trigger
```

### Why `awx-web:8013` instead of `localhost:8043`?

The self-hosted runner container and AWX web container both run on the shared Docker network (`cd-ansible-zap_poc-network`). Inside this network, containers communicate using container names and internal ports. AWX's nginx listens on port **8013** inside the container, which is mapped to host port **8043**. Since the runner is inside the Docker network, it uses the internal address `awx-web:8013`.

### Required GitHub Secrets

| Secret | Source | Description |
|---|---|---|
| `AWX_TOKEN` | `awx-setup.sh` output | OAuth2 bearer token for AWX API authentication |
| `AWX_WORKFLOW_TEMPLATE_ID` | `awx-setup.sh` output | ID of the Workflow Template to launch |

### Workflow Trigger

The workflow triggers on pushes to the `main` branch only:

```yaml
on:
  push:
    branches: [main]
```

## CD Phase — AWX Workflow

The CD phase is orchestrated by an AWX Workflow Template that chains three Job Templates. Each node advances only on the success of the previous node.

```mermaid
flowchart TD
    wf["Workflow Template<br/><b>CD Pipeline — Deploy, Scan, Evaluate</b><br/><i>ask_variables_on_launch: true</i>"]
    deploy["Job Template<br/><b>Deploy Sample App</b><br/><i>deploy.yml</i>"]
    zap["Job Template<br/><b>ZAP Security Scan</b><br/><i>zap-scan.yml</i>"]
    evaluate["Job Template<br/><b>Evaluate ZAP Report</b><br/><i>evaluate-report.yml</i>"]

    wf -->|"launches"| deploy
    deploy -->|"on success"| zap
    zap -->|"on success"| evaluate
    deploy -.->|"on failure"| wf_fail["Workflow Failed"]
    zap -.->|"on failure"| wf_fail
    evaluate -.->|"on failure"| wf_fail

    style wf fill:#e8f5e9
    style deploy fill:#e1f5fe
    style zap fill:#fff3e0
    style evaluate fill:#f3e5f5
    style wf_fail fill:#ffcdd2
```

### Variable Flow Through the Workflow

The Workflow Template is configured with `ask_variables_on_launch: true`, which allows the CI phase to pass `extra_vars` at launch time. The `image_tag` variable flows through the workflow:

1. **CI** passes `{"extra_vars": {"image_tag": "<git-sha>"}}` when launching the workflow.
2. The **Workflow Template** propagates `extra_vars` to each child node.
3. The **Deploy Job Template** (`ask_variables_on_launch: true`) receives `image_tag` and uses it to pull the correct image.
4. The **ZAP Scan** and **Evaluate** Job Templates use pre-configured `extra_vars` (host-absolute paths) and do not require `image_tag`.

## Sequence Diagram

```mermaid
sequenceDiagram
    participant Dev as Developer
    participant GH as GitHub
    participant Runner as Self-Hosted Runner
    participant Reg as Docker Registry
    participant AWX as AWX API
    participant EE as Execution Environment
    participant Docker as Docker Engine
    participant App as Sample App
    participant ZAP as OWASP ZAP

    Dev->>GH: git push (main)
    GH->>Runner: Trigger CI workflow

    rect rgb(255, 243, 224)
        Note over Runner: CI Phase
        Runner->>Runner: docker build (SHA tag)
        Runner->>Reg: docker push
        Runner->>AWX: POST /workflow_job_templates/{id}/launch/
    end

    rect rgb(232, 245, 233)
        Note over AWX: CD Phase — Deploy
        AWX->>EE: Launch EE container
        EE->>Reg: Pull sample-app image
        EE->>Docker: Create sample-app container
        Docker->>App: Start application
        EE->>App: GET /health (wait for 200)
        App-->>EE: 200 OK
    end

    rect rgb(255, 243, 224)
        Note over AWX: CD Phase — ZAP Scan
        AWX->>EE: Launch EE container
        EE->>Docker: Create zap-baseline container
        ZAP->>App: Baseline scan (HTTP)
        ZAP-->>EE: Report JSON
        EE->>Docker: Create zap-full container
        ZAP->>App: Full active scan (HTTP)
        ZAP-->>EE: Report JSON
    end

    rect rgb(243, 229, 245)
        Note over AWX: CD Phase — Evaluate
        AWX->>EE: Launch EE container
        EE->>EE: Read zap-full-report.json
        alt No High/Critical findings
            EE-->>AWX: Job Successful
        else High/Critical findings found
            EE-->>AWX: Job Failed
        end
    end
```

## Image Tag Data Flow

The Git commit SHA serves as the immutable image tag, propagating through every stage of the pipeline.

```mermaid
flowchart LR
    git["Git Commit<br/><code>github.sha</code>"]
    tag["Docker Tag<br/><code>localhost:5000/<br/>sample-app:{sha}</code>"]
    push_reg["Registry<br/>stores tagged image"]
    extra["AWX extra_vars<br/><code>image_tag: {sha}</code>"]
    deploy_pull["deploy.yml<br/><code>docker_image pull<br/>tag: {sha}</code>"]
    container["Container<br/><code>sample-app</code><br/>running {sha}"]

    git --> tag --> push_reg
    git --> extra --> deploy_pull
    push_reg --> deploy_pull --> container
```

This ensures full traceability from Git commit to running container — every deployment can be traced back to the exact source code revision.

## Security Gate Logic

The `evaluate-report.yml` playbook reads the ZAP full scan report and enforces a configurable risk threshold.

```mermaid
flowchart TD
    start["Read zap-full-report.json"]
    exists{{"Report exists?"}}
    parse["Parse JSON, extract alerts"]
    filter["Filter alerts where<br/>riskcode >= risk_threshold"]
    check{{"High-risk alerts found?"}}
    details["Display alert details<br/>(name, risk, confidence)"]
    fail_gate["FAIL: Security gate failed<br/>Pipeline stops"]
    pass_gate["PASS: No high-risk findings<br/>Pipeline continues"]
    fail_missing["FAIL: Report not found<br/>Pipeline stops"]

    start --> exists
    exists -->|"Yes"| parse --> filter --> check
    exists -->|"No"| fail_missing
    check -->|"alerts > 0"| details --> fail_gate
    check -->|"alerts == 0"| pass_gate

    style pass_gate fill:#c8e6c9
    style fail_gate fill:#ffcdd2
    style fail_missing fill:#ffcdd2
```

### ZAP Risk Codes

| Risk Code | Level | Gate Behavior (threshold=3) |
|---|---|---|
| 0 | Informational | Pass |
| 1 | Low | Pass |
| 2 | Medium | Pass |
| 3 | High | **Fail** |
| 4 | Critical | **Fail** |

The `risk_threshold` variable defaults to `3` (High). Any alert with a `riskcode` greater than or equal to the threshold causes the pipeline to fail. This is configurable — setting it to `2` would also fail on Medium findings.

---

*See also: [Architecture Overview](architecture.md) | [Technical Design](technical-design.md) | [Component Reference](component-reference.md)*
