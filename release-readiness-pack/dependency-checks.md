# Dependency Audit & Supply Chain Security Report

**Target Release:** Checkout API `v2.4`  
**Evaluation Date:** 2026-08-20  
**Evaluator:** Release Engineering & SRE Team  

---

## 1. Executive Summary

This report provides a comprehensive audit of the dependencies declared in `app/requirements.txt`, evaluated against the target architecture specification (`docs/architecture.md`), container build manifests (`app/Dockerfile`), and modern supply chain security standards.

| Check Category | Status | Assessment Summary |
| :--- | :---: | :--- |
| **Top-Level Version Pinning** | ✅ PASS | Explicit versions are pinned with `==` for direct dependencies |
| **Architecture Specification Alignment** | ⚠️ WARN | Framework and server versions match `docs/architecture.md`, but DB/Cache drivers are missing |
| **Transitive Dependency Pinning** | ❌ FAIL | Sub-dependencies (Werkzeug, Jinja2, Click, etc.) are unpinned, leading to non-deterministic builds |
| **Environment Separation (Prod vs Dev)** | ❌ FAIL | Test framework (`pytest==8.0.2`) is included in production container image |
| **Missing Driver Dependencies** | ❌ FAIL | Production database (`psycopg2`/`asyncpg`) and cache (`redis`) client drivers are absent |
| **Container Base Image Pinning** | ⚠️ WARN | Base image `python:3.11-slim` uses floating tag rather than cryptographic digest hash |

---

## 2. Direct Dependency Inventory & Architecture Reconciliation

The declared dependencies in `app/requirements.txt` were audited against `docs/architecture.md`:

```text
# app/requirements.txt
Flask==3.0.2
gunicorn==22.0.0
pytest==8.0.2
```

### 2.1 Alignment Matrix

| Package | Declared Version | Architecture Spec (`docs/architecture.md`) | Role / Purpose | Production Required? | Audit Finding |
| :--- | :--- | :--- | :--- | :---: | :--- |
| `Flask` | `3.0.2` | Flask 3.0.2 | Core Web Framework / Routing | Yes | ✅ Aligned |
| `gunicorn` | `22.0.0` | Gunicorn 22.0.0 | WSGI Production Application Server | Yes | ✅ Aligned |
| `pytest` | `8.0.2` | N/A (Test tool) | Automated Unit Testing Framework | **NO** | ❌ **Violation:** Dev tool included in Prod bundle |
| `psycopg2-binary` | *Not listed* | PostgreSQL (via `DATABASE_URL`) | PostgreSQL Driver | **YES** | ❌ **Missing:** Required for PostgreSQL connectivity |
| `redis` | *Not listed* | Redis (via `REDIS_URL`) | Redis Client Library | **YES** | ❌ **Missing:** Required for Redis cache connectivity |

---

## 3. Transitive Dependency & Deterministic Build Analysis

While top-level packages specify exact versions, their sub-dependencies are currently resolved dynamically at build time during `docker build`:

### 3.1 Unpinned Transitive Dependency Tree

```
checkout-api (v2.4)
├── Flask==3.0.2
│   ├── Werkzeug >= 3.0.0
│   ├── Jinja2 >= 3.1.2
│   ├── itsdangerous >= 2.1.2
│   ├── click >= 8.1.3
│   └── blinker >= 1.6.2
├── gunicorn==22.0.0
│   └── packaging
└── pytest==8.0.2 (Test only)
    ├── iniconfig
    ├── packaging
    ├── pluggy >= 1.4.0
    └── colorama / pygments
```

### 3.2 Risk of Non-Deterministic Builds
Without a pinned lockfile (`requirements.lock` or compiled hashes via `pip-compile` / `uv.lock`), consecutive Docker builds on different days or runners may download newer minor/patch versions of `Werkzeug` or `Jinja2`. This risks silent behavioral regressions or breaking changes in production.

---

## 4. Container Base Image & Packaging Security

### 4.1 Base Image Analysis
`app/Dockerfile` declares:
```dockerfile
FROM python:3.11-slim
```
- **Finding:** `python:3.11-slim` is a moving tag that updates whenever Debian/Python upstream releases updates.
- **Remediation:** Pin to an immutable SHA256 digest (e.g., `python:3.11.9-slim-bookworm@sha256:abcd...`) to guarantee reproducible, tamper-proof builds.

### 4.2 Multi-Stage Build & Non-Root Execution
The current Dockerfile installs packages directly as `root` and executes the server as `root` user without a dedicated system user.

---

## 5. Recommended Production Dependency Structure

### 5.1 Production Requirements (`app/requirements.txt`)
```text
# Core Framework & Server
Flask==3.0.2
gunicorn==22.0.0

# Database & Cache Connectors
psycopg2-binary==2.9.9
redis==5.0.8

# Pinned Transitive Dependencies (Deterministic Lock)
blinker==1.7.0
click==8.1.7
itsdangerous==2.1.2
Jinja2==3.1.3
MarkupSafe==2.1.5
packaging==24.0
Werkzeug==3.0.1
```

### 5.2 Development & Test Requirements (`app/requirements-dev.txt`)
```text
-r requirements.txt
pytest==8.0.2
pytest-cov==4.1.0
flake8==7.0.0
black==24.2.0
```

### 5.3 Hardened Multi-Stage Dockerfile (`app/Dockerfile`)
```dockerfile
# Build stage
FROM python:3.11-slim AS builder
WORKDIR /install
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# Final runtime stage
FROM python:3.11-slim
WORKDIR /app

# Create non-root runtime user
RUN groupadd -r appgroup && useradd -r -g appgroup appuser

COPY --from=builder /install /usr/local
COPY app.py .

USER appuser
EXPOSE 5000

CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "3", "--access-logfile", "-", "app:app"]
```

---

## 6. Audit Conclusion

The dependency checks reveal that while direct version numbers match the architectural specification, the dependency management strategy requires hardening. The inclusion of `pytest` in production, lack of database drivers, and unpinned transitive dependencies represent operational liabilities that must be resolved prior to release sign-off.
