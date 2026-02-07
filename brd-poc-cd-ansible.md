# Business Requirements Document
## PoC: Continuous Delivery Pipeline with GitHub Actions, AWX, and OWASP ZAP

| Field | Detail |
|---|---|
| **Document ID** | BRD-DEVSECOPS-POC-2026-001 |
| **Author** | David — AVP, Senior DevSecOps Engineer |
| **Department** | DevSecOps Engineering |
| **Date** | February 7, 2026 |
| **Version** | 1.0 |
| **Status** | Draft |
| **Classification** | Internal Use Only |

---

## 1. Executive Summary

This document defines the business and technical requirements for a Proof of Concept (PoC) that demonstrates a lightweight CI/CD pipeline using open-source tooling that can be executed entirely on a local developer workstation. The pipeline covers two phases: a CI phase handled by GitHub Actions self-hosted runners for building and pushing container artifacts, and a CD phase orchestrated by AWX (the open-source upstream of Ansible Automation Platform) for deploying to a local Dev environment and executing OWASP ZAP DAST security scans.

The PoC serves as a validation exercise before recommending enterprise adoption of Ansible Automation Platform (AAP) for continuous delivery across Banamex's 287 application teams.

---

## 2. Business Objectives

**BO-1.** Validate the feasibility of decoupling CI (build/test) from CD (deploy/scan) using GitHub Actions and AWX as independent, integrated components.

**BO-2.** Demonstrate that OWASP ZAP DAST scanning can be embedded as an automated gate within the CD workflow, supporting Banamex's shift-left security strategy.

**BO-3.** Provide a reproducible, local-first PoC environment that stakeholders can evaluate without requiring access to shared infrastructure or cloud resources.

**BO-4.** Generate evidence and findings to inform the business case for enterprise AAP licensing and rollout.

---

## 3. Scope

### 3.1 In Scope

- GitHub Actions self-hosted runner configuration for CI (build and push only).
- AWX deployment on local machine for CD orchestration.
- Automated deployment of a sample containerized application to a local Dev environment.
- OWASP ZAP baseline and active DAST scan against the deployed application.
- Pipeline integration: GitHub Actions triggers AWX via API upon successful CI completion.
- ZAP scan report generation and basic pass/fail gating.

### 3.2 Out of Scope

- Smoke tests, integration tests, or functional test automation.
- Multi-environment promotion (Staging, Production).
- SAST, SCA, or other security scan types (Snyk, SonarQube).
- High availability, clustering, or performance testing of AWX.
- CNBV or PCI-DSS compliance validation (deferred to enterprise implementation).
- Cloud-hosted infrastructure (AWS, OpenShift).

---

## 4. Stakeholders

| Role | Responsibility |
|---|---|
| DevSecOps Engineer (Author) | PoC design, implementation, and documentation |
| DevSecOps Lead / Manager | Review, approval, and resource allocation |
| Application Security Team | Validate ZAP scan configuration and findings relevance |
| Platform Engineering | Assess AWX feasibility for enterprise scale |
| Release Management | Evaluate CD workflow for process alignment |

---

## 5. Technical Architecture

### 5.1 Architecture Overview

The entire PoC runs on a single local workstation using containerized components. GitHub Actions self-hosted runner executes the CI phase locally, while AWX orchestrates the CD phase including deployment and security scanning.

```
┌──────────────────────────────────────────────────────────────────┐
│                     LOCAL WORKSTATION                             │
│                                                                  │
│  ┌──────────────────────┐        ┌────────────────────────────┐  │
│  │  GitHub Actions       │  API   │  AWX (Docker Compose)      │  │
│  │  Self-Hosted Runner   │───────▶│                            │  │
│  │                       │  POST  │  - Job Templates           │  │
│  │  - Build image        │        │  - Inventories             │  │
│  │  - Push to registry   │        │  - Credentials Vault       │  │
│  └──────────────────────┘        └──────────┬─────────────────┘  │
│                                              │                    │
│                                    Ansible Playbooks              │
│                                              │                    │
│                              ┌───────────────▼──────────────┐    │
│                              │  Local Dev Environment        │    │
│                              │  (Podman / Docker Compose)    │    │
│                              │                               │    │
│                              │  ┌─────────┐  ┌───────────┐  │    │
│                              │  │ Sample   │  │ OWASP ZAP │  │    │
│                              │  │ App      │  │ Scanner   │  │    │
│                              │  │ Container│  │ Container │  │    │
│                              │  └─────────┘  └───────────┘  │    │
│                              └──────────────────────────────┘    │
│                                                                  │
│  ┌──────────────────────┐                                        │
│  │  Local Registry       │                                       │
│  │  (Docker Registry v2) │                                       │
│  └──────────────────────┘                                        │
└──────────────────────────────────────────────────────────────────┘
```

### 5.2 Technology Stack

