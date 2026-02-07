# CD Pipeline PoC — GitHub Actions, AWX, and OWASP ZAP

Proof of Concept for a CI/CD pipeline that decouples CI (GitHub Actions) from CD (AWX/Ansible) with integrated OWASP ZAP DAST scanning. The entire environment runs locally on a single workstation.

## Prerequisites

| Requirement | Minimum |
|---|---|
| Docker / Docker Compose | Latest stable |
| RAM | 16 GB |
| CPU cores | 4 |
| Java | 17 (only if building outside Docker) |
| Maven | 3.9+ (only if building outside Docker) |
| Ansible | ansible-core 2.16+ with `community.docker` collection |
| Git | Latest stable |

Install the Ansible Docker collection if not already present:

```bash
ansible-galaxy collection install community.docker
```

## Repository Structure

```
cd-ansible-zap/
├── .github/workflows/ci.yml          # GitHub Actions CI pipeline
├── sample-app/                        # Spring Boot sample application
│   ├── pom.xml
│   ├── Dockerfile
│   └── src/main/...
├── ansible/
│   ├── inventory/local.yml            # Localhost inventory
│   └── playbooks/
│       ├── deploy.yml                 # Deploy container
│       ├── zap-scan.yml               # Run ZAP scans
│       └── evaluate-report.yml        # Parse report, pass/fail gate
├── docker-compose.infra.yml           # Local registry (port 5000)
├── docker-compose.dev.yml             # Dev environment (app on port 8080)
├── docker-compose.runner.yml          # GitHub Actions self-hosted runner
├── zap/rules.tsv                      # ZAP scan rule config
└── reports/                           # ZAP report output directory
```

## Quick Start

### 1. Start Infrastructure

Launch the local Docker registry:

```bash
docker compose -f docker-compose.infra.yml up -d
```

Verify the registry is running:

```bash
curl http://localhost:5000/v2/_catalog
```

### 2. Build and Push the Sample App

Build the Docker image:

```bash
docker build -t localhost:5000/sample-app:latest ./sample-app
```

Push to the local registry:

```bash
docker push localhost:5000/sample-app:latest
```

### 3. Run the Sample App

Using Docker Compose:

```bash
IMAGE_TAG=latest docker compose -f docker-compose.dev.yml up -d
```

Or run the Ansible deploy playbook:

```bash
ansible-playbook -i ansible/inventory/local.yml ansible/playbooks/deploy.yml \
  -e "image_tag=latest"
```

Verify the app is running:

```bash
curl http://localhost:8080/health
# Expected: {"status":"UP"}
```

### 4. Run ZAP Security Scans

Execute the ZAP scan playbook:

```bash
ansible-playbook -i ansible/inventory/local.yml ansible/playbooks/zap-scan.yml
```

### 5. Evaluate Results

Run the report evaluation playbook:

```bash
ansible-playbook -i ansible/inventory/local.yml ansible/playbooks/evaluate-report.yml
```

This will fail the pipeline if any High or Critical findings are detected.

## Setting Up GitHub Actions Self-Hosted Runner

The self-hosted runner is containerized via `docker-compose.runner.yml` using the [`myoung34/github-runner`](https://github.com/myoung34/docker-github-actions-runner) image.

### 1. Generate a Runner Registration Token

Using GitHub CLI:

```bash
gh api -X POST repos/poc-pipeline/cd-ansible-zap/actions/runners/registration-token --jq '.token'
```

Or navigate to **Settings > Actions > Runners > New self-hosted runner** in the GitHub repository and copy the token shown during setup.

> **Note:** Registration tokens expire after 1 hour. Generate a new one if the runner fails to register.

### 2. Create a `.env` File

Create a `.env` file in the project root (this file is gitignored):

```bash
RUNNER_TOKEN=<paste-your-registration-token-here>
```

### 3. Start the Runner

Ensure the `poc-network` is already running (from the infra compose), then start the runner:

```bash
docker compose -f docker-compose.runner.yml up -d
```

### 4. Verify the Runner is Online

Check the container logs:

```bash
docker logs github-runner
```

You should see output like:

```
√ Connected to GitHub
Current runner version: '2.x.x'
Listening for Jobs
```

You can also verify in GitHub: **Settings > Actions > Runners** — the runner should show as **Idle** with labels `self-hosted`, `Linux`, and `local-poc`.

### 5. Runner Lifecycle

| Action | Command |
|---|---|
| Start runner | `docker compose -f docker-compose.runner.yml up -d` |
| Stop runner | `docker compose -f docker-compose.runner.yml down` |
| View logs | `docker logs -f github-runner` |
| Restart runner | `docker compose -f docker-compose.runner.yml restart` |

### Docker-in-Docker Access

The runner mounts the host Docker socket (`/var/run/docker.sock`), allowing it to build and push Docker images as part of CI workflows. This is required for the `docker build` and `docker push` steps in `ci.yml`.

### Required GitHub Secrets

Configure these in **Settings > Secrets and variables > Actions**:

| Secret | Description |
|---|---|
| `AWX_TOKEN` | OAuth2 token for AWX API authentication |
| `AWX_JOB_TEMPLATE_ID` | ID of the AWX Job Template to trigger |

## AWX Setup

1. Deploy AWX using the [official AWX Operator](https://github.com/ansible/awx-operator) or Docker Compose method.
2. Create a **Project** pointing to this repository.
3. Create an **Inventory** using `ansible/inventory/local.yml`.
4. Create **Job Templates** for each playbook:
   - **Deploy** — runs `ansible/playbooks/deploy.yml` with `image_tag` as a survey variable
   - **ZAP Scan** — runs `ansible/playbooks/zap-scan.yml`
   - **Evaluate Report** — runs `ansible/playbooks/evaluate-report.yml`
5. Create a **Workflow Template** chaining: Deploy → ZAP Scan → Evaluate Report.
6. Generate an API token under **Users > Tokens** for GitHub Actions integration.

## Full Pipeline End-to-End

Once all components are configured:

1. Ensure infrastructure is running: `docker compose -f docker-compose.infra.yml up -d`
2. Ensure the self-hosted runner is active: `docker compose -f docker-compose.runner.yml up -d`
3. Ensure AWX is running and the Workflow Template is configured.
4. Push a commit to `main`:

```bash
git add . && git commit -m "trigger pipeline" && git push origin main
```

The pipeline will automatically:
- Build and tag the Docker image (CI — GitHub Actions)
- Push the image to the local registry (CI — GitHub Actions)
- Trigger AWX via API (CI → CD handoff)
- Deploy the container (CD — AWX/Ansible)
- Run ZAP baseline + active scans (CD — AWX/Ansible)
- Evaluate findings and pass/fail (CD — AWX/Ansible)

## Teardown

Stop and remove all containers and volumes:

```bash
docker compose -f docker-compose.runner.yml down
docker compose -f docker-compose.dev.yml down
docker compose -f docker-compose.infra.yml down -v
docker rm -f sample-app zap-baseline zap-full 2>/dev/null
```

## Troubleshooting

| Issue | Solution |
|---|---|
| Registry unreachable | Ensure `docker compose -f docker-compose.infra.yml up -d` is running |
| App health check fails | Check container logs: `docker logs sample-app` |
| ZAP cannot reach app | Ensure both containers are on `cd-ansible-zap_poc-network` |
| AWX trigger fails | Verify `AWX_TOKEN` and `AWX_JOB_TEMPLATE_ID` secrets are set correctly |
| Ansible collection missing | Run `ansible-galaxy collection install community.docker` |
