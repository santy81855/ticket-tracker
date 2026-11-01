#!/usr/bin/env python3
"""Exercise the actual stdio helper using isolated stores, never real tickets."""
import json
import os
import selectors
import sqlite3
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path


class Client:
    def __init__(self, executable, directory):
        environment = dict(os.environ, TICKET_TRACKER_DATA_DIR=str(directory))
        self.process = subprocess.Popen(
            [str(executable), "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, env=environment, bufsize=0,
        )
        self.sequence = 0
        self.buffer = b""
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.request("initialize", {
            "protocolVersion": "2025-11-25", "capabilities": {},
            "clientInfo": {"name": "ticket-tracker-integration-tests", "version": "1"},
        })
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def send(self, payload):
        self.process.stdin.write(json.dumps(payload).encode() + b"\n")
        self.process.stdin.flush()

    def request(self, method, params):
        self.sequence += 1
        identifier = self.sequence
        self.send({"jsonrpc": "2.0", "id": identifier, "method": method, "params": params})
        return self.response(identifier)

    def response(self, identifier):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                if not line.strip():
                    continue
                message = json.loads(line)
                if message.get("id") == identifier:
                    assert "error" not in message, message
                    return message["result"]
            if self.selector.select(timeout=0.25):
                block = os.read(self.process.stdout.fileno(), 65536)
                if not block:
                    raise AssertionError("Helper exited: " + self.process.stderr.read().decode())
                self.buffer += block
        raise AssertionError("Timed out waiting for MCP response")

    def tool(self, name, arguments, error=False):
        result = self.request("tools/call", {"name": name, "arguments": arguments})
        assert bool(result.get("isError")) == error, result
        return json.loads(result["content"][0]["text"])

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=5)
        self.selector.close()
        self.process.stdout.close()
        self.process.stderr.close()


class CLIClient:
    operations = {
        "tracker_health": "health", "tracker_list_items": "list",
        "tracker_get_item": "get", "tracker_create_item": "create",
        "tracker_update_details": "update", "tracker_add_mr": "add-mr",
        "tracker_record_action": "record", "tracker_check_transition": "check",
        "tracker_set_completion_time": "set-completion-time",
        "tracker_get_message_draft": "draft",
        "tracker_workflow": "workflow",
    }

    def __init__(self, executable, directory):
        self.executable = executable
        self.environment = dict(os.environ, TICKET_TRACKER_DATA_DIR=str(directory))

    def tool(self, name, arguments, error=False):
        result = subprocess.run(
            [str(self.executable), self.operations[name], "--stdin"],
            input=json.dumps(arguments), text=True, capture_output=True,
            env=self.environment, timeout=15,
        )
        assert result.returncode == (1 if error else 0), (result.stdout, result.stderr)
        assert not (result.stdout if error else result.stderr), result
        return json.loads(result.stderr if error else result.stdout)


def mutate(client, context, action, note="User explicitly confirmed in the external system.", error=False):
    snapshot = context["snapshot"]
    token = snapshot["token"]
    return client.tool("tracker_record_action", {
        "item_id": snapshot["item"]["id"], "generation": token["generation"],
        "expected_revision": token["version"],
        "request_id": f"action-{time.monotonic_ns()}", "action_id": action, "note": note,
    }, error=error)


def edit(client, context, **fields):
    snapshot = context["snapshot"]
    return client.tool("tracker_update_details", {
        "item_id": snapshot["item"]["id"], "generation": snapshot["token"]["generation"],
        "expected_revision": snapshot["token"]["version"],
        "request_id": f"edit-{time.monotonic_ns()}", **fields,
    })


