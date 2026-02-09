# Component Reference

Detailed reference for every component in the PoC. For architectural context, see [Architecture Overview](architecture.md). For design rationale, see [Technical Design](technical-design.md).

## Ansible Playbooks

### `deploy.yml` — Deploy Sample Application

**Purpose:** Pull the container image from the local registry and run it on the shared Docker network. Satisfies requirements FR-CD-01, FR-CD-02, FR-CD-03.

#### Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `image_tag` | Yes | — (mandatory) | Git SHA or tag of the image to deploy |
| `image_name` | No | `localhost:5000/sample-app` | Full registry path of the image |
| `container_name` | No | `sample-app` | Name for the running container |
| `app_port` | No | `8080` | Application port (container and host) |
| `app_host` | No | `localhost` | Hostname for health check URI. AWX overrides to `sample-app` for EE execution |
| `network_name` | No | `cd-ansible-zap_poc-network` | Docker network to attach the container to |

#### Task Sequence

1. **Pull application image** — `community.docker.docker_image` with `force_source: true`
2. **Stop and remove existing container** — `community.docker.docker_container` with `state: absent`
3. **Start application container** — `community.docker.docker_container` with port mapping and network attachment
4. **Wait for health check** — `ansible.builtin.uri` polling `GET /health` with 12 retries at 5s intervals
5. **Display health check result** — `ansible.builtin.debug`

#### Modules Used

- `community.docker.docker_image`
- `community.docker.docker_container`
- `ansible.builtin.uri`
- `ansible.builtin.debug`

---

### `zap-scan.yml` — Run OWASP ZAP Security Scans

**Purpose:** Execute ZAP baseline and full active scans against the deployed application, generating JSON reports. Satisfies requirements FR-CD-04, FR-CD-05, FR-CD-06.

#### Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `target_url` | No | `http://sample-app:8080` | URL to scan (uses Docker DNS) |
| `network_name` | No | `cd-ansible-zap_poc-network` | Docker network for ZAP containers |
| `reports_dir` | No | `{{ playbook_dir }}/../../reports` | Directory for report output. AWX overrides with host-absolute path |
| `zap_image` | No | `ghcr.io/zaproxy/zaproxy:stable` | ZAP Docker image |
| `rules_file` | No | `{{ playbook_dir }}/../../zap/rules.tsv` | ZAP scan rules configuration file. AWX overrides with host-absolute path |

#### Task Sequence

1. **Ensure reports directory exists** — `ansible.builtin.file` with `mode: 0777`
2. **Remove stale ZAP containers** — `community.docker.docker_container` with `state: absent` (loop)
3. **Run ZAP baseline scan** — `community.docker.docker_container` with `detach: false`, outputs `zap-baseline-report.json`
4. **Copy baseline report** — `ansible.builtin.command` using `docker cp`
5. **Remove baseline container** — cleanup
6. **Run ZAP full scan** — same pattern, outputs `zap-full-report.json`, `-m 10` (10-minute timeout)
7. **Copy full scan report** — `docker cp`
8. **Remove full scan container** — cleanup
9. **List generated reports** — `ansible.builtin.find`
10. **Display scan summary** — `ansible.builtin.debug`

#### Modules Used

- `community.docker.docker_container`
- `ansible.builtin.file`
- `ansible.builtin.command`
- `ansible.builtin.find`
- `ansible.builtin.debug`

---

### `evaluate-report.yml` — Evaluate ZAP Report (Security Gate)

**Purpose:** Parse the ZAP JSON report and fail the pipeline if findings meet or exceed the risk threshold. Satisfies requirement FR-CD-07.

#### Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `reports_dir` | No | `{{ playbook_dir }}/../../reports` | Directory containing ZAP reports. AWX overrides with host-absolute path |
| `report_file` | No | `{{ reports_dir }}/zap-full-report.json` | Specific report file to evaluate |
| `risk_threshold` | No | `3` | Minimum risk code to trigger failure (3=High, 4=Critical) |

#### Task Sequence

