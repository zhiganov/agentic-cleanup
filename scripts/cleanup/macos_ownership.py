"""Bounded macOS ownership evidence. Never persists commands, config or secrets."""
from __future__ import annotations

import importlib.util
import json
import os
import re
import selectors
import shlex
import signal
import stat
import subprocess
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
_path = Path(__file__).resolve().parents[1] / "windows/cleanup/file_audit.py"
_spec = importlib.util.spec_from_file_location("cleanup_metadata", _path)
metadata = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(metadata)


def absolute(path):
    return os.path.abspath(os.fspath(path))  # lexical only; never resolve links


def within(path, root):
    return metadata.inside(absolute(path), absolute(root))


def read_metadata(path, check=lambda: None, limit=262144):
    """Only caller-allowlisted config/plist/selector files; pinned no-follow read."""
    path = absolute(path)
    with metadata.root_scope(os.path.dirname(path), check) as parent:
        check()
        info = parent.metadata(os.path.basename(path))
        if (not stat.S_ISREG(info.st_mode) or info.st_size > limit or
                getattr(info, "st_flags", 0) & getattr(stat, "SF_DATALESS", 0x40000000)):
            raise OSError("unsupported-metadata")
        fd = os.open(os.path.basename(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                     dir_fd=parent.descriptor)
        try:
            current = os.fstat(fd)
            if (not stat.S_ISREG(current.st_mode) or
                    getattr(current, "st_flags", 0) & getattr(stat, "SF_DATALESS", 0x40000000) or
                    (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino)):
                raise OSError("changed-metadata")
            data = bytearray()
            while len(data) <= limit:
                check()
                block = os.read(fd, min(16384, limit + 1 - len(data)))
                if not block:
                    break
                data.extend(block)
            after = os.fstat(fd)
            if len(data) != info.st_size or (after.st_size, after.st_mtime_ns) != (info.st_size, info.st_mtime_ns):
                raise OSError("changed-metadata")
            return bytes(data)
        finally:
            os.close(fd)


def jsonc(data):
    """Comments/trailing commas only; never evaluates substitutions or imports."""
    text = data.decode("utf-8-sig")
    result, index, quoted, escaped = [], 0, False, False
    while index < len(text):
        char = text[index]
        if quoted:
            result.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
            index += 1
            continue
        if char == '"':
            quoted = True
        elif text[index:index + 2] == "//":
            end = text.find("\n", index + 2)
            index = len(text) if end < 0 else end
            continue
        elif text[index:index + 2] == "/*":
            end = text.find("*/", index + 2)
            if end < 0:
                raise ValueError("invalid-jsonc")
            result.append(" ")
            index = end + 2
            continue
        result.append(char)
        index += 1
    text, result, quoted, escaped = "".join(result), [], False, False
    for index, char in enumerate(text):
        if not quoted and char == "," and text[index + 1:].lstrip().startswith(("}", "]")):
            continue
        result.append(char)
        if escaped:
            escaped = False
        elif quoted and char == "\\":
            escaped = True
        elif char == '"':
            quoted = not quoted
    return json.loads("".join(result))


def command(args, seconds=5, max_bytes=2097152, env=None):
    """Fixed read-only commands only, bounded output/time; own and reap workers."""
    process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               start_new_session=True, env=env)
    output = bytearray()
    deadline = time.monotonic() + seconds
    completed = False
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("command-budget")
                for key, _ in selector.select(min(remaining, 0.1)):
                    block = os.read(key.fd, 16384)
                    if not block:
                        selector.unregister(key.fileobj)
                    output.extend(block)
                    if len(output) > max_bytes:
                        raise TimeoutError("command-output-budget")
        code = process.wait(timeout=max(0.01, deadline - time.monotonic()))
        completed = True
        return code, output.decode(errors="replace")
    finally:
        if not completed:
            try:
                os.killpg(process.pid, signal.SIGKILL)  # only this invocation's group
            except ProcessLookupError:
                pass
        process.wait()
        process.stdout.close()


def processes(run=command):
    paths, names, counts, failures = set(), set(), {}, []
    rows = {}
    try:
        code, output = run(["/bin/ps", "-U", str(os.getuid()), "-o", "pid=,ppid=,comm="])
        if code:
            failures.append("process-census-incomplete")
        for line in output.splitlines():
            fields = line.split(None, 2)
            if len(fields) == 3 and fields[0].isdigit() and fields[1].isdigit():
                rows[int(fields[0])] = (int(fields[1]), fields[2])
        ancestors, pid = {os.getpid()}, os.getpid()
        while pid in rows and rows[pid][0] not in ancestors:
            pid = rows[pid][0]
            ancestors.add(pid)
        for pid, (_, executable) in rows.items():
            if pid == os.getpid():
                continue
            name = os.path.basename(executable).casefold()
            names.add(name)
            if executable.startswith("/"):
                paths.add(absolute(executable))
            for runtime in ("opencode", "claude", "codex", "node", "bun", "python"):
                if name == runtime or name.startswith(runtime + "-") or (runtime == "python" and name.startswith("python")):
                    counts[runtime] = counts.get(runtime, 0) + 1
        code, output = run(["/bin/ps", "-U", str(os.getuid()), "-o", "pid=,command="])
        if code:
            failures.append("process-arguments-incomplete")
        model_host = bool(failures)
        for line in output.splitlines():
            fields = line.split(None, 1)
            if len(fields) != 2 or not fields[0].isdigit() or int(fields[0]) == os.getpid():
                continue
            pid, text = int(fields[0]), fields[1]
            try:
                paths.update(absolute(token) for token in shlex.split(text) if token.startswith("/") and "://" not in token)
            except ValueError:
                failures.append("unparsed-process-arguments")
            name = os.path.basename(rows.get(pid, (0, ""))[1]).casefold()
            if pid not in ancestors and name.startswith(("python", "node", "bun", "uv", "whisper", "ollama")):
                model_host |= any(word in text.casefold() for word in ("huggingface", "transformers", "faster-whisper", "ollama"))
        code, output = run(["/usr/sbin/lsof", "-nP", "-a", "-u", str(os.getuid()), "-Fpn"])
        if code:
            failures.append("open-paths-incomplete")
        paths.update(absolute(line[1:]) for line in output.splitlines() if line.startswith("n/"))
    except (OSError, TimeoutError, subprocess.SubprocessError):
        failures.append("process-probe-unavailable")
        model_host = True
    return {"paths": paths, "names": names, "modelHost": model_host,
            "summary": {"status": "partial", "runtimeCounts": counts, "failures": sorted(set(failures)),
                        "limitations": ["Current-user accessible processes only; hidden/new consumers remain unknown.",
                                        "Runtime counts are not exact session attribution; no open path does not prove non-use."]}}