def ticket(client, key, qa):
    context = client.tool("tracker_create_item", {
        "kind": "ticket", "title": f"Integration test {key}",
        "jira": f"https://jira.example.test/browse/{key}",
        "qa": qa, "qa_reason": "User selected the test playbook.", "request_id": f"create-{key}",
    })
    context = edit(client, context, thread_url=f"https://teams.example.test/thread/{key}", testing_notes="Test current changes.")
    snapshot = context["snapshot"]
    return client.tool("tracker_add_mr", {
        "item_id": snapshot["item"]["id"], "generation": snapshot["token"]["generation"],
        "expected_revision": snapshot["token"]["version"], "request_id": f"mr-{key}",
        "url": f"https://gitlab.example.test/pod/app/-/merge_requests/{key.split('-')[-1]}",
    })


def approvals(client, context):
    for action in ["jiraStart", "kickoff", "implementation", "approvalRequest"]:
        steps = context["steps"]
        if next(step for step in steps if step["id"] == action)["state"] == "pending":
            context = mutate(client, context, action)
    for mr in context["snapshot"]["item"]["mergeRequests"]:
        context = mutate(client, context, f"approveMR:{mr['id']}")
    return context


def check_copilot_setup(executable, directory):
    home = Path(directory) / "copilot-home"
    home.mkdir()
    configuration = {"mcpServers": {"existing-server": {"command": "/usr/bin/true"}}}
    original_config = json.dumps(configuration).encode()
    original_instructions = b"Keep my existing workflow.\n"
    config_path = home / "mcp-config.json"
    instructions_path = home / "copilot-instructions.md"
    config_path.write_bytes(original_config)
    instructions_path.write_bytes(original_instructions)
    environment = dict(os.environ, COPILOT_HOME=str(home))
    subprocess.run([str(executable), "setup-copilot"], env=environment, check=True, capture_output=True, timeout=15)
    assert config_path.read_bytes() == original_config
    assert instructions_path.read_bytes() == original_instructions
    subprocess.run([str(executable), "setup-copilot", "--confirm"], env=environment, check=True, capture_output=True, timeout=15)
    updated = json.loads(config_path.read_bytes())
    assert updated["mcpServers"]["existing-server"] == configuration["mcpServers"]["existing-server"]
    assert updated["mcpServers"]["ticket-tracker"]["command"] == str(executable)
    assert instructions_path.read_bytes().startswith(original_instructions)
    backup = next((home / "ticket-tracker-setup-backups").iterdir())
    assert (backup / "mcp-config.json").read_bytes() == original_config
    assert (backup / "copilot-instructions.md").read_bytes() == original_instructions
    print("PASS: explicit Copilot setup, no-change preview, preservation and original-file backups")
    mcp_bytes = config_path.read_bytes()
    before_cli = instructions_path.read_bytes()
    preview = subprocess.run(
        [str(executable), "setup-copilot", "--mode", "cli"], env=environment,
        check=True, capture_output=True, timeout=15,
    )
    assert b"organization-permitted local Ticket Tracker CLI" in preview.stdout
    assert instructions_path.read_bytes() == before_cli
    subprocess.run(
        [str(executable), "setup-copilot", "--mode", "cli", "--confirm"],
        env=environment, check=True, capture_output=True, timeout=15,
    )
    assert config_path.read_bytes() == mcp_bytes
    cli_text = instructions_path.read_bytes()
    assert cli_text.startswith(original_instructions)
    assert b"organization-permitted local Ticket Tracker CLI" in cli_text
    assert cli_text.count(b"<!-- ticket-tracker:start -->") == 1
    print("PASS: CLI setup changes only scoped instructions, leaving MCP configuration byte-identical")


