# Copyright 2026 © Amazon.com and Affiliates: This deliverable is considered Developed Content as defined in the AWS Service Terms.
"""배포 후 검증 — 엔드포인트 조회/헬스체크 순수 로직.

kubectl/curl 을 subprocess 로 호출하되 예외를 던지지 않는다(실패는 결과값으로
표현). rich 를 import 하지 않는다 — 렌더링은 cli.py 전담."""
from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass, field

# role↔ingress 이름 suffix 매핑. helm 차트 구조에서 오는 규칙이라 상수.
# 이름 전체를 박지 않고 라벨 셀렉터로 받은 뒤 suffix 로 role 을 역매핑한다.
ROLE_SUFFIX = {"gateway": "gateway", "admin-api": "admin-api", "admin-ui": "admin-ui"}
# 헬스체크 경로: gateway/admin-api 는 /health, admin-ui(Next.js)는 루트로 307 확인.
HEALTH_PATH = {"gateway": "/health", "admin-api": "/health", "admin-ui": "/"}

ORDER = ("gateway", "admin-api", "admin-ui")


@dataclass
class Endpoint:
    role: str
    ingress_name: str
    hostname: str | None

    @property
    def url(self) -> str | None:
        return f"http://{self.hostname}" if self.hostname else None


@dataclass
class Endpoints:
    items: list[Endpoint] = field(default_factory=list)
    error: str | None = None

    def by_role(self, role: str) -> Endpoint | None:
        return next((e for e in self.items if e.role == role), None)


@dataclass
class HealthResult:
    label: str
    state: str  # "ok" | "pending" | "check"
    detail: str


def isolated_kubeconfig(cluster_name: str = "llm-gateway") -> str:
    """steps.py 와 동일한 격리 KUBECONFIG 경로 규칙."""
    return f"/tmp/{cluster_name}.kubeconfig"


def _run_kubectl(args: list[str], cluster_name: str) -> tuple[int, str]:
    """격리 KUBECONFIG 로 kubectl 실행. (returncode, stdout+stderr) 반환.
    예외를 던지지 않는다 — 미설치/타임아웃도 (비정상코드, 메시지)로."""
    env = dict(os.environ)
    env["KUBECONFIG"] = isolated_kubeconfig(cluster_name)
    try:
        proc = subprocess.run(
            ["kubectl", *args],
            capture_output=True, text=True, env=env, timeout=15,
        )
    except FileNotFoundError:
        return 127, "kubectl not found"
    except subprocess.TimeoutExpired:
        return 124, "kubectl timed out"
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def _role_for(name: str) -> str | None:
    """ingress 이름 suffix 로 role 역매핑. 긴 suffix 우선(admin-api/admin-ui가
    gateway보다 먼저 매칭되도록 정렬)."""
    for role in sorted(ROLE_SUFFIX, key=lambda r: -len(ROLE_SUFFIX[r])):
        if name.endswith(ROLE_SUFFIX[role]):
            return role
    return None


def discover_endpoints(cluster_name: str = "llm-gateway",
                       release: str = "llm-gateway",
                       namespace: str = "llm-gateway") -> Endpoints:
    """라벨 셀렉터로 ingress 3개를 조회해 role/hostname 매핑. 실패해도 예외 없이
    Endpoints(error=...) 반환."""
    rc, out = _run_kubectl(
        ["get", "ingress", "-n", namespace,
         "-l", f"app.kubernetes.io/instance={release}", "-o", "json"],
        cluster_name,
    )
    if rc != 0:
        return Endpoints(items=[], error=out.strip() or f"kubectl exit {rc}")
    try:
        data = json.loads(out)
    except (ValueError, TypeError):
        return Endpoints(items=[], error="kubectl 출력 파싱 실패 (JSON 아님)")

    by_role: dict[str, Endpoint] = {}
    for item in data.get("items", []):
        name = item.get("metadata", {}).get("name", "")
        role = _role_for(name)
        if role is None:
            continue
        ing = item.get("status", {}).get("loadBalancer", {}).get("ingress", [])
        hostname = ing[0].get("hostname") if ing else None
        by_role[role] = Endpoint(role=role, ingress_name=name, hostname=hostname)

    items = [by_role[r] for r in ORDER if r in by_role]
    return Endpoints(items=items)


def _pod_health(cluster_name: str, namespace: str) -> HealthResult:
    rc, out = _run_kubectl(["get", "pods", "-n", namespace, "-o", "json"], cluster_name)
    if rc != 0:
        return HealthResult(label="pods", state="check", detail=out.strip()[:60] or "kubectl 실패")
    try:
        items = json.loads(out).get("items", [])
    except (ValueError, TypeError):
        return HealthResult(label="pods", state="check", detail="pod 목록 파싱 실패")
    total = len(items)
    ready = 0
    for p in items:
        st = p.get("status", {})
        cs = st.get("containerStatuses", []) or []
        if st.get("phase") == "Running" and cs and all(c.get("ready") for c in cs):
            ready += 1
    state = "ok" if total > 0 and ready == total else "pending"
    return HealthResult(label="pods", state=state, detail=f"{ready}/{total} Ready")


def _curl_status(url: str) -> int | None:
    """HTTP 상태코드 반환. 연결실패/타임아웃/미설치는 None."""
    try:
        proc = subprocess.run(
            ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
             "--max-time", "10", url],
            capture_output=True, text=True, timeout=15,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    code = proc.stdout.strip()
    return int(code) if code.isdigit() and code != "000" else None


def live_healthcheck(endpoints: Endpoints, cluster_name: str = "llm-gateway",
                     namespace: str = "llm-gateway") -> list[HealthResult]:
    results = [_pod_health(cluster_name, namespace)]
    for ep in endpoints.items:
        if ep.hostname is None:
            results.append(HealthResult(label=ep.role, state="pending", detail="ALB 프로비저닝 중"))
            continue
        path = HEALTH_PATH.get(ep.role, "/")
        code = _curl_status(f"{ep.url}{path}")
        if code is None:
            results.append(HealthResult(label=ep.role, state="pending", detail="연결 안 됨 (준비 중)"))
        elif 200 <= code < 400:
            results.append(HealthResult(label=ep.role, state="ok", detail=f"HTTP {code}"))
        else:
            results.append(HealthResult(label=ep.role, state="check", detail=f"HTTP {code}"))
    return results
