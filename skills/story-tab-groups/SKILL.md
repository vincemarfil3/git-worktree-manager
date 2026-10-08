---
name: story-tab-groups
description: Use when working in {{PROJECT_ROOT}} and asked to list, create, or update a tracked story (list stories, create one, append a work-log entry, advance a phase, mark released) - this repo's story registry is tracked by the story-tab-groups browser extension, not by hand-editing files.
---

# story-tab-groups: {{PROJECT_ID}}

This repo ({{PROJECT_ROOT}}) is tracked by the story-tab-groups extension as project
`{{PROJECT_ID}}`. Its story registry, per-story doc and per-story ledger live at
`{{PROJECT_ROOT}}\.claude\stories\`, read live by the extension's popup - anything
written through the commands below shows up there on the next popup open, with
nothing else to click.

Drive it through `{{TOOLS_DIR}}\switch-story.ps1` / `{{TOOLS_DIR}}\story-ledger.ps1` /
`{{TOOLS_DIR}}\story-release.ps1` - never hand-edit `stories.json` or a `.story-ship-state.json`
file directly, for the same reason you wouldn't hand-edit a database another program owns:
these scripts hold a file lock during writes and validate shapes these tools also read.

**Every command below always exits 0** and carries the result in `ok`/`error` inside its JSON
reply, not the process exit code - check `ok`, not `$LASTEXITCODE`. Always pass `-Json`, or a
script that needs setup it doesn't have may `Write-Error` and exit 1 instead of replying cleanly.

## Workspaces

<!-- MODE:worktree -->
- **`main_workspace.code-workspace`** (`{{PROJECT_ROOT}}\<workspace dir>\main_workspace.code-workspace` -
  regenerated fresh every time it's opened, so it always reflects whichever apps are actually
  cloned right now) - every home-base app clone, no story attached. For planning/brainstorming
  before a story exists or between stories - never make a code change while working from it if a
  story-scoped alternative is available.
<!-- /MODE:worktree -->
<!-- MODE:tracking -->
- **`main_workspace.code-workspace`** (`{{PROJECT_ROOT}}\main_workspace.code-workspace`, written
  once at project-add time) - the **whole project folder** (`path: "."`), since planning needs
  DESIGN.md/ROADMAP.md, which live at the root. For planning/brainstorming before a story exists
  or between stories - never make a code change while working from it if a story-scoped
  alternative is available.
<!-- /MODE:tracking -->
<!-- MODE:tracking -->
- **`dev_workspace.code-workspace`** (`{{PROJECT_ROOT}}\dev_workspace.code-workspace`) - **only the
  actual git repos** under the project root (e.g. `workout-tracker-service`,
  `workout-tracker-ui`), never the project folder itself - so DESIGN.md/ROADMAP.md/stories.json/
  `.claude\` don't show up in the window you write code from. Regenerated fresh every time it's
  opened from the popup's **🛠 Dev workspace** button (same "always current" reasoning as worktree
  mode's `main_workspace`), so a newly-cloned repo shows up the very next open. There is no way for
  a session to introspect which literal file launched it, so the REAL gate you follow is the
  ledger's `plan` phase (below), never which workspace happens to be open.
<!-- /MODE:tracking -->

## Commands

Every one of these takes `-Project {{PROJECT_ID}}` - never omit it. With no `-Project`, these
scripts fall back to whichever project is currently active in the extension's popup, which may
not be this one.

**List stories**
```
{{TOOLS_DIR}}\switch-story.ps1 list -Project {{PROJECT_ID}} -Json
```

<!-- MODE:tracking -->
**Create a story** (env/apps are optional here - this project tracks stories, it doesn't cut
git worktrees). Don't run this straight from a request - see "Planning discipline" below first;
a story should only get created once its brainstorm topic is LOCKED in `DESIGN.md`.
```
{{TOOLS_DIR}}\switch-story.ps1 new <KEY> -Project {{PROJECT_ID}} [-Title "..."] [-JiraUrl "..."] -Json
```
`<KEY>` must look like `ABC-123` or `some-slug-name`.
<!-- /MODE:tracking -->
<!-- MODE:worktree -->
**Create a story** (cuts a real git worktree per app - `<env>` and `<apps>` are required)
```
{{TOOLS_DIR}}\switch-story.ps1 new <KEY> <env> <apps> -Project {{PROJECT_ID}} [-Title "..."] [-JiraUrl "..."] [-Branch "..."] -Json
```
`<KEY>` must look like `ABC-123` or `some-slug-name`; `<apps>` is a comma-separated list of app
names already cloned under this project's root. This project's tickets arrive pre-planned (e.g.
from Jira), so there's no brainstorm-first gate here the way there is in a tracking-mode project -
create the story once you have a key, env and app list.
<!-- /MODE:worktree -->

**Append a work-log entry** (plain text - this handles the encoding, don't call
`story-doc.ps1 append` directly, it only accepts base64)
```
{{TOOLS_DIR}}\switch-story.ps1 note <KEY> "what happened" -Project {{PROJECT_ID}}
```

**Where am I on this story / resume pointer** (read this before assuming a story hasn't been
started - don't restart from scratch on a story that already has progress)
```
{{TOOLS_DIR}}\story-ledger.ps1 next -Story <KEY> -Project {{PROJECT_ID}} -Json
```

**Start / finish a phase**
```
{{TOOLS_DIR}}\story-ledger.ps1 start <phase> -Story <KEY> -Project {{PROJECT_ID}} -Json
{{TOOLS_DIR}}\story-ledger.ps1 done  <phase> -Story <KEY> -Project {{PROJECT_ID}} -Json
```
Phases are always exactly these 8, in this order - never a different name, never a subset:
`bring-up, plan, implement, testplan, verify, typecheck, commit-push, deploy`
<!-- MODE:tracking -->
Don't mark `plan` done from a request alone - see "Planning discipline" below for what actually
has to be true first.
<!-- /MODE:tracking -->

**Record a blocker on a phase** (instead of leaving it silently stuck at "running")
```
{{TOOLS_DIR}}\story-ledger.ps1 fail <phase> -Story <KEY> -Message "what's blocking it" -Project {{PROJECT_ID}} -Json
```

**Mark released** (ships the story without deleting anything - the tool's own "done" state)
```
{{TOOLS_DIR}}\story-release.ps1 release -Story <KEY> -Project {{PROJECT_ID}} -Json
```

**Where the docs actually live on disk**, if you need to read one directly:
`{{PROJECT_ROOT}}\.claude\stories\<KEY>.md`

<!-- MODE:tracking -->
## Planning discipline: brainstorm before you build

This project has no worktree to physically separate "just talking" from "writing code" -
`main_workspace` (the whole project folder, for planning) and `dev_workspace` (just the git repos,
for implementation) are two different windows onto the same repos, not a real isolation boundary.
The real gate is the ledger's `plan` phase, and it means more here than a checkbox: **don't mark
`plan` done, and don't start
`implement`, until a real design conversation actually happened and produced the artifacts
below.** "The developer said build X" is a request, not a plan - if you catch yourself about to
create a story and start coding in the same breath, stop and hold the brainstorm first.

**Brainstorm a topic first.** Before creating a story for a new chunk of work, have a real
back-and-forth about it - ask questions, surface trade-offs and alternatives, push back on
anything that contradicts an already-LOCKED decision rather than silently overriding it. Track it
in `{{PROJECT_ROOT}}\DESIGN.md` (created empty when this project was added) under three headings
per topic:
- **`## LOCKED`** - decisions that are actually settled. Once something is here, don't
  contradict it in a later session without flagging that to the human first.