def check_cli(executable, directory):
    client = CLIClient(executable, Path(directory) / "cli-store")
    catalog = subprocess.run(
        [str(executable), "commands"], capture_output=True, text=True,
        check=True, env=client.environment, timeout=15,
    )
    assert {entry["command"] for entry in json.loads(catalog.stdout)} == set(client.operations.values())
    assert not Path(client.environment["TICKET_TRACKER_DATA_DIR"]).exists()
    assert client.tool("tracker_health", {})["ready"]
    argument_health = subprocess.run(
        [str(executable), "health", "--json", "{}"], capture_output=True, text=True,
        check=True, env=client.environment, timeout=15,
    )
    assert json.loads(argument_health.stdout)["ready"]
    for payload in ["[]", "{", "x" * 1_048_577]:
        invalid = subprocess.run(
            [str(executable), "create", "--stdin"], input=payload, text=True,
            capture_output=True, env=client.environment, timeout=15,
        )
        assert invalid.returncode != 0 and invalid.stderr and not invalid.stdout
    client.tool("tracker_list_items", {"limit": "many"}, error=True)
    client.tool("tracker_create_item", {
        "kind": "ticket", "title": "Unconfirmed QA skip",
        "jira": "https://jira.example.test/browse/CLI-9", "qa": "notRequired",
        "request_id": "unconfirmed-skip",
    }, error=True)
    print("PASS: standalone CLI discovery, stdin/argument JSON, input bounds and explicit failures")

    context = approvals(client, ticket(client, "CLI-201", "notRequired"))
    item_id = context["snapshot"]["item"]["id"]
    assert client.tool("tracker_get_item", {"item_id": "CLI-201"})["snapshot"]["item"]["id"] == item_id
    draft = client.tool("tracker_get_message_draft", {"item_id": item_id, "kind": "approvals"})
    assert draft
    assert client.tool("tracker_check_transition", {"item_id": item_id, "target": "merge"})["allowed"]
    mutate(client, context, "jiraDone", error=True)
    context = mutate(client, context, f"mergeMR:{context['snapshot']['item']['mergeRequests'][0]['id']}")
    context = mutate(client, context, "jiraDone")
    assert context["phase"] == "Done"
    print("PASS: CLI ticket creation, details/MRs/drafts, guarded no-QA progression and completion")

    with sqlite3.connect(Path(client.environment["TICKET_TRACKER_DATA_DIR"]) / "tracker.sqlite") as db:
        settings = {
            "jiraBaseURL": "", "gitlabHost": "", "teamsChannelURL": "", "pod": "", "qe": "",
            "jiraBoardURL": "https://jira.example.test/secure/RapidBoard.jspa?rapidView=42",
            "kickoffTemplate": "Starting implementation on {{ticket}}: {{title}}\n{{jira}}",
            "approvalTemplate": "{{pod}} - could you review {{ticket}}?\n{{mrs}}\n{{jira}}",
            "qaTemplate": "{{qe}} - {{ticket}} is ready for {{qa_action}}.\n{{mrs}}\n\nTesting notes:\n"
            "{{testing}}\nEnvironment: {{environment}}\n{{finding}}\n{{jira}}",
        }
        db.execute("INSERT OR REPLACE INTO settings (id, payload) VALUES (1, ?)", (json.dumps(settings).encode(),))
    qa = approvals(client, ticket(client, "CLI-202", "required"))
    assert qa["phase"] == "Ready for QA"
    assert "rapidView=42" in qa["jiraBoardURL"] and "selectedIssue=CLI-202" in qa["jiraBoardURL"]
    qa = mutate(client, qa, "jiraValidate")
    assert qa["phase"] == "Ready for QA handoff"
    qa = mutate(client, qa, "qaHandoff")
    qa = mutate(client, qa, "rework", note="QE requested a fix; keep the ticket in QA.")
    assert qa["phase"] == "QA · Fix requested"
    assert next(step for step in qa["steps"] if step["id"] == "jiraValidate")["state"] == "completed"
    qa = approvals(client, qa)
    qa = edit(client, qa, testing_notes="Retest the corrected behavior.")
    qa = mutate(client, qa, "retestHandoff")
    qa = mutate(client, qa, "qaPassed")
    qa = mutate(client, qa, "jiraReady")
    assert client.tool("tracker_check_transition", {
        "item_id": qa["snapshot"]["item"]["id"], "target": "merge",
    })["allowed"]

    snapshot = qa["snapshot"]
    common = {
        "item_id": snapshot["item"]["id"], "generation": snapshot["token"]["generation"],
        "expected_revision": snapshot["token"]["version"],
    }
    client.tool("tracker_record_action", {
        **common, "request_id": "no-bypass", "action_id": "jiraDone",
        "note": "Try to skip merging", "ignore_prerequisites": True,
    }, error=True)
    processes = []
    try:
        for index in range(2):
            process = subprocess.Popen(
                [str(executable), "update", "--stdin"], stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=client.environment,
            )
            processes.append(process)
            process.stdin.write(json.dumps({**common, "request_id": f"cli-race-{index}", "notes": f"writer {index}"}))
            process.stdin.close()
            process.stdin = None
        results = [(process.communicate(timeout=15), process.returncode) for process in processes]
        assert sorted(code for _, code in results) == [0, 1], results
        failure = next(output for output, code in results if code == 1)
        assert not failure[0] and json.loads(failure[1])["code"] == "conflict"
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
                process.communicate(timeout=5)
    print("PASS: CLI QA rework/retest stays in QA; concurrent CLI writers reject stale tokens")

    creation = {"kind": "task", "title": "Ask Jack", "request_id": "cli-task"}
    task = client.tool("tracker_create_item", creation)
    assert client.tool("tracker_create_item", creation)["snapshot"]["item"]["id"] == task["snapshot"]["item"]["id"]
    note = "Jack's update:\nKeep the literal text $(not-a-command) and `notes`."
    task = edit(client, task, notes=note, waiting_on="Jack", follow_up_at="2099-01-01T10:00:00Z")
    assert task["snapshot"]["item"]["notes"] == note
    assert any(item["id"] == task["snapshot"]["item"]["id"] for item in client.tool("tracker_list_items", {"view": "followups"})["items"])
    task = mutate(client, task, "taskDone", note="User confirmed the follow-up is complete.")
    assert task["phase"] == "Done"
    print("PASS: CLI task idempotency, literal work context, follow-up scheduling and completion")


