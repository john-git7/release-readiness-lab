# Release Readiness Report & Go / No-Go Decision

**Service:** Checkout API (`checkout-api`)  
**Release Candidate:** `v2.4`  
**Target Environment:** Production Kubernetes Cluster (`checkout-system` namespace)  
**Report Date:** 2026-08-20  
**Report Author:** Release Engineering & SRE Team  
**Release Commander:** Jordan Taylor  

---

## DECISION: ❌ NO-GO

> **v2.4 is NOT cleared for production deployment.**  
> Three (3) Critical release blockers are unresolved. Deployment in current state will cause data loss, state fragmentation across checkout replicas, and silent production failures masked by a defective health check. A **NO-GO** verdict is mandatory until all three blockers are fully remediated and independently verified.

---

## 1. Executive Summary

The Checkout API `v2.4` release candidate introduces minor performance improvements to the checkout pipeline (per `docs/architecture.md`). However, an operational audit of the Kubernetes configuration, runtime application code, and dependency management reveals **3 Critical blockers** and **4 additional medium-severity gaps** that together represent an unacceptable risk to production data integrity, system observability, and security posture.

| Area Audited | Files Reviewed | Finding | Severity |
| :--- | :--- | :--- | :---: |
| Runtime Configuration | `k8s/configmap.yaml`, `app/app.py` | `DATABASE_URL` and `REDIS_URL` missing from ConfigMap | 🔴 Critical |
| Health Check Logic | `app/app.py` `/health` endpoint | Returns `200 OK` + `"healthy"` on broken fallback config, defeating K8s probes | 🔴 Critical |
| Multi-Pod State | `k8s/deployment.yaml` (3 replicas), `app/app.py` | 3 pods each run independent SQLite + in-memory cache; no shared state | 🔴 Critical |
| Container Security | `app/Dockerfile` | Application runs as root; production image contains test tooling `pytest` | 🟡 High |
| Dependency Management | `app/requirements.txt` | Missing DB/cache drivers (`psycopg2`, `redis`); unpinned sub-deps | 🟡 High |
| Infrastructure Resilience | `k8s/deployment.yaml` | No pod anti-affinity; all 3 replicas may schedule on same node | 🟡 Medium |
| Deployment Automation | `scripts/deploy.sh` | No pre-flight checks, secret validation, or auto-rollback on failure | 🟡 Medium |
| Rollback Readiness | Repository (pre-pack) | No tested rollback plan existed before this pack | ✅ Remediated |
| Ownership & Governance | Repository (pre-pack) | No defined deployment owners or escalation paths before this pack | ✅ Remediated |

---

## 2. Critical Blocker Detail

### Blocker 1 — Missing Production Backing Service Configuration (RSK-001 & RSK-002)
**Source:** `k8s/configmap.yaml` lines 9–10  
**Evidence:**
```yaml
# Note: Developers forgot to include DATABASE_URL and REDIS_URL here.
# This causes the application to default to volatile, in-memory SQLite and local cache.
```
**Runtime Output Confirming Failure:**
```text
2026-08-20 10:41:37,010 [WARNING] checkout-api: DATABASE_URL is not set! Using unstable, volatile in-memory SQLite fallback.
2026-08-20 10:41:37,010 [WARNING] checkout-api: REDIS_URL is not set! Using volatile local in-memory dict cache fallback.
```
**Impact:** All three Kubernetes replicas (3 pods × independent SQLite DBs) would store checkout transactions in non-shared, non-persistent memory. Every pod restart causes permanent, unrecoverable loss of customer cart and payment data.  
**Required Remediation:** Inject `DATABASE_URL` and `REDIS_URL` via a Kubernetes `Secret` (not a `ConfigMap`) bound to the deployment via `secretRef`.

---

### Blocker 2 — Health Check Returns False-Positive "Healthy" on Broken Configuration (RSK-003)
**Source:** `app/app.py`, lines 48–57  
**Evidence:**
```python
status_code = 200  # Always 200, regardless of fallback state

return jsonify({
    "status": "healthy",  # Always "healthy", regardless of fallback state
    ...
})
```
**Runtime Verification Confirming Failure:**
```text
Scenario A (No DB/Redis configured):
GET /health → HTTP 200 {"status": "healthy", "checks": {"database": "warning_fallback_sqlite", "redis": "warning_fallback_local"}}
```
**Impact:** Kubernetes `readinessProbe` and `livenessProbe` both query `/health`. Because the health endpoint always returns `200 OK`, Kubernetes marks every replica `Ready` and routes live customer traffic to pods operating in a broken, data-lossy configuration. The orchestration layer has been completely deceived.  
**Required Remediation:** Modify `/health` to return `HTTP 503 Service Unavailable` when `DATABASE_URL` or `REDIS_URL` is absent, preventing Kubernetes from routing traffic to misconfigured pods.

