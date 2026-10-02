---
format_version = 1
name = "TypeScript Best Practices"
version = "1.2.0"
description = "Enforce TypeScript conventions and patterns"
tags = ["typescript", "code-quality"]
scope = "user"

[adapters.claude-code]
target = "skill"

[adapters.cursor]
target = "mdc"
description = "TypeScript conventions"
globs = ["**/*.ts", "**/*.tsx"]
always_apply = false

[adapters.codex]
target = "agents"
---

# TypeScript Best Practices

Always use strict mode. Prefer `const` over `let`. Never use `any` unless absolutely necessary.
