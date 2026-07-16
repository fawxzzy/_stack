from __future__ import annotations

import os
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any


def atlas_root() -> Path:
    return Path(__file__).resolve().parents[1]


def normalize_slashes(value: str) -> str:
    return value.replace("\\", "/")


def parse_scalar(value: str) -> Any:
    lowered = value.lower()
    if lowered == "true":
        return True
    if lowered == "false":
        return False
    if lowered == "null":
        return None
    if (value.startswith('"') and value.endswith('"')) or (value.startswith("'") and value.endswith("'")):
        return value[1:-1]
    if re.fullmatch(r"-?\d+", value):
        return int(value)
    if re.fullmatch(r"-?\d+\.\d+", value):
        return float(value)
    return value


def parse_simple_yaml(text: str) -> dict[str, Any]:
    lines: list[tuple[int, str]] = []
    for raw_line in text.splitlines():
        if not raw_line.strip():
            continue
        stripped = raw_line.lstrip(" ")
        if stripped.startswith("#"):
            continue
        lines.append((len(raw_line) - len(stripped), stripped.rstrip()))

    root: dict[str, Any] = {}
    stack: list[tuple[int, Any]] = [(-1, root)]
    for index, (indent, content) in enumerate(lines):
        while stack and indent <= stack[-1][0]:
            stack.pop()
        parent = stack[-1][1]
        next_indent = lines[index + 1][0] if index + 1 < len(lines) else -1
        next_content = lines[index + 1][1] if index + 1 < len(lines) else ""

        if content.startswith("- "):
            if not isinstance(parent, list):
                raise ValueError(f"List item found without list parent near: {content}")
            parent.append(parse_scalar(content[2:].strip()))
            continue

        key, separator, value_text = content.partition(":")
        if not separator:
            raise ValueError(f"Unsupported YAML line: {content}")
        key = key.strip()
        value_text = value_text.strip()
        if value_text:
            if not isinstance(parent, dict):
                raise ValueError(f"Key/value pair found without mapping parent near: {content}")
            parent[key] = parse_scalar(value_text)
            continue

        child: Any = [] if next_indent > indent and next_content.startswith("- ") else {}
        if not isinstance(parent, dict):
            raise ValueError(f"Nested mapping found without mapping parent near: {content}")
        parent[key] = child
        stack.append((indent, child))
    return root


def load_stack_config(path: Path | None = None) -> dict[str, Any]:
    stack_path = path or atlas_root() / "stack.yaml"
    text = stack_path.read_text(encoding="utf-8")
    try:
        import yaml  # type: ignore

        loaded = yaml.safe_load(text)
        if not isinstance(loaded, dict):
            raise ValueError("stack.yaml must deserialize to a mapping")
        return loaded
    except ModuleNotFoundError:
        return parse_simple_yaml(text)


def resolve_atlas_path(candidate: str | Path, root: Path | None = None) -> Path:
    value = Path(candidate)
    base = root or atlas_root()
    return value.resolve() if value.is_absolute() else (base / value).resolve()


def atlas_relative(candidate: str | Path, root: Path | None = None) -> str:
    resolved = resolve_atlas_path(candidate, root=root)
    base = (root or atlas_root()).resolve()
    try:
        return normalize_slashes(str(resolved.relative_to(base)))
    except ValueError:
        return normalize_slashes(str(resolved))


@dataclass(frozen=True)
class RepoEntry:
    repo_id: str
    path: str
    role: str
    status: str
    root: Path

    @property
    def atlas_path(self) -> str:
        return normalize_slashes(self.path)


def load_repo_registry(config: dict[str, Any] | None = None, root: Path | None = None) -> dict[str, RepoEntry]:
    base = (root or atlas_root()).resolve()
    data = config or load_stack_config(base / "stack.yaml")
    registry: dict[str, RepoEntry] = {}
    for repo_id, value in data.get("repo_registry", {}).items():
        if not isinstance(value, dict) or not isinstance(value.get("path"), str):
            continue
        registry[repo_id] = RepoEntry(
            repo_id=repo_id,
            path=normalize_slashes(value["path"]),
            role=str(value.get("role", "")),
            status=str(value.get("status", "unknown")),
            root=resolve_atlas_path(value["path"], root=base),
        )
    return registry


def repo_candidates_for_path(relative_path: str, registry: dict[str, RepoEntry]) -> list[RepoEntry]:
    normalized = normalize_slashes(relative_path).strip("/")
    candidates: list[RepoEntry] = []
    for entry in registry.values():
        repo_prefix = entry.atlas_path.strip("/")
        if repo_prefix in {"", "."}:
            candidates.append(entry)
            continue
        if normalized == repo_prefix or normalized.startswith(f"{repo_prefix}/"):
            candidates.append(entry)
    candidates.sort(key=lambda item: len(item.atlas_path), reverse=True)
    return candidates


def path_is_within(child: Path, parent: Path) -> bool:
    try:
        child.resolve().relative_to(parent.resolve())
        return True
    except ValueError:
        return False


def discover_git_root(path: Path) -> Path | None:
    try:
        completed = subprocess.run(
            ["git", "-C", str(path), "rev-parse", "--show-toplevel"],
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
    except OSError:
        return None
    if completed.returncode != 0:
        return None
    stdout = completed.stdout.strip()
    return Path(stdout).resolve() if stdout else None


def command_available(name: str) -> bool:
    paths = os.environ.get("PATH", "")
    if not paths:
        return False
    extensions = [""]
    if os.name == "nt":
        pathext = os.environ.get("PATHEXT", ".EXE;.CMD;.BAT;.COM")
        extensions = [item.lower() for item in pathext.split(";") if item]
    for directory in paths.split(os.pathsep):
        if not directory:
            continue
        candidate_base = Path(directory) / name
        if candidate_base.exists():
            return True
        for extension in extensions:
            if extension and candidate_base.with_suffix(extension).exists():
                return True
            if extension and Path(f"{candidate_base}{extension}").exists():
                return True
    return False
