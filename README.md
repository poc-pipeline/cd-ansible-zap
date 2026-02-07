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

1. Go to your GitHub repository **Settings > Actions > Runners > New self-hosted runner**.
2. Follow the instructions to download and configure the runner on your workstation.
3. Add the labels `self-hosted` and `local-poc` to the runner.
4. Start the runner:

```bash
cd actions-runner
./run.sh
```

### Required GitHub Secrets

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
2. Ensure the GitHub Actions self-hosted runner is active.
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
