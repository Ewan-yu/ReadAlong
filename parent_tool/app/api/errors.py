from __future__ import annotations

from uuid import uuid4

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from app.models.errors import ApiErrorResponse, PipelineError


def install_error_handlers(app: FastAPI) -> None:
    @app.middleware("http")
    async def attach_request_id(request: Request, call_next):
        request.state.request_id = request.headers.get("x-request-id") or str(uuid4())
        response = await call_next(request)
        response.headers["x-request-id"] = request.state.request_id
        return response

    @app.exception_handler(PipelineError)
    async def handle_pipeline_error(request: Request, exc: PipelineError) -> JSONResponse:
        body = ApiErrorResponse(
            code=exc.code,
            message=exc.message,
            details=exc.details,
            request_id=request.state.request_id,
        )
        return JSONResponse(status_code=exc.status_code, content=body.model_dump(mode="json"))

    @app.exception_handler(RequestValidationError)
    async def handle_request_validation(
        request: Request, exc: RequestValidationError
    ) -> JSONResponse:
        body = ApiErrorResponse(
            code="INVALID_STEP_PARAMS",
            message="请求参数不合法。",
            details={"errors": exc.errors()},
            request_id=request.state.request_id,
        )
        return JSONResponse(status_code=422, content=body.model_dump(mode="json"))
