#!/usr/bin/env bash
# awx-setup.sh — Configure AWX resources via REST API
# Creates: Inventory, Project, Job Templates, Workflow Template, API Token
set -euo pipefail

AWX_URL="${AWX_URL:-http://localhost:8043}"
AWX_USER="${AWX_USER:-admin}"
AWX_PASS="${AWX_PASS:-admin}"

# Resolve host-absolute paths for Docker volume mounts inside AWX
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOST_REPORTS_DIR="${PROJECT_ROOT}/reports"
HOST_ZAP_DIR="${PROJECT_ROOT}/zap"

# ── Helpers ───────────────────────────────────────────────────────────────────

awx_api() {
  local method="$1" endpoint="$2"
  shift 2
  curl --fail --silent --show-error \
    -u "${AWX_USER}:${AWX_PASS}" \
    -H "Content-Type: application/json" \
    -X "$method" \
    "${AWX_URL}/api/v2${endpoint}" \
    "$@"
}

echo "================================================================"
echo " AWX Setup — Automated Configuration"
echo "================================================================"
echo ""
echo "AWX URL:  ${AWX_URL}"
echo "Project:  ${PROJECT_ROOT}"
echo ""

# ── 1. Wait for AWX API ───────────────────────────────────────────────────────

echo "--- [1/9] Waiting for AWX API readiness..."
MAX_WAIT=180
ELAPSED=0
until awx_api GET /ping/ -o /dev/null 2>/dev/null; do
  if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
    echo "ERROR: AWX API not ready after ${MAX_WAIT}s. Is AWX running?"
    exit 1
  fi
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  echo "  Waiting... (${ELAPSED}s)"
done
echo "  AWX API is ready."

# ── 2. Get Default Organization ───────────────────────────────────────────────

echo "--- [2/9] Getting Default organization..."
ORG_ID=$(awx_api GET /organizations/ | python3 -c "
import sys, json
for r in json.load(sys.stdin)['results']:
    if r['name'] == 'Default':
        print(r['id']); break
")
echo "  Organization ID: ${ORG_ID}"

# ── 3. Configure EE Settings ────────────────────────────────────────────────

echo "--- [3/8] Configuring Execution Environment settings..."
awx_api PATCH /settings/jobs/ \
  -d "{
    \"AWX_ISOLATION_SHOW_PATHS\": [\"/var/run/docker.sock\", \"${HOST_REPORTS_DIR}\"],
    \"DEFAULT_CONTAINER_RUN_OPTIONS\": [\"--network\", \"cd-ansible-zap_poc-network\"]
  }" > /dev/null
echo "  AWX_ISOLATION_SHOW_PATHS: /var/run/docker.sock, ${HOST_REPORTS_DIR}"
echo "  DEFAULT_CONTAINER_RUN_OPTIONS: --network cd-ansible-zap_poc-network"

# ── 4. Create Inventory ──────────────────────────────────────────────────────

echo "--- [4/9] Creating Inventory..."
INV_ID=$(awx_api POST /inventories/ \
  -d "{
    \"name\": \"PoC Local Inventory\",
    \"organization\": ${ORG_ID},
    \"description\": \"Localhost inventory for CD pipeline PoC\"
  }" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "  Inventory ID: ${INV_ID}"

echo "  Adding localhost host..."
awx_api POST /inventories/${INV_ID}/hosts/ \
  -d '{
    "name": "localhost",
    "variables": "ansible_connection: local\nansible_python_interpreter: /usr/bin/python3"
  }' > /dev/null
echo "  Host added."

# ── 5. Create Manual Project ─────────────────────────────────────────────────

echo "--- [5/9] Creating Manual Project..."
PROJ_ID=$(awx_api POST /projects/ \
  -d "{
    \"name\": \"CD Ansible ZAP\",
    \"organization\": ${ORG_ID},
    \"scm_type\": \"\",
    \"local_path\": \"cd-ansible-zap\",
    \"description\": \"Manual project — playbooks mounted from host\"
  }" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "  Project ID: ${PROJ_ID}"

# ── 6. Create Execution Environment ──────────────────────────────────────────────────

echo "--- [6/9] Creating Execution Environment..."
EE_ID=$(awx_api POST /execution_environments/ \
  -d "{
    \"name\": \"AWX EE (Default)\",
    \"image\": \"localhost:5000/awx-ee-poc:latest\",
    \"organization\": ${ORG_ID},
    \"pull\": \"missing\"
  }" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "  Execution Environment ID: ${EE_ID}"

echo "  Setting as default EE..."
awx_api PATCH /organizations/${ORG_ID}/ \
  -d "{\"default_environment\": ${EE_ID}}" > /dev/null
echo "  Default EE set."

# ── 7. Create Job Templates ──────────────────────────────────────────────────

echo "--- [7/9] Creating Job Templates..."

