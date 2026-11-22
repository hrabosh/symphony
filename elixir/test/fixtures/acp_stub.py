import json
import sys
from pathlib import Path


def send(message):
    print(json.dumps({"jsonrpc": "2.0", **message}), flush=True)


def result(request, data):
    send({"id": request["id"], "result": data})


mode = sys.argv[1]
pending = None
for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    params = request.get("params", {})
    if method == "initialize":
        assert params["protocolVersion"] == 1 and not params.get("clientCapabilities", {}).get("fs")
        assert params["clientCapabilities"]["elicitation"]["form"] == {}
        result(request, {"protocolVersion": 1})
    elif method == "session/new":
        assert Path(params["cwd"]).resolve() == Path.cwd()
        assert params["mcpServers"] == []
        if mode == "auth":
            send({"id": request["id"], "error": {"code": -32000, "message": "Authentication required"}})
        else:
            result(request, {"sessionId": "stub-session"})
    elif method == "session/prompt":
        assert params["sessionId"] == "stub-session"
        assert params["prompt"][0]["type"] == "text"
        pending = request
        send({"method": "session/update", "params": {"sessionId": "stub-session",
             "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Working"}}}})
        if mode == "complete":
            result(request, {"stopReason": "end_turn"})
        elif mode == "crash":
            sys.exit(7)
        elif mode == "permission":
            send({"id": "permission-1", "method": "session/request_permission",
                  "params": {"sessionId": "stub-session", "options": [
                      {"optionId": "always", "kind": "allow_always"},
                      {"optionId": "once", "kind": "allow_once"}]}})
        elif mode == "input":
            send({"id": "question-1", "method": "elicitation/create", "params": {
                "sessionId": "stub-session", "mode": "form", "message": "Which option?",
                "requestedSchema": {"type": "object", "properties": {}}}})
    elif method == "session/cancel":
        assert params["sessionId"] == "stub-session"
        if mode == "cancel-collision":
            send({"id": pending["id"], "method": "session/request_permission",
                  "params": {"sessionId": "stub-session", "options": []}})
        else:
            if len(sys.argv) > 2:
                Path(sys.argv[2]).write_text("cancelled")
            result(pending, {"stopReason": "cancelled"})
    elif mode == "cancel-collision" and request["id"] == pending["id"]:
        assert request["result"] == {"outcome": {"outcome": "cancelled"}}
        Path(sys.argv[2]).write_text("cancelled")
        result(pending, {"stopReason": "cancelled"})
    elif request["id"] == "permission-1":
        outcome = request["result"]["outcome"]
        if outcome == {"outcome": "selected", "optionId": "once"}:
            result(pending, {"stopReason": "end_turn"})
        else:
            assert outcome == {"outcome": "cancelled"}
    elif request["id"] == "question-1":
        assert request["result"] == {"action": "cancel"}