1. **Check if report exists** — `ansible.builtin.stat`
2. **Fail if report is missing** — `ansible.builtin.fail`
3. **Read ZAP JSON report** — `ansible.builtin.slurp`
4. **Parse report and extract alerts** — `ansible.builtin.set_fact` with `from_json`
5. **Extract high-risk alerts** — `ansible.builtin.set_fact` filtering `riskcode >= threshold`
6. **Display findings summary** — `ansible.builtin.debug`
7. **Display high-risk alert details** — `ansible.builtin.debug` (loop)
8. **Fail pipeline if high-risk findings found** — `ansible.builtin.fail`

#### Modules Used

- `ansible.builtin.stat`
- `ansible.builtin.fail`
- `ansible.builtin.slurp`
- `ansible.builtin.set_fact`
- `ansible.builtin.debug`

## Ansible Inventory

### `ansible/inventory/local.yml`

```yaml
all:
  hosts:
    localhost:
      ansible_connection: local
      ansible_python_interpreter: "{{ ansible_playbook_python }}"
```

All playbooks target `localhost` with a local connection. The Python interpreter is set to match the playbook's own Python, avoiding path mismatches between host and EE environments.

## AWX Configuration

### Setup Script Steps (`scripts/awx-setup.sh`)

The setup script provisions all AWX resources via the REST API. It requires AWX to be running and the API to be accessible.

| Step | Action | API Endpoint |
|---|---|---|
| 1/9 | Wait for AWX API readiness | `GET /api/v2/ping/` |
| 2/9 | Get Default organization ID | `GET /api/v2/organizations/` |
| 3/9 | Configure EE settings (isolation paths, network) | `PATCH /api/v2/settings/jobs/` |
| 4/9 | Create Inventory + localhost host | `POST /api/v2/inventories/`, `POST /api/v2/inventories/{id}/hosts/` |
| 5/9 | Create Manual Project (local_path) | `POST /api/v2/projects/` |
| 6/9 | Create Execution Environment + set as org default | `POST /api/v2/execution_environments/`, `PATCH /api/v2/organizations/{id}/` |
| 7/9 | Create 3 Job Templates (Deploy, ZAP Scan, Evaluate) | `POST /api/v2/job_templates/` |
| 8/9 | Create Workflow Template + chain nodes | `POST /api/v2/workflow_job_templates/`, `POST .../workflow_nodes/`, `POST .../success_nodes/` |
| 9/9 | Generate API token for GitHub Actions | `POST /api/v2/users/{id}/personal_tokens/` |

### AWX Services

| Service | Container Name | Image | Role |
|---|---|---|---|
| PostgreSQL | `awx-postgres` | `postgres:15` | AWX database (users, jobs, inventory, credentials) |
| Redis | `awx-redis` | `redis:7` | Message broker via Unix socket (Celery + Channels) |
| Init | `awx-init` | `awx-poc:24.6.1` | One-shot: migrations, admin user, instance registration |
| Web | `awx-web` | `awx-poc:24.6.1` | API server + web UI (nginx → uwsgi/daphne) |
| Task | `awx-task` | `awx-poc:24.6.1` | Job dispatcher + receptor daemon, launches EE containers |

### AWX Config Files

| File | Mount Path | Purpose | Key Settings |
|---|---|---|---|
| `settings.py` | `/etc/tower/settings.py` | Django configuration | DB connection, Redis broker, `ALLOWED_HOSTS`, `AWX_ISOLATION_BASE_PATH` |
| `SECRET_KEY` | `/etc/tower/SECRET_KEY` | Encryption key | Used by Django for signing (gitignored) |
| `environment.sh` | env_file | Shell environment variables | Database credentials, admin password |
| `nginx.conf` | `/etc/nginx/nginx.conf` | Reverse proxy | Listen :8013, upstream uwsgi :8050 + daphne :8051, WebSocket support |
| `redis.conf` | `/etc/redis/redis.conf` | Redis server config | Unix socket at `/var/run/redis/redis.sock`, `unixsocketperm 777`, TCP disabled |
| `receptor.conf` | `/etc/receptor/receptor.conf` | Receptor mesh config | Node `awx`, TCP listener :2222, control socket, ansible-runner work command |