def no_processes():
    return {"paths": set(), "names": set(), "modelHost": True,
            "summary": {"status": "unsupported", "runtimeCounts": {}, "failures": [],
                        "limitations": ["Process probing was disabled; no absence or closed-owner claim is possible."]}}


def live(path, process):
    return any(within(value, path) for value in process["paths"])


def launch_path(token, base, home, env):
    if not isinstance(token, str) or any(char in token for char in "\n\r;|&`") or "://" in token:
        return None
    def expand(match):
        value = env.get(match[1])
        if not isinstance(value, str):
            raise ValueError("unresolved-mcp-path")
        return value
    token = re.sub(r"\{env:([A-Za-z_][A-Za-z0-9_]*)\}", expand, token)
    token = re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", expand, token)
    if any(char in token for char in "{}$"):
        raise ValueError("unresolved-mcp-path")
    if token.startswith(("-", "@")):
        return None
    if token == "~" or token.startswith("~/"):
        token = home + token[1:]
    if token.startswith("/"):
        return absolute(token)
    if "/" in token or re.search(r"\.(?:[cm]?[jt]s|py|rb|sh)$", token):
        return absolute(os.path.join(base, token))
    return None


def mcp_ownership(sources, cwd, home, env, check=lambda: None):
    paths, failures, read = set(), [], 0
    for source, runtime, base in sorted(set(sources)):
        try:
            data = jsonc(read_metadata(source, check))
        except FileNotFoundError:
            continue
        except (OSError, ValueError, UnicodeError, TypeError):
            failures.append("mcp-source-unreadable-or-unsupported")
            continue
        read += 1
        if not isinstance(data, dict):
            failures.append("mcp-source-unsupported")
            continue
        mcp = data.get("mcp", {})
        groups = [(data.get("mcpServers", {}), base)] if runtime == "claude" else [(mcp.get("servers", {}) if isinstance(mcp, dict) else None, base)]
        if runtime == "claude":
            projects = data.get("projects", {})
            if not isinstance(projects, dict):
                failures.append("mcp-source-unsupported")
                projects = {}
            for project, settings in projects.items():
                if isinstance(project, str) and project.startswith("/") and isinstance(settings, dict):
                    groups.append((settings.get("mcpServers", {}), project))
        for servers, scope in groups:
            check()
            if not isinstance(servers, dict):
                failures.append("mcp-source-unsupported")
                continue
            for server in servers.values():  # never persist opaque server names
                check()
                if not isinstance(server, dict) or server.get("type") in ("remote", "http", "sse"):
                    continue
                if runtime == "opencode" and server.get("type") != "local":
                    failures.append("mcp-registration-unsupported")
                    continue
                tokens = server.get("command", [])
                arguments = server.get("args", [])
                if runtime == "claude" and isinstance(tokens, str):
                    tokens = [tokens] + arguments if isinstance(arguments, list) else []
                if not isinstance(tokens, list) or not tokens or not all(isinstance(x, str) for x in tokens):
                    failures.append("mcp-registration-unsupported")
                    continue
                if os.path.basename(tokens[0]) in ("sh", "bash", "zsh", "fish", "cmd", "powershell", "pwsh"):
                    failures.append("mcp-shell-registration-unresolved")
                    continue
                try:
                    local_env = server.get("environment" if runtime == "opencode" else "env", {})
                    local_env = {**env, **local_env} if isinstance(local_env, dict) else env
                    working = launch_path(server.get("cwd", ""), scope, home, local_env) or scope
                    resolved = {path for token in tokens if (path := launch_path(token, working, home, local_env))}
                    paths.update(resolved)
                    if server.get("cwd"):
                        paths.add(working)
                    if not resolved and not server.get("cwd"):
                        failures.append("mcp-package-or-executable-ownership-unresolved")
                except ValueError:
                    failures.append("mcp-path-substitution-unresolved")
    if env.get("OPENCODE_CONFIG_CONTENT") or env.get("OPENCODE_CONFIG"):
        failures.append("opencode-dynamic-source-not-inspected")
    return {"paths": paths, "summary": {"status": "partial" if failures else "complete-static-sources",
                                        "sourcesRead": read, "failures": sorted(set(failures)),
                                        "limitations": ["Static local registrations only; remote/managed/dynamic registrations are not absence evidence."]}}