def check_completion_time(client):
    context = approvals(client, ticket(client, "BACK-901", "notRequired"))
    mr = context["snapshot"]["item"]["mergeRequests"][0]
    context = mutate(client, context, f"mergeMR:{mr['id']}")
    context = mutate(client, context, "jiraDone")
    original = context["snapshot"]
    actual = (datetime.now(timezone.utc) - timedelta(days=7)).replace(microsecond=0)
    arguments = {
        "item_id": original["item"]["id"], "generation": original["token"]["generation"],
        "expected_revision": original["token"]["version"], "request_id": "completion-correction",
        "completed_at": actual.isoformat(), "evidence": "userConfirmed",
        "note": "User confirmed the final workflow obligation was completed a week ago.",
    }
    for fields in [
        {"completed_at": (datetime.now(timezone.utc) + timedelta(days=1)).isoformat()},
        {"completed_at": "yesterday"}, {"completed_at": 123}, {"note": " \n "},
        {"evidence": "assumed"}, {"ignore_prerequisites": True},
    ]:
        client.tool("tracker_set_completion_time", {
            **arguments, **fields, "request_id": f"invalid-{time.monotonic_ns()}",
        }, error=True)
    missing = {key: value for key, value in arguments.items() if key != "completed_at"}
    client.tool("tracker_set_completion_time", missing, error=True)
    assert client.tool("tracker_get_item", {"item_id": original["item"]["id"]})["snapshot"] == original
    corrected = client.tool("tracker_set_completion_time", arguments)
    assert client.tool("tracker_set_completion_time", arguments) == corrected
    client.tool("tracker_set_completion_time", {
        **arguments, "completed_at": (actual - timedelta(days=1)).isoformat(),
    }, error=True)
    stale = client.tool("tracker_set_completion_time", {
        **arguments, "request_id": "completion-stale",
    }, error=True)
    assert stale["code"] == "conflict"
    reread = client.tool("tracker_get_item", {"item_id": original["item"]["id"]})
    assert reread == corrected
    item = corrected["snapshot"]["item"]
    assert corrected["phase"] == "Done"
    assert datetime.fromisoformat(item["completedAt"].replace("Z", "+00:00")) == actual
    assert actual < datetime.fromisoformat(item["createdAt"].replace("Z", "+00:00"))
    assert item["actions"] == original["item"]["actions"]
    assert item["mergeRequests"] == original["item"]["mergeRequests"]
    assert len(item["history"]) == len(original["item"]["history"]) + 1
    entry = item["history"][-1]
    assert entry["source"] == "copilot" and entry["note"].endswith(arguments["note"])
    assert original["item"]["completedAt"] in entry["note"] and item["completedAt"] in entry["note"]
    active = ticket(client, "BACK-902", "notRequired")["snapshot"]
    client.tool("tracker_set_completion_time", {
        **arguments, "item_id": active["item"]["id"],
        "generation": active["token"]["generation"], "expected_revision": active["token"]["version"],
        "request_id": "completion-incomplete",
    }, error=True)
    assert client.tool("tracker_get_item", {"item_id": active["item"]["id"]})["snapshot"] == active
    print(f"PASS: {type(client).__name__} audited historical completion, persistence, retry/stale safety and invalid/incomplete rejection")


