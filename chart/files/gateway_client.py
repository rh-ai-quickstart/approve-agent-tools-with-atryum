"""Run the published Finance Demo dashboard against a federated MCP endpoint."""

import os
import sys
from urllib.parse import parse_qs, urlsplit, urlunsplit

# The dashboard and its dependencies come from the pinned demo image.
sys.path.insert(0, "/app")
import app as dashboard
import uvicorn
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client


AGENT_PREFIXES = {
    agent["atryum_id"]: f"{server}_"
    for server, demo in dashboard.DEMOS.items()
    for agent in demo["agents"].values()
}


def gateway_client(url):
    parts = urlsplit(url)
    identities = parse_qs(parts.query).get("agent_id", [])
    if len(identities) != 1 or identities[0] not in AGENT_PREFIXES:
        raise ValueError("MCP connection requires a known demo agent")
    endpoint = urlunsplit(parts._replace(query="", fragment=""))
    return streamablehttp_client(
        endpoint, headers={"X-Atryum-Demo-Agent": identities[0]}
    )


class GatewaySession(ClientSession):
    def __init__(self, *args, client_info, **kwargs):
        super().__init__(*args, client_info=client_info, **kwargs)
        self.prefix = AGENT_PREFIXES[client_info.name]

    async def list_tools(self):
        # The existing dashboard expects the original tool names for its
        # prompts and UI. Keep its finance and GDPR tool sets separate.
        cursor = None
        tools = []
        while True:
            result = await super().list_tools(cursor=cursor)
            tools.extend(
                tool.model_copy(update={"name": tool.name[len(self.prefix):]})
                for tool in result.tools
                if tool.name.startswith(self.prefix)
            )
            cursor = result.nextCursor
            if not cursor:
                break
        if not tools:
            raise RuntimeError(f"No tools registered under gateway prefix {self.prefix}")
        return result.model_copy(update={"tools": tools})

    async def call_tool(self, name, *args, **kwargs):
        return await super().call_tool(self.prefix + name, *args, **kwargs)


if __name__ == "__main__":
    dashboard.streamablehttp_client = gateway_client
    dashboard.ClientSession = GatewaySession
    uvicorn.run(dashboard.app, host="0.0.0.0", port=int(os.getenv("APP_PORT", "8000")))
