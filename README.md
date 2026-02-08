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
├── awx/
│   ├── Dockerfile                     # Extends AWX image with receptor
│   └── config/                        # AWX configuration files
│       ├── settings.py                # Django settings (DB, Redis, secrets)
│       ├── environment.sh             # Shell env vars (DB, admin creds)
│       ├── nginx.conf                 # Nginx reverse proxy config
│       ├── redis.conf                 # Redis Unix socket config
│       ├── receptor.conf              # Receptor mesh config
│       └── SECRET_KEY                 # Encryption key (gitignored)
├── scripts/
│   └── awx-setup.sh                   # Automated AWX resource setup
├── docker-compose.infra.yml           # Local registry (port 5000)
├── docker-compose.awx.yml             # AWX (web, task, postgres, redis)
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
| `AWX_TOKEN` | API token for AWX authentication (from `awx-setup.sh` output) |
| `AWX_WORKFLOW_TEMPLATE_ID` | Workflow Template ID (from `awx-setup.sh` output) |

## AWX Setup

AWX is deployed via Docker Compose with five services: PostgreSQL, Redis, an init container (migrations + admin user), the web UI/API, and the task runner.

### 1. Start AWX

Ensure the infrastructure network is running first, then start AWX:

```bash
docker compose -f docker-compose.infra.yml up -d
docker compose -f docker-compose.awx.yml up -d
```

The init container (`awx-init`) runs database migrations and creates the admin user. This takes 2-3 minutes on first launch. Monitor progress:

```bash
docker logs -f awx-init
```

Wait until you see `AWX init completed successfully`, then verify the API is reachable:

```bash
curl http://localhost:8043/api/v2/ping/
```

The AWX web UI is available at `http://localhost:8043` (username: `admin`, password: `admin`).

### 2. Run the Setup Script

The setup script automatically creates all AWX resources via the REST API:

```bash
bash scripts/awx-setup.sh
```

This creates:
- **Inventory** — localhost with local connection
- **Project** — manual project pointing to mounted playbooks
- **Job Templates** — Deploy, ZAP Scan, Evaluate Report
- **Workflow Template** — Deploy → ZAP Scan → Evaluate Report
- **API Token** — for GitHub Actions authentication

The script outputs the values needed for GitHub secrets.

### 3. Configure GitHub Secrets

Copy the values from the setup script output and add them as repository secrets in **Settings > Secrets and variables > Actions**.

### AWX Lifecycle

| Action | Command |
|---|---|
| Start AWX | `docker compose -f docker-compose.awx.yml up -d` |
| Stop AWX | `docker compose -f docker-compose.awx.yml down` |
| View web logs | `docker logs -f awx-web` |
| View task logs | `docker logs -f awx-task` |
| Reset AWX (destroy data) | `docker compose -f docker-compose.awx.yml down -v` |

## Full Pipeline End-to-End

Once all components are configured:

1. Ensure infrastructure is running: `docker compose -f docker-compose.infra.yml up -d`
2. Ensure AWX is running: `docker compose -f docker-compose.awx.yml up -d`
3. Ensure the self-hosted runner is active: `docker compose -f docker-compose.runner.yml up -d`
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
docker compose -f docker-compose.awx.yml down -v
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
| AWX trigger fails | Verify `AWX_TOKEN` and `AWX_WORKFLOW_TEMPLATE_ID` secrets are set correctly |
| AWX init takes too long | First run can take 2-3 min; monitor with `docker logs -f awx-init` |
| AWX API not responding | Check `docker logs awx-web`; ensure init completed first |
| AWX setup script fails | Ensure AWX API is reachable: `curl http://localhost:8043/api/v2/ping/` |
| ZAP paths wrong in AWX | Re-run `awx-setup.sh` — it detects host-absolute paths automatically |
| Ansible collection missing | Run `ansible-galaxy collection install community.docker` |