def check_workflow_cli(executable, directory):
    client = CLIClient(executable, Path(directory) / "workflow-store")

    def write(name, context, **fields):
        snapshot = context["snapshot"]
        return client.tool(name, {
            "item_id": snapshot["item"]["id"], "generation": snapshot["token"]["generation"],
            "expected_revision": snapshot["token"]["version"],
            "request_id": f"workflow-{time.monotonic_ns()}", **fields,
        })

    old = ticket(client, "OLD-801", "notRequired")
    catalog = client.tool("tracker_workflow", {"op": "list"})
    definition = client.tool("tracker_workflow", {"op": "get", "workflow_id": "developer-handoff"})
    definition["id"] = "integration-personal"
    definition["name"] = "Integration personal workflow"
    ready = next(step for step in definition["steps"] if step["kind"] == "jiraReady")
    assert ready["owner"] == "Me" and "mergeMR" in ready["dependsOn"]
    assert client.tool("tracker_workflow", {"op": "validate", "definition": definition})["valid"]
    publish = {
        "op": "publish", "definition": definition, "generation": catalog["generation"],
        "expected_revision": catalog["revision"], "request_id": "publish-personal",
        "reason": "User requested the developer-owned post-merge handoff", "make_default": True,
    }
    published = client.tool("tracker_workflow", publish)
    assert client.tool("tracker_workflow", publish) == published
    conflict = client.tool("tracker_workflow", {**publish, "request_id": "stale-catalog"}, error=True)
    assert conflict["code"] == "conflict"
    assert client.tool("tracker_get_item", {"item_id": old["snapshot"]["item"]["id"]})["snapshot"]["item"].get("workflow") is None
    preview = client.tool("tracker_workflow", {
        "op": "preview-adopt", "item_id": old["snapshot"]["item"]["id"],
        "workflow_id": definition["id"], "workflow_version": 1,
    })
    assert any("Still required" in line for line in preview)
    token = old["snapshot"]["token"]
    adopt = {
        "op": "adopt", "item_id": old["snapshot"]["item"]["id"], "workflow_id": definition["id"],
        "workflow_version": 1, "generation": token["generation"],
        "expected_revision": token["version"], "request_id": "adopt-old",
        "reason": "User explicitly requested the reviewed migration",
    }
    client.tool("tracker_workflow", adopt, error=True)
    old = client.tool("tracker_workflow", {**adopt, "confirm_migration": True})
    assert old["snapshot"]["item"]["workflow"]["id"] == definition["id"]
    context = ticket(client, "FLOW-701", "required")
    context = write("tracker_add_mr", context, url="https://gitlab.example.test/pod/service/-/merge_requests/702")
    context = approvals(client, context)
    before_round = context["snapshot"]["item"]["reviewRound"]
    context = write("tracker_add_mr", context, role="workspace",
                    url="https://gitlab.example.test/pod/workspace/-/merge_requests/703")
    assert context["snapshot"]["item"]["reviewRound"] == before_round
    for action in ["jiraValidate", "qaHandoff", "qaPassed"]:
        context = mutate(client, context, action)
    mutate(client, context, "jiraReady", error=True)
    for mr in [entry for entry in context["snapshot"]["item"]["mergeRequests"] if entry.get("classification", "ticket") == "ticket"]:
        context = write("tracker_record_action", context, action_id=f"mergeMR:{mr['id']}",
                        note="GitLab merge succeeded; actual merged_at verified.", evidence="performed",
                        occurred_at="2026-10-27T12:00:00Z")
    assert client.tool("tracker_get_message_draft", {
        "item_id": context["snapshot"]["item"]["id"], "action_id": "merged-notice",
    })["text"] == "merged"
    context = mutate(client, context, "merged-notice")
    context = edit(client, context, field_values={"fix-version": "2026.11.3"})
    context = mutate(client, context, "jiraReady")
    assert context["phase"] == "Development complete"
    completed_at = context["snapshot"]["item"]["completedAt"]
    item_id = context["snapshot"]["item"]["id"]
    assert any(item["id"] == item_id for item in client.tool("tracker_list_items", {"view": "workspaceUnmerged"})["items"])
    workspace = next(entry for entry in context["snapshot"]["item"]["mergeRequests"] if entry.get("classification") == "workspace")
    context = write("tracker_record_action", context, action_id=f"mergeMR:{workspace['id']}",
                    note="Verified later workspace merge", evidence="verified", occurred_at="2026-10-28T12:00:00Z")
    assert context["snapshot"]["item"]["completedAt"] == completed_at
    assert context["phase"] == "Development complete"
    assert any(item["id"] == item_id for item in client.tool("tracker_list_items", {"view": "workspaceMerged"})["items"])
    assert not any(item["id"] == item_id for item in client.tool("tracker_list_items", {"view": "workspaceUnmerged"})["items"])
    print("PASS: workflow CLI validation/publishing/retry/conflicts, explicit migration, actual merge dates, developer Fix Version/s handoff, merged message and optional post-completion workspace catch-up")


