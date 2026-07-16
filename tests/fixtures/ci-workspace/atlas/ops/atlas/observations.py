from __future__ import annotations

import argparse
import hashlib
import json


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    emit = subparsers.add_parser("emit")
    emit.add_argument("--root", required=True)
    emit.add_argument("--owner", required=True)
    emit.add_argument("--observation-type", required=True)
    emit.add_argument("--source-kind", required=True)
    emit.add_argument("--status", required=True)
    emit.add_argument("--source-ref", required=True)
    emit.add_argument("--details-json", required=True)
    emit.add_argument("--observed-at")
    emit.add_argument("--scope-ref")
    args = parser.parse_args()

    details = json.loads(args.details_json)
    identity = json.dumps(
        {
            "owner": args.owner,
            "observation_type": args.observation_type,
            "source_kind": args.source_kind,
            "status": args.status,
            "source_ref": args.source_ref,
            "scope_ref": args.scope_ref,
            "details": details,
        },
        sort_keys=True,
        separators=(",", ":"),
    )
    result = {
        "contract_version": "atlas.observation.v1",
        "observation_id": f"stack-ci-fixture-{hashlib.sha256(identity.encode('utf-8')).hexdigest()[:24]}",
        "owner": args.owner,
        "observation_type": args.observation_type,
        "source_kind": args.source_kind,
        "status": args.status,
        "source_ref": args.source_ref,
        "scope_ref": args.scope_ref,
        "observed_at": args.observed_at,
        "details": details,
        "fixture_mode": "github_actions_versioned_fixture",
    }
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
