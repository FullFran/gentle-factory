#!/usr/bin/env python3
"""gentle-factory node runner.

Runs the nodes of a factory spec against a target git repository and writes
one in-toto receipt per node attempt (docs/design/receipt-format.md). The next
node is computed from the receipts (docs/design/node-contract.md section 5), so
a stopped or crashed run resumes by running the same command again.

Usage:
  factory.py run --spec SPEC --repo REPO --context CONTEXT [--run-id ID] [--runs-dir DIR]
  factory.py summary [--runs-dir DIR] [--repo REPO]

Python 3 standard library only.
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import secrets
import signal
import subprocess
import sys
import time
import uuid

PREDICATE_TYPE = "https://github.com/FullFran/gentle-factory/blob/receipt-v0.1/docs/design/receipt-format.md"
STATEMENT_TYPE = "https://in-toto.io/Statement/v1"
RECEIPT_VERSION = "0.1.0"
DEFAULT_RUNS_DIR = "odd/runs"
DEFAULT_PROTECTED = ["odd/runs/", ".factory/", "gates/"]
DENIED_BASH = ["Bash(git push:*)", "Bash(git tag:*)", "Bash(git reset:*)", "Bash(gh:*)"]
READ_ONLY_DENIED = ["Edit", "Write", "NotebookEdit", "Bash(git commit:*)"]
FAIL_PREFIX = "FALLO:"
VERDICT_RE = re.compile(r"^FACTORY_GATES:.*(?:^|\s)status=(GREEN|RED|MISCONFIGURED)(?:\s|$)")
EXIT_OK, EXIT_STOPPED, EXIT_USAGE = 0, 1, 2


class SpecError(Exception):
    """Invalid spec, context or arguments (exit 2)."""


# ---------------------------------------------------------------- helpers

def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def git(repo, *args, check=True):
    proc = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    if check and proc.returncode != 0:
        raise SpecError(f"git {' '.join(args)} failed: {proc.stderr.strip()}")
    return proc.stdout


def head_commit(repo):
    return git(repo, "rev-parse", "HEAD").strip()


def current_branch(repo):
    return git(repo, "rev-parse", "--abbrev-ref", "HEAD").strip()


def last_line(text):
    lines = [line.strip() for line in (text or "").splitlines() if line.strip()]
    return lines[-1] if lines else ""


def sha256_text(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def tree_digest(path):
    """Digest of every file name and content under path (empty when absent)."""
    digest = hashlib.sha256()
    if not os.path.isdir(path):
        return digest.hexdigest()
    for root, dirs, files in os.walk(path):
        dirs.sort()
        for name in sorted(files):
            full = os.path.join(root, name)
            digest.update(os.path.relpath(full, path).encode("utf-8") + b"\0")
            try:
                with open(full, "rb") as handle:
                    digest.update(hashlib.sha256(handle.read()).digest())
            except OSError:
                digest.update(b"unreadable")
    return digest.hexdigest()


# ---------------------------------------------------------------- spec

def load_json(path, what):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise SpecError(f"cannot read {what} {path}: {exc}") from exc


def load_spec(path):
    spec = load_json(path, "spec")
    spec_dir = os.path.dirname(os.path.abspath(path))
    if not isinstance(spec.get("factory"), str) or not spec["factory"]:
        raise SpecError("spec.factory must be a non-empty string")
    nodes = spec.get("nodes")
    if not isinstance(nodes, list) or not nodes:
        raise SpecError("spec.nodes must be a non-empty list")
    max_retries = spec.get("max_retries", 2)
    if not isinstance(max_retries, int) or max_retries < 0:
        raise SpecError("spec.max_retries must be a non-negative integer")
    seen = []
    for node in nodes:
        node_id = node.get("id")
        if not isinstance(node_id, str) or not re.fullmatch(r"[a-z0-9_-]+", node_id or ""):
            raise SpecError(f"node id {node_id!r} must match [a-z0-9_-]+")
        if node_id in seen:
            raise SpecError(f"duplicate node id {node_id}")
        kind = node.get("kind")
        if kind == "code":
            if not isinstance(node.get("command"), list) or not node["command"]:
                raise SpecError(f"code node {node_id} needs a non-empty command list")
        elif kind == "agent":
            if node.get("engine", "claude") != "claude":
                raise SpecError(f"agent node {node_id}: only engine 'claude' is supported")
            if not node.get("prompt_file"):
                raise SpecError(f"agent node {node_id} needs prompt_file")
            node["prompt_file"] = os.path.join(spec_dir, node["prompt_file"])
            if not os.path.isfile(node["prompt_file"]):
                raise SpecError(f"agent node {node_id}: prompt_file not found")
            if not isinstance(node.get("tools", []), list):
                raise SpecError(f"agent node {node_id}: tools must be a list")
        else:
            raise SpecError(f"node {node_id}: kind must be 'code' or 'agent'")
        role = node.setdefault("role", "checker" if kind == "code" or node.get("read_only") else "producer")
        if role not in ("producer", "checker"):
            raise SpecError(f"node {node_id}: role must be producer or checker")
        retry = node.get("retry")
        if retry is not None:
            if retry not in seen:
                raise SpecError(f"node {node_id}: retry target {retry!r} must be an earlier node")
            target = next(n for n in nodes if n["id"] == retry)
            if target["role"] != "producer":
                raise SpecError(f"node {node_id}: retry target {retry} must be a producer")
        seen.append(node_id)
    spec["max_retries"] = max_retries
    spec.setdefault("protected_paths", DEFAULT_PROTECTED)
    spec["_dir"] = spec_dir
    return spec


def load_context(path):
    ctx = load_json(path, "context")
    for key in ("repository", "issue", "design_comment"):
        if key not in ctx:
            raise SpecError(f"context.{key} is required")
    task = ctx.get("task_id") or f"{ctx['repository']}#{ctx['issue'].get('number')}"
    return ctx, task


# ---------------------------------------------------------------- store

class Store:
    """Append-only receipt store: <runs_dir>/<run_id>/{receipts,logs,feedback}."""

    def __init__(self, runs_dir, run_id):
        self.runs_dir = runs_dir
        self.run_dir = os.path.join(runs_dir, run_id)
        for sub in ("receipts", "logs", "feedback"):
            os.makedirs(os.path.join(self.run_dir, sub), exist_ok=True)

    def receipts(self):
        return read_receipts(os.path.join(self.run_dir, "receipts"))

    def append(self, receipt):
        rdir = os.path.join(self.run_dir, "receipts")
        seq = len(os.listdir(rdir)) + 1
        step = receipt["predicate"]["step"]
        path = os.path.join(rdir, f"{seq:04d}-{step['node_id']}-{step['attempt']}.json")
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(receipt, handle, indent=2)
            handle.write("\n")
        os.replace(tmp, path)
        return path

    def log_path(self, node_id, attempt):
        return os.path.join(self.run_dir, "logs", f"{node_id}-{attempt}.log")

    def feedback_path(self, node_id):
        return os.path.join(self.run_dir, "feedback", f"{node_id}.txt")


def read_receipts(rdir):
    if not os.path.isdir(rdir):
        return []
    out = []
    for name in sorted(os.listdir(rdir)):
        if name.endswith(".json"):
            with open(os.path.join(rdir, name), encoding="utf-8") as handle:
                out.append(json.load(handle)["predicate"])
    return out


def exclude_runs_dir(repo, runs_dir):
    """Keep the receipt store out of git status and `git add -A`."""
    rel = os.path.relpath(runs_dir, repo)
    if rel.startswith(".."):
        return
    exclude = git(repo, "rev-parse", "--git-path", "info/exclude").strip()
    if not os.path.isabs(exclude):
        exclude = os.path.join(repo, exclude)
    entry = "/" + rel.replace(os.sep, "/").rstrip("/") + "/"
    existing = ""
    if os.path.exists(exclude):
        with open(exclude, encoding="utf-8") as handle:
            existing = handle.read()
    if entry not in existing.splitlines():
        os.makedirs(os.path.dirname(exclude), exist_ok=True)
        with open(exclude, "a", encoding="utf-8") as handle:
            if existing and not existing.endswith("\n"):
                handle.write("\n")
            handle.write(entry + "\n")


# ---------------------------------------------------------------- decide

def is_current(receipt, node, head):
    if receipt["outcome"]["status"] != "success":
        return False
    if node["role"] == "producer":
        return True
    return receipt["references"].get("vcs", {}).get("head_commit") == head


def next_node(nodes, receipts, head):
    """First node without a current success receipt (node contract 5.1)."""
    for node in nodes:
        mine = [r for r in receipts if r["step"]["node_id"] == node["id"]]
        if not any(is_current(r, node, head) for r in mine):
            return node
    return None


def attempts_of(receipts, node_id):
    return sum(1 for r in receipts if r["step"]["node_id"] == node_id)


# ---------------------------------------------------------------- execution

def run_process(cmd, cwd, env, stdin_text, timeout):
    """Run cmd in its own process group; SIGTERM then SIGKILL on timeout."""
    grace = float(os.environ.get("FACTORY_KILL_GRACE", "30"))
    try:
        proc = subprocess.Popen(cmd, cwd=cwd, env=env, text=True, start_new_session=True,
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as exc:
        return 127, "", f"cannot start {cmd[0]}: {exc}", False
    try:
        out, err = proc.communicate(stdin_text, timeout=timeout)
        return proc.returncode, out, err, False
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            out, err = proc.communicate(timeout=grace)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            out, err = proc.communicate()
        return proc.returncode, out or "", err or "", True


def merge_otel(existing, attrs):
    keys = {k for k, _ in attrs}
    kept = [p for p in (existing or "").split(",") if p and p.split("=", 1)[0] not in keys]
    return ",".join(kept + [f"{k}={v}" for k, v in attrs])


def node_env(ctx, node, attempt, feedback_file, engine):
    env = dict(os.environ)
    attrs = [("service.name", f"factory-{ctx['factory']}"), ("factory.name", ctx["factory"]),
             ("run.id", ctx["run_id"]), ("task.id", ctx["task_id"]), ("agent.engine", engine)]
    env.update({
        "FACTORY_NAME": ctx["factory"],
        "FACTORY_RUN_ID": ctx["run_id"],
        "FACTORY_TASK_ID": ctx["task_id"],
        "FACTORY_NODE_ID": node["id"],
        "FACTORY_ATTEMPT": str(attempt),
        "FACTORY_FEEDBACK_FILE": feedback_file or "",
        "TRACEPARENT": ctx["traceparent"],
        "OTEL_RESOURCE_ATTRIBUTES": merge_otel(env.get("OTEL_RESOURCE_ATTRIBUTES"), attrs),
    })
    return env


def expand(arg, values):
    for key, value in values.items():
        arg = arg.replace("{" + key + "}", value)
    return arg


def claude_command(node):
    tools = list(node.get("tools", []))
    denied = list(DENIED_BASH) + list(node.get("deny", []))
    if node.get("read_only"):
        denied += READ_ONLY_DENIED
        tools = [t for t in tools if t not in READ_ONLY_DENIED]
    cmd = [os.environ.get("FACTORY_CLAUDE_BIN", "claude"), "-p", "--output-format", "json",
           "--max-turns", str(node.get("max_turns", 30)),
           "--max-budget-usd", str(node.get("max_budget_usd", 3.0)),
           "--no-session-persistence"]
    if tools:
        cmd += ["--allowedTools", *tools]
    cmd += ["--disallowedTools", *denied]
    return cmd, tools


def token_usage(data):
    """Tokens summed over modelUsage (top-level usage is zero on error results)."""
    per_model = (data.get("modelUsage") or {}).values()
    inputs = outputs = 0
    seen = False
    for usage in per_model:
        if isinstance(usage, dict) and isinstance(usage.get("outputTokens"), int):
            seen = True
            inputs += sum(int(usage.get(k) or 0) for k in
                          ("inputTokens", "cacheReadInputTokens", "cacheCreationInputTokens"))
            outputs += int(usage["outputTokens"])
    if not seen:
        usage = data.get("usage") or {}
        if not all(isinstance(usage.get(k), int) for k in ("input_tokens", "output_tokens")):
            return {}
        inputs = usage["input_tokens"] + int(usage.get("cache_read_input_tokens") or 0) \
            + int(usage.get("cache_creation_input_tokens") or 0)
        outputs = usage["output_tokens"]
    return {"input_tokens": inputs, "output_tokens": outputs, "total_tokens": inputs + outputs}


CLAUDE_REASONS = {"success": "completed", "error_max_turns": "max_turns_exceeded",
                  "error_max_budget_usd": "budget_exceeded", "error_during_execution": "engine_error"}


def run_agent(node, ctx, attempt, feedback, feedback_file):
    with open(node["prompt_file"], encoding="utf-8") as handle:
        prompt = handle.read()
    if feedback:
        prompt += ("\n\n## Feedback from the previous attempt\n\n"
                   "A later step failed with the reason below. Fix it.\n\n" + feedback + "\n")
    cmd, tools = claude_command(node)
    timeout = node.get("timeout_seconds", 1800)
    env = node_env(ctx, node, attempt, feedback_file, "claude-code")
    start = time.monotonic()
    code, out, err, timed_out = run_process(cmd, ctx["repo"], env, prompt, timeout)
    duration = int((time.monotonic() - start) * 1000)
    result = {"log": (cmd, out, err), "engine": "claude-code-headless", "command": cmd, "tools": tools,
              "caps": {"max_turns": node.get("max_turns", 30),
                       "max_budget_usd": float(node.get("max_budget_usd", 3.0)),
                       "timeout_seconds": timeout},
              "duration_ms": duration, "exit_code": code, "telemetry": {}}
    if timed_out:
        return {**result, "status": "failure", "terminal_reason": "timeout",
                "reason": f"timed out after {timeout}s"}
    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        return {**result, "status": "failure", "terminal_reason": "engine_output_invalid",
                "reason": last_line(err) or last_line(out) or f"exit {code}"}
    text = data.get("result") or ""
    tokens = token_usage(data)
    models = list((data.get("modelUsage") or {}).keys())
    telemetry = {"gen_ai_system": "anthropic", "num_turns": data.get("num_turns")}
    if isinstance(data.get("total_cost_usd"), (int, float)):
        telemetry["total_cost_usd"] = float(data["total_cost_usd"])
    if tokens:
        telemetry["tokens"] = tokens
    if models:
        telemetry["request_model"] = models[0]
    result["telemetry"] = {k: v for k, v in telemetry.items() if v is not None}
    result["notes"] = text[-2000:]
    subtype = data.get("subtype", "")
    final = last_line(text)
    if final.startswith(FAIL_PREFIX):
        return {**result, "status": "failure", "terminal_reason": "step_failed",
                "reason": final[len(FAIL_PREFIX):].strip()}
    if data.get("is_error") or subtype != "success" or code != 0:
        return {**result, "status": "failure",
                "terminal_reason": CLAUDE_REASONS.get(subtype, subtype or "engine_error"),
                "reason": final or subtype or f"exit {code}"}
    return {**result, "status": "success", "terminal_reason": "completed"}


def run_code(node, ctx, attempt, feedback_file):
    values = {"repo": ctx["repo"], "base_commit": ctx["base_commit"], "run_dir": ctx["run_dir"],
              "spec_dir": ctx["spec_dir"], "feedback_file": feedback_file or ""}
    cmd = [expand(str(a), values) for a in node["command"]]
    timeout = node.get("timeout_seconds", 600)
    env = node_env(ctx, node, attempt, feedback_file, "code")
    start = time.monotonic()
    code, out, err, timed_out = run_process(cmd, ctx["repo"], env, "", timeout)
    duration = int((time.monotonic() - start) * 1000)
    result = {"log": (cmd, out, err), "engine": os.path.basename(cmd[0]), "command": cmd, "tools": [os.path.basename(cmd[0])],
              "caps": {"timeout_seconds": timeout}, "duration_ms": duration, "exit_code": code,
              "telemetry": {}, "notes": ""}
    verdict = next((l.strip() for l in reversed(out.splitlines()) if VERDICT_RE.match(l.strip())), None)
    if verdict:
        status = VERDICT_RE.match(verdict).group(1)
        failed = sorted(set(re.findall(r"GATE: name=(\S+) status=(?:RED|MISCONFIGURED)", out)))
        passed = sorted(set(re.findall(r"GATE: name=(\S+) status=GREEN", out)))
        result["gate"] = {"status": status, "verdict_line": verdict,
                          "checks_passed": passed, "checks_failed": failed}
    if timed_out:
        return {**result, "status": "failure", "terminal_reason": "timeout",
                "reason": f"timed out after {timeout}s"}
    final = last_line(out)
    if final.startswith(FAIL_PREFIX):
        return {**result, "status": "failure", "terminal_reason": "step_failed",
                "reason": final[len(FAIL_PREFIX):].strip()}
    gate_status = result.get("gate", {}).get("status")
    if gate_status == "MISCONFIGURED" or code in (126, 127):
        return {**result, "status": "misconfigured", "terminal_reason": "misconfigured",
                "reason": verdict or last_line(err) or f"exit {code}"}
    if code != 0 or gate_status == "RED":
        return {**result, "status": "failure",
                "terminal_reason": "gate_failed" if gate_status else "step_failed",
                "reason": verdict or final or last_line(err) or f"exit {code}"}
    return {**result, "status": "success", "terminal_reason": "gate_passed" if gate_status else "completed"}


def write_log(path, cmd, out, err):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("$ " + " ".join(cmd) + "\n")
        handle.write(out or "")
        if err:
            handle.write("\n--- stderr ---\n" + err)


# ---------------------------------------------------------------- guards

def repo_state(repo):
    """HEAD plus every tracked and untracked change, for the read-only guard."""
    status = git(repo, "status", "--porcelain", "--untracked-files=all")
    diff = git(repo, "diff", "HEAD", "--binary")
    untracked = git(repo, "ls-files", "--others", "--exclude-standard").splitlines()
    blob = hashlib.sha256()
    for path in sorted(untracked):
        try:
            with open(os.path.join(repo, path), "rb") as handle:
                blob.update(path.encode() + b"\0" + hashlib.sha256(handle.read()).digest())
        except OSError:
            blob.update(path.encode() + b"\0missing")
    return (head_commit(repo), status, sha256_text(diff), blob.hexdigest())


def changed_paths(repo, since_head, untracked_before):
    tracked = git(repo, "diff", "--name-only", since_head).splitlines()
    untracked = set(git(repo, "ls-files", "--others", "--exclude-standard").splitlines())
    return set(tracked) | (untracked - set(untracked_before))


def protected_hits(paths, protected):
    hits = []
    for path in sorted(paths):
        for prefix in protected:
            if path == prefix.rstrip("/") or path.startswith(prefix.rstrip("/") + "/"):
                hits.append(path)
                break
    return hits


def commit_producer_changes(repo, ctx, node, attempt):
    """The harness closes the node: leftover producer edits become one commit."""
    if not git(repo, "status", "--porcelain").strip():
        return
    git(repo, "add", "-A")
    git(repo, "-c", "user.name=gentle-factory", "-c", "user.email=factory@localhost",
        "commit", "-q", "--no-verify", "-m",
        f"chore(factory): {node['id']} attempt {attempt} ({ctx['run_id']})")


# ---------------------------------------------------------------- receipts

def failure_signature(outcome):
    gate = outcome.get("gate") or {}
    if gate.get("checks_failed"):
        basis = "checks:" + ",".join(gate["checks_failed"])
    else:
        basis = "reason:" + " ".join((outcome.get("reason") or outcome["terminal_reason"]).split())
    return sha256_text(basis)


def build_receipt(ctx, node, attempt, outcome, head):
    predicate = {
        "version": RECEIPT_VERSION,
        "run_id": ctx["run_id"],
        "step": {"node_id": node["id"], "node_kind": node["kind"], "attempt": attempt},
        "references": {
            "repository": ctx["context"]["repository"],
            "issue": ctx["context"]["issue"],
            "design_comment": ctx["context"]["design_comment"],
            "vcs": {"base_commit": ctx["base_commit"], "head_commit": head, "branch": ctx["branch"]},
        },
        "execution": {"engine": outcome["engine"], "command": outcome["command"],
                      "tools_allowed": outcome["tools"], "caps": outcome["caps"]},
        "telemetry": {"trace_id": ctx["trace_id"], "span_id": outcome["span_id"],
                      "traceparent": f"00-{ctx['trace_id']}-{outcome['span_id']}-01",
                      **outcome["telemetry"], "duration_ms": outcome["duration_ms"]},
        "outcome": {"status": outcome["status"], "terminal_reason": outcome["terminal_reason"]},
    }
    if outcome.get("engine_version"):
        predicate["execution"]["engine_version"] = outcome["engine_version"]
    if outcome["exit_code"] is not None and (outcome["status"] != "success" or outcome["exit_code"] == 0):
        predicate["outcome"]["exit_code"] = outcome["exit_code"]
    if outcome.get("gate"):
        predicate["gate"] = outcome["gate"]
    if outcome["status"] != "success":
        predicate["failure_signature"] = failure_signature(outcome)
    notes = outcome.get("notes") or ""
    if outcome.get("reason") and outcome["status"] != "success":
        notes = (f"reason: {outcome['reason']}\n" + notes).strip()
    if notes:
        predicate["notes"] = notes
    return {"_type": STATEMENT_TYPE,
            "subject": [{"name": "git:commit", "digest": {"gitCommit": head}}],
            "predicateType": PREDICATE_TYPE, "predicate": predicate}


# ---------------------------------------------------------------- run loop

def engine_version(binary):
    proc = subprocess.run([binary, "--version"], capture_output=True, text=True)
    return last_line(proc.stdout) if proc.returncode == 0 else ""


def execute(node, ctx, store, receipts, feedback):
    """Run one attempt of node, apply the guards, write its receipt."""
    attempt = attempts_of(receipts, node["id"]) + 1
    feedback_file = None
    if feedback:
        feedback_file = store.feedback_path(node["id"])
        with open(feedback_file, "w", encoding="utf-8") as handle:
            handle.write(feedback + "\n")
    repo = ctx["repo"]
    before = repo_state(repo)
    untracked_before = git(repo, "ls-files", "--others", "--exclude-standard").splitlines()
    runs_before = tree_digest(store.runs_dir)
    print(f"NODE: id={node['id']} attempt={attempt} kind={node['kind']}", flush=True)
    if node["kind"] == "agent":
        outcome = run_agent(node, ctx, attempt, feedback, feedback_file)
        if "engine_version" not in ctx:
            ctx["engine_version"] = engine_version(outcome["command"][0])
        outcome["engine_version"] = ctx["engine_version"]
    else:
        outcome = run_code(node, ctx, attempt, feedback_file)
    outcome["span_id"] = secrets.token_hex(8)

    # Guards run before the receipt is written (node contract 4.2).
    if node.get("read_only") and repo_state(repo) != before:
        outcome.update(status="failure", terminal_reason="read_only_modified",
                       reason="read-only step changed the target repository (git status/HEAD differ)")
    if node["kind"] == "agent":
        hits = protected_hits(changed_paths(repo, before[0], untracked_before), ctx["protected"])
        if tree_digest(store.runs_dir) != runs_before:
            hits.append(os.path.relpath(store.runs_dir, repo) + "/")
        if hits:
            outcome.update(status="failure", terminal_reason="protected_path_modified",
                           reason="protected paths changed: " + ", ".join(hits))
    # The log goes into the receipt store only after the store integrity check.
    write_log(store.log_path(node["id"], attempt), *outcome["log"])
    if outcome["status"] == "success" and node["role"] == "producer":
        commit_producer_changes(repo, ctx, node, attempt)

    receipt = build_receipt(ctx, node, attempt, outcome, head_commit(repo))
    store.append(receipt)
    print(f"NODE: id={node['id']} attempt={attempt} status={outcome['status']} "
          f"reason={outcome['terminal_reason']} duration_ms={outcome['duration_ms']}", flush=True)
    return receipt["predicate"], outcome


def stop(node_id, reason, detail):
    detail = " ".join((detail or "").split())
    print(f"RUN: status=STOPPED node={node_id} reason={reason} detail={detail}", flush=True)
    return EXIT_STOPPED


def run_factory(args):
    spec = load_spec(args.spec)
    context, task_id = load_context(args.context)
    repo = os.path.abspath(args.repo)
    if git(repo, "rev-parse", "--show-toplevel", check=False).strip() == "":
        raise SpecError(f"{repo} is not a git repository")
    repo = git(repo, "rev-parse", "--show-toplevel").strip()
    runs_dir = os.path.abspath(args.runs_dir or os.path.join(repo, DEFAULT_RUNS_DIR))
    run_id = args.run_id or f"run_{uuid.uuid4()}"
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", run_id):
        raise SpecError("run id must match [A-Za-z0-9_.-]+")
    exclude_runs_dir(repo, runs_dir)
    store = Store(runs_dir, run_id)
    receipts = store.receipts()
    base = receipts[0]["references"]["vcs"]["base_commit"] if receipts else head_commit(repo)
    trace_id = sha256_text(run_id)[:32]
    ctx = {"factory": spec["factory"], "run_id": run_id, "task_id": task_id, "context": context,
           "repo": repo, "run_dir": store.run_dir, "spec_dir": spec["_dir"], "base_commit": base,
           "branch": current_branch(repo), "trace_id": trace_id,
           "traceparent": f"00-{trace_id}-{secrets.token_hex(8)}-01",
           "protected": spec["protected_paths"]}
    print(f"RUN: id={run_id} factory={spec['factory']} task={task_id} runs_dir={runs_dir}", flush=True)
    nodes = spec["nodes"]
    by_id = {n["id"]: n for n in nodes}
    while True:
        receipts = store.receipts()
        head = head_commit(repo)
        node = next_node(nodes, receipts, head)
        if node is None:
            print(f"RUN: status=COMPLETE id={run_id}", flush=True)
            return EXIT_OK
        mine = [r for r in receipts if r["step"]["node_id"] == node["id"]]
        last = mine[-1] if mine else None
        if (node.get("retry") and last and last["outcome"]["status"] == "failure"
                and last["references"]["vcs"]["head_commit"] == head):
            # Resumed after this checker failed on the current code: decide, do not re-run.
            predicate, prior = last, mine[:-1]
        else:
            predicate, outcome = execute(node, ctx, store, receipts, None)
            if outcome["status"] == "success":
                continue
            if outcome["status"] != "failure" or not node.get("retry"):
                return stop(node["id"], outcome["terminal_reason"], reason_of(predicate))
            prior = mine
        reason = reason_of(predicate)
        if prior and prior[-1]["outcome"]["status"] == "failure" \
                and prior[-1].get("failure_signature") == predicate["failure_signature"]:
            return stop(node["id"], "same_failure_signature", reason)
        target = by_id[node["retry"]]
        if attempts_of(receipts, target["id"]) - 1 >= spec["max_retries"]:
            return stop(node["id"], "retries_exhausted", reason)
        print(f"RETRY: node={target['id']} after={node['id']} reason={' '.join(reason.split())}", flush=True)
        _, outcome = execute(target, ctx, store, store.receipts(), reason)
        if outcome["status"] != "success":
            return stop(target["id"], outcome["terminal_reason"], reason_of_outcome(outcome))


def reason_of(predicate):
    notes = predicate.get("notes") or ""
    first = notes.splitlines()[0] if notes else ""
    if first.startswith("reason: "):
        return first[len("reason: "):]
    return predicate["outcome"]["terminal_reason"]


def reason_of_outcome(outcome):
    return outcome.get("reason") or outcome["terminal_reason"]



# ---------------------------------------------------------------- summary

def summary(args):
    repo = os.path.abspath(args.repo or ".")
    runs_dir = os.path.abspath(args.runs_dir or os.path.join(repo, DEFAULT_RUNS_DIR))
    if not os.path.isdir(runs_dir):
        raise SpecError(f"no runs directory at {runs_dir}")
    stats = {}
    runs = 0
    for run in sorted(os.listdir(runs_dir)):
        receipts = read_receipts(os.path.join(runs_dir, run, "receipts"))
        if not receipts:
            continue
        runs += 1
        for r in receipts:
            s = stats.setdefault(r["step"]["node_id"], {"attempts": 0, "failures": 0, "retries": 0,
                                                       "cost_usd": 0.0, "duration_ms": 0})
            s["attempts"] += 1
            s["failures"] += r["outcome"]["status"] != "success"
            s["retries"] += r["step"]["attempt"] > 1
            s["cost_usd"] += r.get("telemetry", {}).get("total_cost_usd", 0.0)
            s["duration_ms"] += r.get("telemetry", {}).get("duration_ms", 0)
    if args.json:
        print(json.dumps({"runs": runs, "nodes": stats}, indent=2, sort_keys=True))
        return EXIT_OK
    print(f"RUNS: {runs}")
    print(f"{'node':<20} {'attempts':>8} {'failures':>8} {'retries':>7} {'cost_usd':>9} {'duration_ms':>11}")
    for node_id in sorted(stats):
        s = stats[node_id]
        print(f"{node_id:<20} {s['attempts']:>8} {s['failures']:>8} {s['retries']:>7} "
              f"{s['cost_usd']:>9.4f} {s['duration_ms']:>11}")

    def most(key):
        best = max(sorted(stats), key=lambda n: stats[n][key], default=None)
        return best if best and stats[best][key] > 0 else "-"

    print(f"MOST: failures={most('failures')} retries={most('retries')} cost={most('cost_usd')}")
    return EXIT_OK


# ---------------------------------------------------------------- cli

def main(argv=None):
    parser = argparse.ArgumentParser(prog="factory", description="gentle-factory node runner")
    sub = parser.add_subparsers(dest="cmd", required=True)
    run = sub.add_parser("run", help="run (or resume) a factory against a repository")
    run.add_argument("--spec", required=True, help="factory spec JSON")
    run.add_argument("--repo", required=True, help="target git repository")
    run.add_argument("--context", required=True, help="references JSON: repository, issue, design_comment")
    run.add_argument("--run-id", help="resume this run id (default: a new one)")
    run.add_argument("--runs-dir", help=f"receipt store (default: <repo>/{DEFAULT_RUNS_DIR})")
    summ = sub.add_parser("summary", help="which node fails, retries or costs the most across runs")
    summ.add_argument("--runs-dir", help=f"receipt store (default: <repo>/{DEFAULT_RUNS_DIR})")
    summ.add_argument("--repo", help="target repository (default: current directory)")
    summ.add_argument("--json", action="store_true", help="machine-readable output")
    args = parser.parse_args(argv)
    try:
        return run_factory(args) if args.cmd == "run" else summary(args)
    except SpecError as exc:
        print(f"RUN: status=MISCONFIGURED reason={' '.join(str(exc).split())}", file=sys.stderr)
        return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main())
