from __future__ import annotations

import argparse
import hashlib
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any
import fnmatch

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from ops._atlas import atlas_root, normalize_slashes, resolve_atlas_path

WORKER_ASSIGNMENT_VERSION = "atlas.worker.assignment.v1"
WORKER_STATUS_VERSION = "atlas.worker.status.v1"
WORKER_MERGE_REQUEST_VERSION = "atlas.worker.merge-request.v1"
ACTIVE_STATES = {"assigned", "running", "paused", "blocked", "merge_wait", "completed", "failed"}


@dataclass
class ArtifactRecord:
    path: Path
    payload: dict[str, Any]


def stable_digest(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def current_stack_lock_digest(root: Path) -> str:
    stack_lock_path = root / "stack.lock.yaml"
    text = stack_lock_path.read_text(encoding="utf-8")
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if line.startswith("lock_digest:"):
            return line.split(":", 1)[1].strip().strip('"')
    raise ValueError("stack.lock.yaml does not declare lock_digest.")


def collect_json_paths(paths: list[Path]) -> list[Path]:
    results: list[Path] = []
    for path in paths:
        if path.is_file() and path.suffix.lower() == ".json":
            results.append(path)
            continue
        if not path.exists():
            continue
        for candidate in sorted(path.rglob("*.json")):
            results.append(candidate)
    seen: set[Path] = set()
    ordered: list[Path] = []
    for item in results:
        resolved = item.resolve()
        if resolved not in seen:
            seen.add(resolved)
            ordered.append(resolved)
    return ordered


def load_artifacts(paths: list[Path]) -> tuple[dict[str, ArtifactRecord], list[ArtifactRecord]]:
    assignments: dict[str, ArtifactRecord] = {}
    statuses: list[ArtifactRecord] = []
    for path in collect_json_paths(paths):
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            continue
        if not isinstance(payload, dict):
            continue
        contract_version = str(payload.get("contract_version", ""))
        if contract_version == WORKER_ASSIGNMENT_VERSION and isinstance(payload.get("assignment_id"), str):
            assignments[str(payload["assignment_id"])] = ArtifactRecord(path=path, payload=payload)
        elif contract_version == WORKER_STATUS_VERSION:
            statuses.append(ArtifactRecord(path=path, payload=payload))
    return assignments, statuses


def path_matches_any(path: str, patterns: list[str]) -> bool:
    normalized = normalize_slashes(path)
    return any(fnmatch.fnmatch(normalized, pattern) for pattern in patterns)


def validate_assignment(payload: dict[str, Any], expected_lock_digest: str) -> list[str]:
    errors: list[str] = []
    if payload.get("contract_version") != WORKER_ASSIGNMENT_VERSION:
        errors.append(f"assignment contract_version must be '{WORKER_ASSIGNMENT_VERSION}'")
    if payload.get("stack_lock_digest") != expected_lock_digest:
        errors.append("assignment stack_lock_digest does not match the current root lock digest")
    return errors


def validate_status(payload: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if payload.get("contract_version") != WORKER_STATUS_VERSION:
        errors.append(f"status contract_version must be '{WORKER_STATUS_VERSION}'")
    if payload.get("state") not in ACTIVE_STATES:
        errors.append("status state is not in the supported observation set")
    if not isinstance(payload.get("touched_ranges"), list):
        errors.append("status touched_ranges must be an array")
    return errors


def ranges_overlap(left: dict[str, Any], right: dict[str, Any]) -> bool:
    return not (int(left["end_line"]) < int(right["start_line"]) or int(right["end_line"]) < int(left["start_line"]))


def derive_paused_handoff_refs(status: dict[str, Any], assignment: dict[str, Any]) -> list[str]:
    refs = [str(item) for item in status.get("output_refs", []) if isinstance(item, str) and item.strip()]
    if refs:
        return refs
    return [str(item) for item in assignment.get("input_handoff_refs", []) if isinstance(item, str) and item.strip()]


def merge_request_for_conflict(
    *,
    lock_digest: str,
    left_status: dict[str, Any],
    left_assignment: dict[str, Any],
    right_status: dict[str, Any],
    right_assignment: dict[str, Any],
    overlaps: list[dict[str, Any]],
) -> dict[str, Any]:
    worker_ids = sorted({str(left_status["worker_id"]), str(right_status["worker_id"])})
    merge_request_id = f"merge-request-{stable_digest([lock_digest, worker_ids, overlaps])[:16]}"
    paused_handoffs = sorted({
        *derive_paused_handoff_refs(left_status, left_assignment),
        *derive_paused_handoff_refs(right_status, right_assignment),
    })
    tool_id = str(
        left_status.get("tool_id")
        or left_assignment.get("tool_id")
        or right_status.get("tool_id")
        or right_assignment.get("tool_id")
        or ""
    ).strip()
    extension_id = left_status.get("extension_id")
    if extension_id is None:
        extension_id = left_assignment.get("extension_id")
    if extension_id is None:
        extension_id = right_status.get("extension_id")
    if extension_id is None:
        extension_id = right_assignment.get("extension_id")
    registry_digest = str(
        left_status.get("registry_digest")
        or left_assignment.get("registry_digest")
        or right_status.get("registry_digest")
        or right_assignment.get("registry_digest")
        or ""
    ).strip()
    return {
        "contract_version": WORKER_MERGE_REQUEST_VERSION,
        "merge_request_id": merge_request_id,
        "stack_lock_digest": lock_digest,
        "tool_id": tool_id,
        "extension_id": extension_id,
        "registry_digest": registry_digest,
        "conflicting_workers": worker_ids,
        "overlaps": overlaps,
        "paused_handoff_refs": paused_handoffs,
        "merge_worker_handoff": {
            "worker_id": "pending-merge-worker",
            "assignment_id": f"assignment-{merge_request_id}",
            "task_id": f"merge-{merge_request_id}",
            "handoff_ref": f"runtime/cortex/supervisor/{merge_request_id}.merge-handoff.json",
            "tool_id": tool_id,
            "extension_id": extension_id,
            "registry_digest": registry_digest,
        },
        "notes": "Read-only Cortex supervisor emitted this merge request from worker status and assignment artifacts only.",
    }


def supervise(assignments: dict[str, ArtifactRecord], statuses: list[ArtifactRecord], *, lock_digest: str) -> dict[str, Any]:
    invalid_statuses: list[dict[str, Any]] = []
    forbidden_scope_violations: list[dict[str, Any]] = []
    valid_statuses: list[tuple[ArtifactRecord, ArtifactRecord]] = []

    for status_record in statuses:
        status = status_record.payload
        assignment_id = str(status.get("assignment_id", ""))
        errors = validate_status(status)
        assignment_record = assignments.get(assignment_id)
        if assignment_record is None:
            errors.append("matching assignment artifact is missing")
        else:
            errors.extend(validate_assignment(assignment_record.payload, lock_digest))
        if errors:
            invalid_statuses.append({
                "path": normalize_slashes(str(status_record.path)),
                "worker_id": status.get("worker_id"),
                "assignment_id": assignment_id,
                "errors": errors,
            })
            continue
        assert assignment_record is not None
        assignment = assignment_record.payload
        forbidden_globs = [str(item) for item in assignment.get("forbidden_globs", []) if isinstance(item, str)]
        for touched_range in status.get("touched_ranges", []):
            if not isinstance(touched_range, dict):
                continue
            if path_matches_any(str(touched_range.get("path", "")), forbidden_globs):
                forbidden_scope_violations.append({
                    "worker_id": status.get("worker_id"),
                    "assignment_id": assignment_id,
                    "path": touched_range.get("path"),
                    "forbidden_globs": forbidden_globs,
                    "status_path": normalize_slashes(str(status_record.path)),
                })
        valid_statuses.append((status_record, assignment_record))

    merge_requests: list[dict[str, Any]] = []
    emitted_pairs: set[tuple[str, str]] = set()
    for index, (left_status_record, left_assignment_record) in enumerate(valid_statuses):
        left_status = left_status_record.payload
        left_assignment = left_assignment_record.payload
        for right_status_record, right_assignment_record in valid_statuses[index + 1:]:
            right_status = right_status_record.payload
            right_assignment = right_assignment_record.payload
            worker_pair = tuple(sorted({str(left_status["worker_id"]), str(right_status["worker_id"])}))
            overlaps: list[dict[str, Any]] = []
            for left_range in left_status.get("touched_ranges", []):
                if not isinstance(left_range, dict):
                    continue
                for right_range in right_status.get("touched_ranges", []):
                    if not isinstance(right_range, dict):
                        continue
                    if normalize_slashes(str(left_range.get("repo_path", ""))) != normalize_slashes(str(right_range.get("repo_path", ""))):
                        continue
                    if normalize_slashes(str(left_range.get("path", ""))) != normalize_slashes(str(right_range.get("path", ""))):
                        continue
                    if str(left_range.get("file_digest_before", "")) != str(right_range.get("file_digest_before", "")):
                        overlaps.append({
                            "repo_path": normalize_slashes(str(left_range.get("repo_path", ""))),
                            "path": normalize_slashes(str(left_range.get("path", ""))),
                            "overlap_type": "file_digest_drift",
                            "file_digest_before": str(left_range.get("file_digest_before", "")),
                            "conflicting_ranges": [
                                {
                                    "worker_id": str(left_status.get("worker_id", "")),
                                    "start_line": int(left_range.get("start_line", 1)),
                                    "end_line": int(left_range.get("end_line", 1)),
                                    "op": str(left_range.get("op", "")),
                                },
                                {
                                    "worker_id": str(right_status.get("worker_id", "")),
                                    "start_line": int(right_range.get("start_line", 1)),
                                    "end_line": int(right_range.get("end_line", 1)),
                                    "op": str(right_range.get("op", "")),
                                },
                            ],
                            "reason": "Same file path observed with different file_digest_before values.",
                        })
                        continue
                    if ranges_overlap(left_range, right_range):
                        overlaps.append({
                            "repo_path": normalize_slashes(str(left_range.get("repo_path", ""))),
                            "path": normalize_slashes(str(left_range.get("path", ""))),
                            "overlap_type": "line_overlap",
                            "file_digest_before": str(left_range.get("file_digest_before", "")),
                            "conflicting_ranges": [
                                {
                                    "worker_id": str(left_status.get("worker_id", "")),
                                    "start_line": int(left_range.get("start_line", 1)),
                                    "end_line": int(left_range.get("end_line", 1)),
                                    "op": str(left_range.get("op", "")),
                                },
                                {
                                    "worker_id": str(right_status.get("worker_id", "")),
                                    "start_line": int(right_range.get("start_line", 1)),
                                    "end_line": int(right_range.get("end_line", 1)),
                                    "op": str(right_range.get("op", "")),
                                },
                            ],
                            "reason": "Same file, overlapping line ranges, same file_digest_before.",
                        })
            if overlaps and worker_pair not in emitted_pairs:
                merge_requests.append(
                    merge_request_for_conflict(
                        lock_digest=lock_digest,
                        left_status=left_status,
                        left_assignment=left_assignment,
                        right_status=right_status,
                        right_assignment=right_assignment,
                        overlaps=overlaps,
                    )
                )
                emitted_pairs.add(worker_pair)

    return {
        "schema_version": "atlas.cortex.supervisor.report.v1",
        "stack_lock_digest": lock_digest,
        "status_count": len(statuses),
        "valid_status_count": len(valid_statuses),
        "invalid_statuses": invalid_statuses,
        "forbidden_scope_violations": forbidden_scope_violations,
        "merge_requests": merge_requests,
    }


def write_merge_requests(merge_requests: list[dict[str, Any]], output_dir: Path) -> list[str]:
    output_dir.mkdir(parents=True, exist_ok=True)
    written: list[str] = []
    for merge_request in merge_requests:
        path = output_dir / f"{merge_request['merge_request_id']}.json"
        path.write_text(json.dumps(merge_request, indent=2) + "\n", encoding="utf-8")
        written.append(normalize_slashes(str(path)))
    return written


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Read-only Cortex supervisor for worker status artifacts. Detects conflicts and emits merge-request artifacts."
    )
    parser.add_argument("--artifact-path", action="append", dest="artifact_paths")
    parser.add_argument("--output-dir", default="runtime/cortex/supervisor")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    root = atlas_root()
    artifact_paths = (
        [resolve_atlas_path(item, root=root) for item in args.artifact_paths]
        if args.artifact_paths
        else [resolve_atlas_path("repos/_stack/docs/examples/stack-worker-artifacts", root=root)]
    )
    assignments, statuses = load_artifacts(artifact_paths)
    lock_digest = current_stack_lock_digest(root)
    report = supervise(assignments, statuses, lock_digest=lock_digest)
    if not args.dry_run:
        output_dir = resolve_atlas_path(args.output_dir, root=root)
        written = write_merge_requests(report["merge_requests"], output_dir)
        report["written_merge_request_paths"] = written
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
