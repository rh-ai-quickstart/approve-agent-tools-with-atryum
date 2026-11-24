"""Restore the demo agent query parameter on requests from the MCP Gateway."""

import json
from contextlib import asynccontextmanager
from pathlib import Path

import httpx
from fastapi import FastAPI, Request
from starlette.background import BackgroundTask
from starlette.responses import Response, StreamingResponse


SEED = json.loads(Path(__file__).with_name("seed.json").read_text())
AGENTS = {
    server: {
        agent_id
        for agent in SEED["agents"]
        if server in agent["tags"]
        for agent_id in agent["agent_ids"]
    }
    for server in ("finance", "gdpr")
}
DISCOVERY_METHODS = ("initialize", "notifications/initialized", "tools/list")
REQUEST_HEADERS = {
    "accept", "content-type", "mcp-protocol-version", "mcp-session-id",
    "traceparent", "tracestate",
}
RESPONSE_HEADERS = {"content-type", "mcp-session-id", "mcp-protocol-version"}


@asynccontextmanager
async def lifespan(app):
    async with httpx.AsyncClient(
        timeout=httpx.Timeout(600, connect=5), trust_env=False
    ) as client:
        app.state.client = client
        yield


app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)


@app.get("/healthz")
async def healthy():
    return Response(status_code=204)


@app.api_route("/mcp/{server}", methods=["GET", "POST", "DELETE"])
async def forward(server: str, request: Request):
    if server not in AGENTS:
        return Response(status_code=404)

    agent_ids = request.headers.getlist("x-atryum-demo-agent")
    if agent_ids and (len(agent_ids) != 1 or agent_ids[0] not in AGENTS[server]):
        return Response("Invalid demo agent for this server", status_code=403)

    body = await request.body()
    if not agent_ids:
        # The broker has no agent identity when discovering upstream tools.
        # Allow its handshake and tool list, but require identity for calls.
        if request.method != "POST":
            return Response(status_code=405)
        try:
            message = json.loads(body)
        except ValueError:
            return Response(status_code=400)
        if isinstance(message, dict) and message.get("method") == "ping" and "id" in message:
            # The broker pings even though Atryum's proxy is stateless and
            # does not expose a ping handler. The pod probe covers readiness.
            return Response(
                json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": {}}),
                media_type="application/json",
            )
        if not isinstance(message, dict) or message.get("method") not in DISCOVERY_METHODS:
            return Response("Demo agent identity required", status_code=403)

    client = request.app.state.client
    upstream = client.build_request(
        request.method,
        f"http://127.0.0.1:8080/mcp/{server}",
        params={"agent_id": agent_ids[0]} if agent_ids else None,
        headers={key: value for key, value in request.headers.items() if key in REQUEST_HEADERS},
        content=body,
    )
    try:
        result = await client.send(upstream, stream=True)
    except httpx.RequestError:
        return Response("Atryum MCP endpoint unavailable", status_code=502)

    return StreamingResponse(
        result.aiter_bytes(),
        status_code=result.status_code,
        headers={key: value for key, value in result.headers.items() if key in RESPONSE_HEADERS},
        background=BackgroundTask(result.aclose),
    )
