---
name: setup-dev-loop
description: Use ONCE, when working in {{PROJECT_ROOT}} (a story-tab-groups tracking-mode project) and main_workspace/dev_workspace/DESIGN.md/ROADMAP.md don't exist yet - retrofits the planning/brainstorming scaffolding a project added before that feature existed never got. Not for day-to-day story work - see the story-tab-groups skill for that.
---

# setup-dev-loop: {{PROJECT_ID}}

A brand-new tracking-mode project gets `main_workspace.code-workspace`, `dev_workspace.code-workspace`,
`DESIGN.md`, `ROADMAP.md` and two `.gitignore` entries automatically the moment it's added in Settings -
this skill exists only for `{{PROJECT_ID}}` (root `{{PROJECT_ROOT}}`), which was added **before** that
existed, so it may be missing some or all of them.

This is a **one-time bootstrap**, not something to run routinely - once `{{PROJECT_ROOT}}` has these six
pieces, there's nothing left for this skill to do, and re-running it is always a safe no-op (every file is
its own already-present check - see the script's own comment). Day-to-day story work (creating a story,
appending a work-log entry, advancing a ledger phase) is the **story-tab-groups** skill's job, not this
one - don't confuse the two.

## What to do

1. **Check first** - this writes nothing:
   ```
   {{TOOLS_DIR}}\setup-dev-loop.ps1 check -Project {{PROJECT_ID}} -Json
   ```
   Read the `missing` array. If it's empty, tell the human this project already has everything and stop -
   there's nothing to apply.

2. **Show the human what would be created**, in plain terms (which of `main_workspace.code-workspace` /
   `dev_workspace.code-workspace` / `DESIGN.md` / `ROADMAP.md` / the `.gitignore` entries / `stories.json`
   itself is missing), and get one explicit yes before doing anything - matching this project's own
   dev-cycle bootstrap convention (propose, one confirmation, then write), not an unattended write.

3. **Only after that confirmation**, create them:
   ```
   {{TOOLS_DIR}}\setup-dev-loop.ps1 apply -Project {{PROJECT_ID}} -Json
   ```
   Report back what `created` actually lists - if it's fewer items than `check` reported missing, say so
   rather than assuming everything landed.

**Every command above always exits 0** and carries the result in `ok`/`error` inside its JSON reply, not
the process exit code - check `ok`, not `$LASTEXITCODE`.

**If this project turns out to be worktree mode**, both actions refuse with a clear error instead of
doing anything - worktree mode has no `dev_workspace`/`DESIGN.md`/`ROADMAP.md`/`.gitignore`-entry concept
at all, and its own `main_workspace` regenerates on its own via the popup's "🧭 Open main workspace"
button (host action `openmain`), needing no bootstrap.

## After this runs

Point the human at the **story-tab-groups** skill (install it too, if it isn't installed for
`{{PROJECT_ID}}` yet - Settings' Agent integration card, or `{{TOOLS_DIR}}\install-agent-skill.ps1
install -Project {{PROJECT_ID}} -Scope user|project`) for the actual brainstorm-before-you-build
discipline this scaffolding supports - its "Planning discipline" section (tracking mode only) is where
`DESIGN.md`'s LOCKED/OPEN/REJECTED sections and `ROADMAP.md`'s per-story rows actually get used.