def check_schema_upgrade(executable, directory):
    path = Path(directory) / "schema-upgrade"
    client = CLIClient(executable, path)
    context = ticket(client, "OLD-900", "required")
    item_id = context["snapshot"]["item"]["id"]
    original_token = context["snapshot"]["token"]
    with sqlite3.connect(path / "tracker.sqlite") as db:
        db.execute("DROP TABLE workflow_catalog")
        db.execute("DROP TABLE workflow_receipts")
        db.execute("DROP TABLE workspace_library")
        db.execute("UPDATE store_meta SET schema_version=1")
    health = client.tool("tracker_health", {})
    assert health["schema"] == 3 and health["generation"] == original_token["generation"]
    assert client.tool("tracker_get_item", {"item_id": item_id})["snapshot"]["token"] == original_token
    backups = list((path / "Backups").glob("before-schema-3-*.sqlite"))
    assert len(backups) == 1
    with sqlite3.connect(f"file:{backups[0]}?mode=ro", uri=True) as db:
        assert db.execute("SELECT schema_version FROM store_meta").fetchone()[0] == 1
        assert db.execute("SELECT id FROM items").fetchone()[0] == item_id
    print("PASS: coherent pre-upgrade schema-1 SQLite backup; schema-3 migration preserves generation, item IDs and revisions")


