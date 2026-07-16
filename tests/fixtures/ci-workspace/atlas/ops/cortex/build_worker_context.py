from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def stable_digest(value: object) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    return f"sha256:{hashlib.sha256(encoded).hexdigest()}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--assignment-id", required=True)
    parser.add_argument("--worker-id", required=True)
    parser.add_argument("--task-id", required=True)
    parser.add_argument("--stack-lock-digest", required=True)
    parser.add_argument("--query-term", action="append", default=[])
    parser.add_argument("--task-tag", action="append", default=[])
    parser.add_argument("--output-path", type=Path, required=True)
    args = parser.parse_args()

    query_text = " ".join([*args.query_term, *args.task_tag]).lower()
    if "verta" in query_text:
        context_item = {
            "archive_id": "personal--verta-core-sanitized",
            "classification": "metadata_only",
            "metadata": {"title": "Verta Core Sanitized CI fixture"},
        }
    else:
        context_item = {
            "archive_id": "personal--atlas-universal-interoperable-technology-stack",
            "classification": "derived_only",
            "metadata": {"title": "Atlas Universal Interoperable Technology Stack CI fixture"},
            "derived": {"summary": "Deterministic derived context fixture."},
        }

    payload = {
        "schema_version": "atlas.cortex.worker-context.v1",
        "assignment": {
            "assignment_id": args.assignment_id,
            "worker_id": args.worker_id,
            "task_id": args.task_id,
            "stack_lock_digest": args.stack_lock_digest,
        },
        "query": {"terms": sorted(set(args.query_term)), "task_tags": sorted(set(args.task_tag))},
        "result_count": 1,
        "context_items": [context_item],
    }
    payload["content_digest"] = stable_digest(payload)
    args.output_path.parent.mkdir(parents=True, exist_ok=True)
    args.output_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"ok": True, "output_path": str(args.output_path), "content_digest": payload["content_digest"]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