- **`## OPEN`** - still being decided; the open questions to resolve before implementation starts.
- **`## REJECTED`** - considered and explicitly ruled out, with a one-line reason, so it doesn't
  get silently re-proposed and re-litigated next session.

**Only once a topic is LOCKED**, turn it into a story (the `new` command above), then seed its
existing per-story `.md` doc - the same file `note` above appends work-log entries into - with the
locked shape, via one `note` call:
- `## Context` - what this story is and why
- `## Locked decisions` - pulled straight from DESIGN.md's LOCKED section for this topic
- `## Acceptance criteria` - a table, one row per criterion, every row starting unmet:
  `| # | Criterion | Met? |` / `|---|---|---|` / `| 1 | ... | no |`
- `## Out of scope` - what this story deliberately does NOT cover

This is one artifact per story, not a separate plan/development/testing split - the same doc keeps
accumulating ordinary work-log entries underneath this seeded section as implementation proceeds.

**Track sequencing** in `{{PROJECT_ROOT}}\ROADMAP.md` (also created empty at project-add time) -
one row per story, its status, and any ordering notes ("do X before Y because..."). Update it on
real status changes, not on every ledger phase tick.

**Where these live**: `DESIGN.md` and `ROADMAP.md` sit at the project root, next to `.gitignore` -
deliberately outside `.claude\stories\`, per an explicit ask that planning docs not be buried
inside app/repo internals. Both are meant to be committed to git, same as `stories.json` and each
story's own `.md` doc - only the live per-story ledger (`.claude\stories\<KEY>.story-ship-state.json`)
and its lock file stay gitignored (set up automatically when this project was added).
<!-- /MODE:tracking -->

## If this repo also runs dev-cycle

Check for `{{PROJECT_ROOT}}\.claude\dev-cycle.json`. If it's there, dev-cycle is the system of
record for this repo's phase state - keep following dev-cycle's own rules exactly as normal.
Best-effort, in addition to that (never instead of it): after a dev-cycle phase transition, also
call the mapped `story-ledger.ps1 done <phase>` below, so the same progress shows up as a phase
chip in the extension's popup. Skip a step if the mapping doesn't clearly apply - dev-cycle has
failure-routing, backward moves, an abandon path and an express lane that don't map 1:1, and
getting this mirror wrong costs nothing since dev-cycle's own state stays authoritative either way.

| dev-cycle phase | ledger phase |
|---|---|
| 0 branch, 1 scope, 2 requirements, 3 design | `plan` |
| 4 implement | `implement` |
| 5 automated test | `testplan` |
| 6 manual test | `verify` |
| 7 requirements gate | *(no mirror - skip)* |
| 8 commit | `commit-push` |

`deploy` has no dev-cycle equivalent (dev-cycle stops at commit) - only ever set it via
`story-release.ps1 release` above, when the story actually ships.