## ZAP Scan Configuration

### Rules File (`zap/rules.tsv`)

The rules file configures ZAP's behavior for specific scan rules. Format: `<rule_id>\t<action>\t<name>`.

| Rule ID | Action | Name |
|---|---|---|
| 10003 | WARN | Vulnerable JS Library |
| 10010 | IGNORE | Cookie No HttpOnly Flag |
| 10011 | IGNORE | Cookie Without Secure Flag |
| 10015 | WARN | Re-examine Cache-control Directives |
| 10017 | IGNORE | Cross-Domain JavaScript Source File Inclusion |
| 10019 | WARN | Content-Type Header Missing |
| 10021 | WARN | X-Content-Type-Options Header Missing |
| 10036 | WARN | Server Leaks Version Information via "Server" HTTP Response Header Field |
| 10038 | WARN | Content Security Policy (CSP) Header Not Set |
| 10049 | WARN | Storable and Cacheable Content |
| 10055 | WARN | CSP: Wildcard Directive |
| 10096 | WARN | Timestamp Disclosure |
| 10098 | WARN | Cross-Domain Misconfiguration |

**Actions:**
- **IGNORE** — Suppress the finding entirely (not included in the report)
- **WARN** — Report the finding but do not affect the ZAP exit code
- **FAIL** — Report the finding and set a non-zero exit code

### Scan Types

| Scan | Command | Description |
|---|---|---|
| Baseline | `zap-baseline.py` | Spider + passive scan only. Fast (~30s). Finds misconfigurations and missing headers. |
| Full | `zap-full-scan.py` | Spider + passive + active scan. Slower (~60s with `-m 10` timeout). Finds injection flaws, XSS, etc. |

Both scans output JSON reports to the `reports/` directory and use the shared `rules.tsv` for rule overrides.

## Sample Application

### Endpoints

| Path | Method | Description | Used By |
|---|---|---|---|
| `/` | GET | Welcome message | ZAP scan target |
| `/health` | GET | Health check (`{"status":"UP"}`) | deploy.yml health check |
| `/info` | GET | Application info | ZAP scan target |

### Docker Build Stages

| Stage | Base Image | Purpose |
|---|---|---|
| `builder` | `maven:3.9-eclipse-temurin-17` | Compile source, download dependencies, package JAR |
| Runtime | `eclipse-temurin:17-jre-alpine` | Minimal JRE image, runs the application JAR |

### Spring Boot Configuration

| Setting | Value |
|---|---|
| Framework | Spring Boot 3.4.1 |
| Java version | 17 |
| Dependencies | `spring-boot-starter-web`, `spring-boot-starter-actuator` |
| Port | 8080 |
| Build tool | Maven 3.9 with `spring-boot-maven-plugin` |

## GitHub Actions Workflow

### `ci.yml` — Build and Push

| Property | Value |
|---|---|
| Trigger | `push` to `main` branch |
| Runner | `[self-hosted, local-poc]` |
| Job name | `build-and-push` |

### Steps

| # | Step | Action |
|---|---|---|
| 1 | Checkout code | `actions/checkout@v4` |
| 2 | Build Docker image | `docker build -t localhost:5000/sample-app:${{ github.sha }} ./sample-app` |
| 3 | Push to local registry | `docker push localhost:5000/sample-app:${{ github.sha }}` |
| 4 | Trigger AWX CD pipeline | `curl POST` to `awx-web:8013/api/v2/workflow_job_templates/{id}/launch/` with `extra_vars: {"image_tag": "<sha>"}` |

### Secrets

| Secret | Description |
|---|---|
| `AWX_TOKEN` | Bearer token for AWX API authentication |
| `AWX_WORKFLOW_TEMPLATE_ID` | Workflow Template ID to launch |

---

*See also: [Architecture Overview](architecture.md) | [Pipeline Workflow](pipeline-workflow.md) | [Technical Design](technical-design.md)*
