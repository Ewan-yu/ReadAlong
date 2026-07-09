# -*- coding: utf-8 -*-
"""ReadAlong 家长端入口：FastAPI + 本地 Web 前端。

启动：
    uvicorn app.main:app --port 8760
或直接：
    python -m app.main   （启动后自动打开浏览器）
"""
import webbrowser
from pathlib import Path

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

app = FastAPI(title="ReadAlong Parent Tool", version="0.1.0")


@app.get("/api/health")
def health():
    return {"status": "ok", "version": "0.1.0"}


# 本地 Web 前端构建产物（M3 里程碑填充）
_web_dist = Path(__file__).parent.parent / "web" / "dist"
if _web_dist.exists():
    app.mount("/", StaticFiles(directory=_web_dist, html=True), name="web")


def run():
    import uvicorn

    webbrowser.open("http://127.0.0.1:8760")
    uvicorn.run(app, host="127.0.0.1", port=8760)


if __name__ == "__main__":
    run()