def main(executable):
    with tempfile.TemporaryDirectory(prefix="TicketTracker-stdio-") as directory:
        check_copilot_setup(executable, directory)
        check_cli(executable, directory)
        check_completion_time(CLIClient(executable, Path(directory) / "completion-cli"))
        completion_client = Client(executable, Path(directory) / "completion-mcp")
        try:
            check_completion_time(completion_client)
        finally:
            completion_client.close()
        check_workflow_cli(executable, directory)
        check_schema_upgrade(executable, directory)
        first = Client(executable, directory)
        second = None
        try:
            tools = first.request("tools/list", {})
            assert len(tools["tools"]) == 11
            assert first.tool("tracker_health", {})["ready"]
            context = approvals(first, ticket(first, "APP-101", "notRequired"))
            item_id = context["snapshot"]["item"]["id"]
            check = first.tool("tracker_check_transition", {"item_id": item_id, "target": "merge"})
            assert check["allowed"]
            mr_id = context["snapshot"]["item"]["mergeRequests"][0]["id"]
            mutate(first, context, "jiraDone", error=True)
            context = mutate(first, context, f"mergeMR:{mr_id}")
            context = mutate(first, context, "jiraDone")
            assert context["phase"] == "Done"
            print("PASS: stdio initialization, tool discovery, guarded no-QA lifecycle")

            qa = approvals(first, ticket(first, "APP-102", "required"))
            assert qa["phase"] == "Ready for QA"
            qa = mutate(first, qa, "jiraValidate")
            qa = mutate(first, qa, "qaHandoff")
            qa = mutate(first, qa, "rework", note="QE found an error. Fix while the ticket remains under QA.")
            assert qa["phase"] == "QA · Fix requested"
            assert next(step for step in qa["steps"] if step["id"] == "jiraValidate")["state"] == "completed"
            qa = approvals(first, qa)
            qa = edit(first, qa, testing_notes="Retest the corrected behavior.")
            qa = mutate(first, qa, "retestHandoff")
            qa = mutate(first, qa, "qaPassed")
            qa = mutate(first, qa, "jiraReady")
            assert not first.tool("tracker_check_transition", {
                "item_id": qa["snapshot"]["item"]["id"], "target": "merge",
            })["blockers"]
            print("PASS: QA fix, renewed review, QE retest without reverting the board move")

            second = Client(executable, directory)
            snapshot = qa["snapshot"]
            common = {
                "item_id": snapshot["item"]["id"], "generation": snapshot["token"]["generation"],
                "expected_revision": snapshot["token"]["version"],
            }
            first.sequence += 1
            first_id = first.sequence
            first.send({"jsonrpc": "2.0", "id": first_id, "method": "tools/call", "params": {
                "name": "tracker_update_details", "arguments": {**common, "request_id": "race-one", "notes": "one"},
            }})
            second.sequence += 1
            second_id = second.sequence
            second.send({"jsonrpc": "2.0", "id": second_id, "method": "tools/call", "params": {
                "name": "tracker_update_details", "arguments": {**common, "request_id": "race-two", "notes": "two"},
            }})
            results = [first.response(first_id), second.response(second_id)]
            assert sum(bool(result.get("isError")) for result in results) == 1
            conflict = next(result for result in results if result.get("isError"))
            assert json.loads(conflict["content"][0]["text"])["code"] == "conflict"
            assert len(second.tool("tracker_list_items", {"view": "archive"})["items"]) == 1
            print("PASS: real concurrent helper processes, stale-write rejection, persistent shared state")
        finally:
            first.close()
            if second:
                second.close()
    print("All subprocess integration scenarios passed.")


if __name__ == "__main__":
    if len(sys.argv) != 2 or not Path(sys.argv[1]).is_file():
        raise SystemExit("Pass the built ticket-tracker executable path.")
    main(Path(sys.argv[1]).resolve())