---

## 3. Medium Severity Gaps (Required Before General Availability)

| # | Risk ID | Gap | Action Required |
| :---: | :---: | :--- | :--- |
| 1 | RSK-004 | Container executes as `root`; `pytest` bundled in production image | Implement multi-stage Dockerfile; add `USER 10001` directive |
| 2 | RSK-005 | Transitive dependencies unpinned; missing `psycopg2` and `redis` drivers | Generate `requirements.lock`; add DB/cache drivers; separate dev requirements |
| 3 | RSK-006 | All 3 pods may schedule on same Kubernetes node | Add `podAntiAffinity` topology constraint to `deployment.yaml` |
| 4 | RSK-007 | `scripts/deploy.sh` executes blind with no pre-flight validation | Add secret existence checks, rollout timeout, and auto-fallback to `rollback.sh` |

---

## 4. Evidence-Backed Assessment Summary

| Document | Key Finding | Status |
| :--- | :--- | :---: |
| [`validation-results.md`](./validation-results.md) | 2/2 unit tests pass; but tests do not validate production dependencies; health check sends false-positive to probes | ⚠️ Incomplete |
| [`config-verification.md`](./config-verification.md) | `DATABASE_URL` and `REDIS_URL` absent from `configmap.yaml`; sensitive credentials must use Kubernetes Secret | ❌ Blocked |
| [`dependency-checks.md`](./dependency-checks.md) | Direct versions pinned; transitive deps unpinned; pytest in prod; DB/cache drivers missing | ❌ Blocked |
| [`rollback-plan.md`](./rollback-plan.md) | Complete rollback plan authored; `scripts/rollback.sh` created; v2.3 confirmed as stable baseline | ✅ Ready |
| [`risk-analysis.md`](./risk-analysis.md) | 3 Critical (Score 25) blockers; 4 Medium risks; post-remediation score acceptable | ❌ Blocked |
| [`ownership.md`](./ownership.md) | Deployment owners, on-call contacts, escalation path, and deployment window schedule defined | ✅ Ready |

---

## 5. What Must Change to Reach "Go"

The following 3 items are **mandatory** gates. Until all three are closed and independently verified, the `v2.4` candidate must not be promoted to production.

```
┌─────────────────────────────────────────────────────────────────────┐
│  MANDATORY PRE-RELEASE CHECKLIST (All gates must be GREEN)          │
├─────────────────────────────────────────────────────────────────────┤
│  [ ] GATE 1: Deploy checkout-api-secrets with DATABASE_URL and      │
│              REDIS_URL; bind via secretRef in deployment.yaml.      │
│              Verified by: Pod startup log shows "CONNECTED"         │
│                                                                     │
│  [ ] GATE 2: Patch /health endpoint to return HTTP 503 when         │
│              backing service env vars are absent.                   │
│              Verified by: Remove env vars → curl /health → 503      │
│                                                                     │
│  [ ] GATE 3: Re-run full unit test suite on patched app.py.         │
│              Update test_health to assert status == "connected"     │
│              when backing services are configured.                  │
│              Verified by: pytest exits 0; tests assert connectivity │
│                                                                     │
│  [ ] GATE 4 (Pre-GA): Non-root Dockerfile + psycopg2 + redis        │
│              drivers + pinned transitive deps + pod anti-affinity   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 6. Rollback Coverage Confirmation

If deployment proceeds prematurely and any of the above blockers manifest:
- **Stable baseline:** `kalvium/checkout-api:v2.3` (deployed prod since 2026-06-01).
- **Rollback command:** `kubectl rollout undo deployment/checkout-api -n checkout-system`
- **Automated rollback:** `scripts/rollback.sh` (verified to complete within 120-second timeout).
- **Target MTTR:** < 2 minutes.

---

## 7. Final Sign-Off

| Role | Name | Status | Comments |
| :--- | :--- | :---: | :--- |
| Release Commander | Jordan Taylor | ⏳ **Pending Blocker Resolution** | Will re-evaluate after Gates 1–3 cleared |
| SRE Lead | Sarah Jenkins | ⏳ **Pending Blocker Resolution** | Rollback plan verified; awaiting secret injection |
| Backend Engineering Lead | Alex Chen | ⏳ **Pending** | Responsible for code patch (Gate 2) |
| Security Engineer | David Kumar | ⏳ **Pending** | Container hardening required pre-GA |