All components are open-source and run locally via containers.

| Component | Technology | Purpose | Version |
|---|---|---|---|
| CI Runner | GitHub Actions Self-Hosted Runner | Build and push container artifacts | Latest |
| CD Orchestrator | AWX (upstream of AAP) | Deployment automation and workflow orchestration | 24.x+ |
| Container Runtime | Podman or Docker | Run application and tooling containers | Latest stable |
| Container Registry | Docker Registry v2 | Local artifact storage (replaces Artifactory for PoC) | 2.8+ |
| DAST Scanner | OWASP ZAP | Dynamic application security testing | Latest stable |
| Sample Application | Any lightweight web app (e.g., OWASP Juice Shop) | Target application for deployment and scanning | Latest |
| Automation Language | Ansible Playbooks | Deployment and scan automation | ansible-core 2.16+ |
| Infrastructure | Docker Compose / Podman Compose | Local environment orchestration | Latest |

### 5.3 Component Details

**5.3.1 GitHub Actions Self-Hosted Runner**

A self-hosted runner installed on the local workstation, registered to the PoC GitHub repository. It executes CI workflows that build the container image and push it to the local Docker Registry v2 instance. The runner is configured with the `self-hosted` and `local-poc` labels for workflow targeting.

**5.3.2 AWX**

AWX is deployed via Docker Compose on the local workstation. It provides the web UI, REST API, credential vault, RBAC, job templates, and workflow engine. AWX serves as the functional equivalent of AAP for this PoC, allowing evaluation of CD orchestration capabilities without enterprise licensing.

**5.3.3 Local Docker Registry v2**

A lightweight, open-source container registry running locally to store built images. This replaces JFrog Artifactory for the PoC, eliminating external dependencies while preserving the push/pull workflow pattern.

**5.3.4 OWASP ZAP**

ZAP runs as a container launched by AWX via Ansible playbooks. It executes a baseline scan followed by an active scan against the deployed sample application. Results are exported as JSON and evaluated against a pass/fail threshold.

---

## 6. Functional Requirements

### 6.1 CI Phase — GitHub Actions

| ID | Requirement | Priority |
|---|---|---|
| FR-CI-01 | The GitHub Actions workflow shall execute on a self-hosted runner registered on the local workstation. | Must |
| FR-CI-02 | The workflow shall build a container image from the sample application source code. | Must |
| FR-CI-03 | The workflow shall tag the image using the Git commit SHA as the version identifier. | Must |
| FR-CI-04 | The workflow shall push the tagged image to the local Docker Registry v2 instance. | Must |
| FR-CI-05 | Upon successful image push, the workflow shall trigger the AWX deployment job template via REST API, passing the image tag as an extra variable. | Must |
| FR-CI-06 | The workflow shall fail and halt if the build or push step fails, preventing the AWX trigger. | Must |

### 6.2 CD Phase — AWX

| ID | Requirement | Priority |
|---|---|---|
| FR-CD-01 | AWX shall expose a Job Template that accepts an image tag as an input parameter and deploys the corresponding container to the local Dev environment. | Must |
| FR-CD-02 | AWX shall pull the specified image from the local Docker Registry v2 and deploy it using Ansible playbooks. | Must |
| FR-CD-03 | AWX shall verify that the deployed application is reachable (HTTP 200 on health endpoint) before proceeding to the ZAP scan. | Must |
| FR-CD-04 | AWX shall execute an OWASP ZAP baseline scan against the deployed application's URL. | Must |
| FR-CD-05 | AWX shall execute an OWASP ZAP active scan against the deployed application's URL after the baseline scan completes. | Should |
| FR-CD-06 | AWX shall export the ZAP scan report in JSON format to a designated local directory. | Must |
| FR-CD-07 | AWX shall evaluate ZAP findings against a configurable risk threshold (default: fail on High or Critical) and mark the job as failed if the threshold is exceeded. | Must |
| FR-CD-08 | AWX shall log all job executions with timestamps, user identity, parameters, and outcome for audit purposes. | Must |
| FR-CD-09 | The CD workflow in AWX shall be defined as a Workflow Template chaining: Deploy → ZAP Scan → Report, with failure handling at each stage. | Should |

### 6.3 Integration

| ID | Requirement | Priority |
|---|---|---|
| FR-INT-01 | The GitHub Actions workflow shall authenticate to the AWX API using a machine credential (OAuth2 token) stored as a GitHub Actions secret. | Must |
| FR-INT-02 | The AWX Job Template launch API shall validate the received image tag parameter before executing the playbook. | Should |
| FR-INT-03 | The pipeline shall be fully executable with a single `git push` event triggering the entire CI → CD → ZAP flow end to end. | Must |

---

## 7. Non-Functional Requirements

