# Release Validation & Test Results Report

**Target Release:** Checkout API `v2.4` (Release Candidate)  
**Target Environment:** Kubernetes (`checkout-system` namespace)  
**Evaluation Date:** 2026-08-20  
**Evaluator:** Release Engineering & SRE Team  
**Git Branch:** `feature/readiness-pack`  
**Base Commit:** `ebe39e6` (`docs: fix repo structure links to relative paths`)

---

## 1. Executive Summary

This document records the automated and manual verification results conducted on the **Checkout API v2.4 Release Candidate**. While syntax checks and unit tests passed under default mock conditions, deeper runtime validation uncovered critical operational discrepancies between the application's configuration expectations and the Kubernetes deployment manifests.

| Validation Category | Status | Details |
| :--- | :---: | :--- |
| **Python Syntax & Compilation** | ✅ PASS | `py_compile` passed for `app/app.py` and `app/test_app.py` |
| **Unit Test Suite** | ⚠️ PASS (CONDITIONAL) | 2/2 unit tests passed (`test_index`, `test_health`), but tests do not validate real external dependencies |
| **Runtime Configuration Validation** | ❌ FAIL | Default runtime drops into volatile in-memory SQLite and local dictionary cache due to missing environment variables |
| **Health Check Operational Integrity** | ❌ FAIL | `/health` returns `HTTP 200 OK` (`status: healthy`) even when operating on degraded volatile fallbacks, defeating Kubernetes probe gating |
| **Container Build & Packaging** | ⚠️ WARN | Dockerfile uses `python:3.11-slim` without non-root user, contains test runner `pytest` in production image |
| **Kubernetes Manifest Validation** | ⚠️ WARN | Manifests are syntactically valid YAML but miss required secret bindings and pod anti-affinity rules |

---

## 2. Automated Test & Build Evidence

### 2.1 Python Syntax Compilation (`py_compile`)
The codebase was verified for Python 3.11/3.12 syntactic compatibility.

```bash
$ python -m py_compile app/app.py app/test_app.py
```
*Result:* Exit Code `0` (Clean compilation, zero syntax errors).

---

### 2.2 Unit Test Execution (`pytest`)
The test suite was executed against `app/test_app.py`.

```text
============================= test session starts =============================
platform win32 -- Python 3.12.10, pytest-8.4.2, pluggy-1.6.0
rootdir: D:\release-readiness-lab
collected 2 items

app\test_app.py ..                                                       [100%]

============================== 2 passed in 1.40s ==============================
```

#### Test Suite Breakdown
1. `test_index`: Asserts that `GET /` returns `HTTP 200`, `service: checkout-api`, and `version: v2.4`. (Passed)
2. `test_health`: Asserts that `GET /health` returns `HTTP 200` and contains `checks` object. (Passed)

> [!WARNING]
> **Test Gap Identified:** `test_app.py` asserts that `status == "healthy"` when `checks` contains `database` and `redis`, but it **does not assert that the checks are in state `"connected"`**. It happily passes when the checks report `"warning_fallback_sqlite"` and `"warning_fallback_local"`.

---

## 3. Runtime & Endpoint Behavior Validation

To verify runtime behavior, the application was tested under two scenarios:
1. **Scenario A (Production Manifest State):** Missing `DATABASE_URL` and `REDIS_URL` as defined in `k8s/configmap.yaml`.
2. **Scenario B (Target Enterprise State):** Valid `DATABASE_URL` and `REDIS_URL` supplied via environment.

### 3.1 Execution Log & Output Comparison

```python
# Validation Script Output
2026-08-20 10:41:37,009 [INFO] checkout-api: Handling request at / endpoint
2026-08-20 10:41:37,010 [WARNING] checkout-api: DATABASE_URL is not set! Using unstable, volatile in-memory SQLite fallback.
2026-08-20 10:41:37,010 [WARNING] checkout-api: REDIS_URL is not set! Using volatile local in-memory dict cache fallback.
2026-08-20 10:41:37,011 [INFO] checkout-api: Database status: CONNECTED
2026-08-20 10:41:37,011 [INFO] checkout-api: Redis cache status: CONNECTED
```

#### Response Comparison Matrix

| Scenario | Endpoint | HTTP Status | Response Payload | Assessment |
| :--- | :--- | :---: | :--- | :--- |
| **A: Current K8s Config** | `GET /` | `200 OK` | `{"service": "checkout-api", "version": "v2.4", "message": "Release Readiness Demo"}` | Normal |
| **A: Current K8s Config** | `GET /health` | `200 OK` | `{"checks": {"database": "warning_fallback_sqlite", "redis": "warning_fallback_local"}, "status": "healthy", "version": "v2.4"}` | **CRITICAL DEFECT** (False positive health) |
| **B: Target Config** | `GET /health` | `200 OK` | `{"checks": {"database": "connected", "redis": "connected"}, "status": "healthy", "version": "v2.4"}` | Expected Production Behavior |

---

## 4. Kubernetes Manifest & Architecture Validation

### 4.1 Deployment Resource & Probe Analysis (`k8s/deployment.yaml`)
- **Replicas:** `3`
- **Container Port:** `5000`
- **Resource Requests:** CPU `100m`, Memory `128Mi`
- **Resource Limits:** CPU `500m`, Memory `256Mi`
- **Readiness Probe:** `GET /health` on port 5000 (`initialDelaySeconds: 5`, `periodSeconds: 10`)
- **Liveness Probe:** `GET /health` on port 5000 (`initialDelaySeconds: 15`, `periodSeconds: 20`)

### 4.2 Multi-Pod State Fragmentation Risk
Because the deployment requests `3` replicas while the configuration lacks central database and cache endpoints:
1. Pod 1, Pod 2, and Pod 3 each instantiate their own independent in-memory SQLite database and Python dictionary cache.
2. Ingress traffic load-balanced across the 3 pods will encounter inconsistent cart states, phantom checkouts, and missing transaction records.
3. Pod restarts or autoscaling events will trigger permanent data loss.

---

## 5. CI Pipeline Audit (`.github/workflows/ci.yml`)

The CI workflow currently executes:
1. `python -m py_compile app/app.py app/test_app.py`
2. `pytest app/test_app.py`
3. `docker build (dry run)`

### Missing CI Gates
- ❌ No linter/formatter enforcement (`flake8`, `black`, `ruff`).
- ❌ No security scanning / SAST (`bandit`, `trivy`, `snyk`).
- ❌ No Kubernetes manifest linting (`kubeconform`, `kustomize build`, `polaris`).
- ❌ No integration testing against containerized backing services (PostgreSQL & Redis service containers).
- ❌ No image signing or SBOM generation (`cosign`, `syft`).

---

## 6. Validation Conclusion

The application artifact builds cleanly and passes unit tests, but **fails operational readiness validation** due to missing backing service configurations, silent fallback mechanisms, and false-positive health check reporting. Deployment to production in its current state is blocked pending remediation.
