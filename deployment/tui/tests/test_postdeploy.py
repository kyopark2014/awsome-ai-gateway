import json

from deployment.tui import postdeploy as pd


def _fake_ingress_json(items):
    # items: list of (name, hostname_or_None)
    return json.dumps({
        "items": [
            {
                "metadata": {"name": name},
                "status": {"loadBalancer": {"ingress": ([{"hostname": h}] if h else [])}},
            }
            for name, h in items
        ]
    })


def test_endpoint_url_builds_http_when_hostname_present():
    ep = pd.Endpoint(role="gateway", ingress_name="llm-gateway-gateway", hostname="abc.elb.amazonaws.com")
    assert ep.url == "http://abc.elb.amazonaws.com"


def test_endpoint_url_none_when_hostname_missing():
    ep = pd.Endpoint(role="gateway", ingress_name="llm-gateway-gateway", hostname=None)
    assert ep.url is None


def test_endpoints_by_role_finds_and_misses():
    eps = pd.Endpoints(items=[pd.Endpoint("admin-ui", "llm-gateway-admin-ui", "h")])
    assert eps.by_role("admin-ui").hostname == "h"
    assert eps.by_role("gateway") is None


def test_isolated_kubeconfig_follows_tmp_rule():
    assert pd.isolated_kubeconfig("llm-gateway") == "/tmp/llm-gateway.kubeconfig"
    assert pd.isolated_kubeconfig("other") == "/tmp/other.kubeconfig"


def test_role_maps_cover_three_roles():
    assert set(pd.ROLE_SUFFIX) == {"gateway", "admin-api", "admin-ui"}
    assert pd.HEALTH_PATH["admin-ui"] == "/"
    assert pd.HEALTH_PATH["gateway"] == "/health"


def test_discover_endpoints_parses_three(monkeypatch):
    payload = _fake_ingress_json([
        ("llm-gateway-gateway", "g.elb.amazonaws.com"),
        ("llm-gateway-admin-api", "a.elb.amazonaws.com"),
        ("llm-gateway-admin-ui", "u.elb.amazonaws.com"),
    ])
    monkeypatch.setattr(pd, "_run_kubectl", lambda args, cluster_name: (0, payload))
    eps = pd.discover_endpoints()
    assert eps.error is None
    assert eps.by_role("gateway").url == "http://g.elb.amazonaws.com"
    assert eps.by_role("admin-ui").hostname == "u.elb.amazonaws.com"


def test_discover_endpoints_hostname_pending_is_none(monkeypatch):
    payload = _fake_ingress_json([("llm-gateway-gateway", None)])
    monkeypatch.setattr(pd, "_run_kubectl", lambda args, cluster_name: (0, payload))
    eps = pd.discover_endpoints()
    assert eps.by_role("gateway").hostname is None
    assert eps.by_role("gateway").url is None


def test_discover_endpoints_kubectl_failure_sets_error(monkeypatch):
    monkeypatch.setattr(pd, "_run_kubectl", lambda args, cluster_name: (1, "error: cluster unreachable"))
    eps = pd.discover_endpoints()
    assert eps.items == []
    assert eps.error is not None


def test_discover_endpoints_bad_json_sets_error(monkeypatch):
    monkeypatch.setattr(pd, "_run_kubectl", lambda args, cluster_name: (0, "not json"))
    eps = pd.discover_endpoints()
    assert eps.error is not None


def _pods_json(states):
    # states: list of (phase, ready_bool)
    return json.dumps({
        "items": [
            {
                "status": {
                    "phase": phase,
                    "containerStatuses": [{"ready": ready}],
                }
            }
            for phase, ready in states
        ]
    })


def test_pod_health_counts_ready(monkeypatch):
    monkeypatch.setattr(pd, "_run_kubectl",
                        lambda args, cluster_name: (0, _pods_json([("Running", True)] * 6)))
    res = pd._pod_health("llm-gateway", "llm-gateway")
    assert res.state == "ok"
    assert "6" in res.detail


def test_pod_health_pending_when_not_all_ready(monkeypatch):
    monkeypatch.setattr(pd, "_run_kubectl",
                        lambda args, cluster_name: (0, _pods_json([("Running", True), ("Pending", False)])))
    res = pd._pod_health("llm-gateway", "llm-gateway")
    assert res.state == "pending"


def test_pod_health_check_on_kubectl_error(monkeypatch):
    monkeypatch.setattr(pd, "_run_kubectl", lambda args, cluster_name: (1, "boom"))
    res = pd._pod_health("llm-gateway", "llm-gateway")
    assert res.state == "check"


def test_live_healthcheck_maps_curl_status(monkeypatch):
    eps = pd.Endpoints(items=[
        pd.Endpoint("gateway", "llm-gateway-gateway", "g"),
        pd.Endpoint("admin-api", "llm-gateway-admin-api", "a"),
        pd.Endpoint("admin-ui", "llm-gateway-admin-ui", "u"),
    ])
    monkeypatch.setattr(pd, "_pod_health",
                        lambda c, n: pd.HealthResult("pods", "ok", "6/6"))
    status = {"http://g/health": 200, "http://a/health": 200, "http://u/": 307}
    monkeypatch.setattr(pd, "_curl_status", lambda url: status.get(url))
    results = pd.live_healthcheck(eps)
    # 1 pod row + 3 endpoint rows
    states = {r.label: r.state for r in results}
    # pod row + 3 endpoints; 200/200/307 all map to ok
    assert states == {"pods": "ok", "gateway": "ok", "admin-api": "ok", "admin-ui": "ok"}
    assert len(results) == 4


def test_live_healthcheck_pending_on_connection_failure(monkeypatch):
    eps = pd.Endpoints(items=[pd.Endpoint("gateway", "llm-gateway-gateway", "g")])
    monkeypatch.setattr(pd, "_pod_health", lambda c, n: pd.HealthResult("pods", "ok", ""))
    monkeypatch.setattr(pd, "_curl_status", lambda url: None)  # refused/timeout
    results = pd.live_healthcheck(eps)
    gw = next(r for r in results if r.label != "pods")
    assert gw.state == "pending"


def test_live_healthcheck_pending_when_hostname_missing(monkeypatch):
    eps = pd.Endpoints(items=[pd.Endpoint("gateway", "llm-gateway-gateway", None)])
    monkeypatch.setattr(pd, "_pod_health", lambda c, n: pd.HealthResult("pods", "ok", ""))
    # hostname None → curl 호출 안 함. 호출되면 실패시키기 위해 예외 던지는 스텁.
    def boom(url):
        raise AssertionError("curl should not be called for missing hostname")
    monkeypatch.setattr(pd, "_curl_status", boom)
    results = pd.live_healthcheck(eps)
    gw = next(r for r in results if r.label != "pods")
    assert gw.state == "pending"
