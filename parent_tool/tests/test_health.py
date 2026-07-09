# -*- coding: utf-8 -*-
"""M0.3 骨架冒烟测试：FastAPI 起服务返回 hello/health。"""
from fastapi.testclient import TestClient

from app.main import app


def test_health():
    client = TestClient(app)
    r = client.get("/api/health")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok"
