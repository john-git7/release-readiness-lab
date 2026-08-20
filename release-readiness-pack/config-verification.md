# Configuration & Environment Verification Report

**Service:** Checkout API (`checkout-api`)  
**Release Candidate:** `v2.4`  
**Evaluation Date:** 2026-08-20  
**Evaluator:** Release Engineering & SRE Team  

---

## 1. Overview & Objective

This document verifies the configuration parameters required by the **Checkout API v2.4** across the application runtime, architectural specification (`docs/architecture.md`), and Kubernetes manifests (`k8s/configmap.yaml`, `k8s/deployment.yaml`).

Operational readiness requires that:
1. All environment variables required by the runtime are explicitly declared.
2. Sensitive connection credentials (database passwords, tokens) are isolated in Kubernetes `Secrets` rather than plain-text `ConfigMaps`.
3. Fallback behaviors for missing variables are safe, predictable, and fail closed in production rather than silently corrupting state.

---

## 2. Configuration Audit Matrix

| Variable Name | Required? | Defined in Architecture Docs? | Implemented in `app/app.py`? | Present in `k8s/configmap.yaml`? | Security Classification | Compliance Status |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| `PORT` | Optional (Default: `5000`) | Yes (`PORT`) | Yes (line 60, default `5000`) | Yes (`PORT: "5000"`) | Non-sensitive | ✅ **COMPLIANT** |
| `LOG_LEVEL` | Optional (Default: `INFO`) | Yes (`LOG_LEVEL`) | Yes (line 9, default `INFO`) | Yes (`LOG_LEVEL: "info"`) | Non-sensitive | ✅ **COMPLIANT** |
| `DATABASE_URL` | **MANDATORY** for Prod | Yes (PostgreSQL connection string) | Yes (line 27, triggers fallback) | ❌ **MISSING** | **SENSITIVE (Secret)** | ❌ **NON-COMPLIANT (CRITICAL)** |
| `REDIS_URL` | **MANDATORY** for Prod | Yes (Redis connection string) | Yes (line 28, triggers fallback) | ❌ **MISSING** | **SENSITIVE (Secret)** | ❌ **NON-COMPLIANT (CRITICAL)** |

---

## 3. Detailed Gap Analysis

### 3.1 Gap 1: Missing Backing Service Connection Strings
In `k8s/configmap.yaml`, the developers explicitly left a note acknowledging the omission:
```yaml
# Note: Developers forgot to include DATABASE_URL and REDIS_URL here.
# This causes the application to default to volatile, in-memory SQLite and local cache.
```
- **Operational Impact:** When pods start in Kubernetes, neither `DATABASE_URL` nor `REDIS_URL` are injected.
- **Consequence:** The 3 replicas operate as 3 independent islands with non-shared SQLite databases and in-memory dict caches. Customer cart items and checkout transactions are lost or fragmented.

### 3.2 Gap 2: Inappropriate Storage Strategy for Sensitive Credentials
Even if `DATABASE_URL` and `REDIS_URL` were placed into `k8s/configmap.yaml`, doing so violates security best practices:
- Connection strings contain authentication credentials (username, password).
- `ConfigMap` data is stored unencrypted and easily readable by anyone with read-only namespace access.
- **Remediation:** Secrets must be stored in a Kubernetes `Secret` (or injected via Vault / AWS Secrets Manager / External Secrets Operator) and mounted via `secretKeyRef`.

### 3.3 Gap 3: Silent Fallback Masking Failure
In `app/app.py`:
```python
if db_url:
    db_status = "connected"
    logger.info("Database status: CONNECTED")
else:
    db_status = "warning_fallback_sqlite"
    logger.warning("DATABASE_URL is not set! Using unstable, volatile in-memory SQLite fallback.")

status_code = 200
```
- **Operational Impact:** The application logs a warning but responds with `status_code = 200` and `"status": "healthy"`.
- **Consequence:** Kubernetes `readinessProbe` queries `/health`, receives `200 OK`, marks the pod as `Ready`, and immediately routes production customer traffic to an unconfigured, volatile instance.

---

## 4. Target Remediation Manifests

To achieve production readiness, the following configuration architecture must be deployed.

### 4.1 Remediation: Non-sensitive Configuration (`k8s/configmap.yaml`)
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: checkout-api-config
  namespace: checkout-system
data:
  PORT: "5000"
  LOG_LEVEL: "INFO"
```

### 4.2 Remediation: Sensitive Credentials Secret (`k8s/secret.yaml`)
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: checkout-api-secrets
  namespace: checkout-system
type: Opaque
stringData:
  DATABASE_URL: "postgresql://checkout_svc:P@ssw0rd_Encrypted@postgres-cluster.internal.svc:5432/checkout_db"
  REDIS_URL: "redis://:Redis_Encrypted_Auth_Token@redis-cluster.internal.svc:6379/0"
```

### 4.3 Remediation: Deployment Env Bindings (`k8s/deployment.yaml`)
```yaml
        envFrom:
        - configMapRef:
            name: checkout-api-config
        - secretRef:
            name: checkout-api-secrets
```

### 4.4 Remediation: Fail-Closed Health Check Logic (`app/app.py`)
```python
@app.route("/health", methods=["GET"])
def health():
    db_url = os.getenv("DATABASE_URL")
    redis_url = os.getenv("REDIS_URL")
    
    healthy = True
    db_status = "connected" if db_url else "missing_configuration"
    redis_status = "connected" if redis_url else "missing_configuration"
    
    if not db_url or not redis_url:
        healthy = False
        status_code = 503  # Service Unavailable to trip readiness probe
    else:
        status_code = 200
        
    return jsonify({
        "status": "healthy" if healthy else "unhealthy",
        "version": VERSION,
        "checks": {
            "database": db_status,
            "redis": redis_status
        }
    }), status_code
```

---

## 5. Verification Sign-Off Criteria

Before promoting release candidate `v2.4` to production:
1. `checkout-api-secrets` must be deployed and verified in target namespace.
2. Pod startup logs must confirm `Database status: CONNECTED` and `Redis cache status: CONNECTED`.
3. Health check must be updated to return `503` if environment variables are omitted.