# Deploy Job Template
DEPLOY_JT_ID=$(awx_api POST /job_templates/ \
  -d "{
    \"name\": \"Deploy Sample App\",
    \"job_type\": \"run\",
    \"inventory\": ${INV_ID},
    \"project\": ${PROJ_ID},
    \"playbook\": \"ansible/playbooks/deploy.yml\",
    \"ask_variables_on_launch\": true,
    \"extra_vars\": \"app_host: sample-app\",
    \"description\": \"Deploy sample-app container from local registry\"
  }" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "  Deploy JT ID: ${DEPLOY_JT_ID}"

# ZAP Scan Job Template — override paths with host-absolute paths
ZAP_JT_ID=$(awx_api POST /job_templates/ \
  -d "{
    \"name\": \"ZAP Security Scan\",
    \"job_type\": \"run\",
    \"inventory\": ${INV_ID},
    \"project\": ${PROJ_ID},
    \"playbook\": \"ansible/playbooks/zap-scan.yml\",
    \"extra_vars\": \"reports_dir: ${HOST_REPORTS_DIR}\\nrules_file: ${HOST_ZAP_DIR}/rules.tsv\",
    \"description\": \"Run OWASP ZAP baseline and full scans\"
  }" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "  ZAP Scan JT ID: ${ZAP_JT_ID}"

# Evaluate Report Job Template
EVAL_JT_ID=$(awx_api POST /job_templates/ \
  -d "{
    \"name\": \"Evaluate ZAP Report\",
    \"job_type\": \"run\",
    \"inventory\": ${INV_ID},
    \"project\": ${PROJ_ID},
    \"playbook\": \"ansible/playbooks/evaluate-report.yml\",
    \"extra_vars\": \"reports_dir: ${HOST_REPORTS_DIR}\",
    \"description\": \"Parse ZAP report and enforce security gate\"
  }" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "  Evaluate JT ID: ${EVAL_JT_ID}"

# ── 6. Create Workflow Template ───────────────────────────────────────────────

echo "--- [8/9] Creating Workflow Template..."
WF_ID=$(awx_api POST /workflow_job_templates/ \
  -d "{
    \"name\": \"CD Pipeline — Deploy, Scan, Evaluate\",
    \"organization\": ${ORG_ID},
    \"ask_variables_on_launch\": true,
    \"description\": \"Full CD chain: Deploy → ZAP Scan → Evaluate Report\"
  }" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "  Workflow Template ID: ${WF_ID}"

# Add workflow nodes: Deploy → ZAP Scan → Evaluate
echo "  Adding workflow nodes..."

# Node 1: Deploy (root node)
DEPLOY_NODE_ID=$(awx_api POST /workflow_job_templates/${WF_ID}/workflow_nodes/ \
  -d "{\"unified_job_template\": ${DEPLOY_JT_ID}}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

# Node 2: ZAP Scan (on Deploy success)
ZAP_NODE_ID=$(awx_api POST /workflow_job_template_nodes/${DEPLOY_NODE_ID}/success_nodes/ \
  -d "{\"unified_job_template\": ${ZAP_JT_ID}}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

# Node 3: Evaluate Report (on ZAP success)
awx_api POST /workflow_job_template_nodes/${ZAP_NODE_ID}/success_nodes/ \
  -d "{\"unified_job_template\": ${EVAL_JT_ID}}" > /dev/null

echo "  Workflow chain: Deploy → ZAP Scan → Evaluate Report"

# ── 7. Generate API Token ────────────────────────────────────────────────────

echo "--- [9/9] Generating API token..."
ADMIN_ID=$(awx_api GET /users/ | python3 -c "
import sys, json
for r in json.load(sys.stdin)['results']:
    if r['username'] == 'admin':
        print(r['id']); break
")

TOKEN=$(awx_api POST /users/${ADMIN_ID}/personal_tokens/ \
  -d '{"scope": "write", "description": "GitHub Actions CI token"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

# ── Output ────────────────────────────────────────────────────────────────────

echo ""
echo "================================================================"
echo " AWX Setup Complete!"
echo "================================================================"
echo ""
echo " Add these as GitHub repository secrets:"
echo ""
echo "   AWX_TOKEN=${TOKEN}"
echo "   AWX_WORKFLOW_TEMPLATE_ID=${WF_ID}"
echo "   AWX_DEPLOY_JT_ID=${DEPLOY_JT_ID}"
echo ""
echo " AWX Web UI: ${AWX_URL} (admin/admin)"
echo ""
echo " To test the workflow manually:"
echo "   curl -X POST -H \"Authorization: Bearer ${TOKEN}\" \\"
echo "     -H \"Content-Type: application/json\" \\"
echo "     -d '{\"extra_vars\": {\"image_tag\": \"latest\"}}' \\"
echo "     ${AWX_URL}/api/v2/workflow_job_templates/${WF_ID}/launch/"
echo ""
echo "================================================================"