| ID | Requirement | Priority |
|---|---|---|
| NFR-01 | The entire PoC environment shall run on a single workstation with no external infrastructure dependencies. | Must |
| NFR-02 | The local workstation shall have a minimum of 16 GB RAM and 4 CPU cores to support all containerized components concurrently. | Must |
| NFR-03 | The complete pipeline (CI + CD + ZAP scan) shall execute end-to-end in under 15 minutes for the sample application. | Should |
| NFR-04 | All components shall be provisioned via Infrastructure-as-Code (Docker Compose files and Ansible playbooks) for reproducibility. | Must |
| NFR-05 | The PoC shall include a README with step-by-step setup instructions enabling any team member to reproduce the environment. | Must |
| NFR-06 | AWX credentials (registry credentials, API tokens) shall be stored in AWX's built-in credential vault, not in plaintext. | Must |

---

## 8. Pipeline Flow Definition

The end-to-end pipeline executes as follows:

**Step 1 — Developer pushes code** to the PoC GitHub repository.

**Step 2 — GitHub Actions CI workflow triggers** on the self-hosted runner with the `self-hosted` label.

**Step 3 — Build** the container image from the Dockerfile in the repository.

**Step 4 — Tag** the image as `localhost:5000/sample-app:{git-sha}`.

**Step 5 — Push** the tagged image to the local Docker Registry v2 at `localhost:5000`.

**Step 6 — Trigger AWX** via HTTP POST to `/api/v2/job_templates/{id}/launch/` with `extra_vars: { "image_tag": "{git-sha}" }`.

**Step 7 — AWX deploys** the application by pulling the image and running the container on the local Dev environment.

**Step 8 — AWX verifies** the application is healthy (HTTP 200 on the health endpoint).

**Step 9 — AWX launches ZAP** container, executes baseline scan, then active scan against the application URL.

**Step 10 — AWX evaluates** ZAP results against the risk threshold.

**Step 11a — If ZAP passes:** Job completes successfully. Report is saved locally.

**Step 11b — If ZAP fails:** Job is marked as failed. Report is saved locally with findings detail.

---

## 9. Success Criteria

| ID | Criterion |
|---|---|
| SC-01 | A `git push` triggers the full pipeline end-to-end without manual intervention. |
| SC-02 | The container image is built, tagged, and pushed to the local registry by GitHub Actions. |
| SC-03 | AWX receives the trigger, deploys the application, and the app responds with HTTP 200. |
| SC-04 | OWASP ZAP scan executes and produces a JSON report with findings. |
| SC-05 | The AWX job fails automatically when ZAP detects High or Critical findings. |
| SC-06 | All pipeline activity is visible in AWX's job history with full audit detail. |
| SC-07 | The environment can be torn down and recreated from code within 30 minutes. |

---

## 10. Risks and Mitigations

| Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|
| AWX Docker Compose deployment is resource-intensive and may degrade workstation performance | Medium | High | Document minimum hardware specs (NFR-02). Close non-essential applications during PoC execution. |
| ZAP active scans may produce false positives, undermining confidence in the gating mechanism | Medium | Medium | Configure ZAP scan policy to tune rules. Document known false positives in findings report. |
| Self-hosted runner security: running CI on a local machine introduces supply chain risk | Low | Low | Use a dedicated PoC repository with no access to production secrets or infrastructure. |
| AWX feature parity with AAP may not be exact, leading to incorrect assumptions about enterprise capabilities | Medium | Medium | Document any AWX limitations encountered and map to AAP equivalents in the findings report. |
| Network isolation on the local machine may cause connectivity issues between containers | Low | Medium | Use a shared Docker/Podman network for all PoC components. |

---

## 11. Deliverables

| ID | Deliverable | Format |
|---|---|---|
| D-01 | PoC source code repository including Dockerfiles, GitHub Actions workflow, Ansible playbooks, and Docker Compose files | GitHub Repository |
| D-02 | AWX Job Templates and Workflow Template export | JSON / YAML |
| D-03 | OWASP ZAP scan report from PoC execution | JSON |
| D-04 | Setup and execution guide (README) | Markdown |
| D-05 | Findings and recommendations report with AAP enterprise mapping | PDF / Markdown |

---

## 12. Timeline

| Phase | Duration | Activities |
|---|---|---|
| Environment Setup | 3 days | Install AWX, self-hosted runner, local registry, sample app |
| CI Pipeline | 2 days | GitHub Actions workflow for build and push |
| CD Pipeline | 3 days | AWX job templates, Ansible playbooks for deploy and ZAP |
| Integration and Testing | 2 days | End-to-end pipeline execution, troubleshooting |
| Documentation and Report | 2 days | README, findings report, enterprise recommendations |
| **Total** | **12 working days** | |

---

## 13. Approval

| Role | Name | Signature | Date |
|---|---|---|---|
| Author | | | |
| DevSecOps Lead | | | |
| Platform Engineering Lead | | | |

---

*End of Document*
