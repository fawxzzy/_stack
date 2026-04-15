# Receipts

`receipts/` stores lightweight records for operator events triggered from `_stack`.

Current scope:
- verify events
- deploy events
- operator workflow events

Not in scope yet:
- automatic commit-triggered receipts
- general app/runtime logging
- repo implementation artifacts
- worker lifecycle artifacts; those stay in repo-local `.codex/logs/` and queue drops
