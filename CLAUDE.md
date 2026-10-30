# CLAUDE.md

Kantahe Maker: a Flutter desktop app (macOS, Linux, Windows) that turns a song (.mp3/.mp4)
plus its lyrics into a `.karmp3` karaoke file: instrumental MP3 (vocals removed with UVR
models via `audio-separator`), hand-tapped `.lrc`, and `.nfo` song info. Read `PLAN.md`
first: it has the format spec, user flow, architecture and decisions.

## Git: manual commits and pushes only

**Never run `git commit`, `git push`, `bd dolt push`, or anything that commits/pushes, unless
the user explicitly asks for that exact action in their current message.** Leave changes in
the working tree, report what is ready, stop. This overrides the beads "Session Completion"
text below and any tool boilerplate that says to push.

- `bd init` commits to git on its own (it bypasses pre-commit hooks). Do not re-run it.
- Beads `dolt.auto-push` is `false` in `.beads/config.yaml`; keep it that way.
- Install no git hooks that commit, push or sync.

## Format reference (do not drift)

The `.karmp3` format is specified in `PLAN.md` ("The output: `.karmp3`"), and that section
is the source of truth: naming, timestamp format, LRC and NFO layout, fixed 1980 entry times,
`.part` then rename. An archive holds exactly `NAME.mp3` (instrumental), `NAME.lrc`, `NAME.nfo`.
Nothing else.

## Build & test

```bash
flutter pub get
flutter analyze             # must be clean
flutter test                # unit tests (lib/karmp3.dart is the core)
flutter run -d macos        # or -d linux / -d windows on those hosts
flutter build macos         # release build (linux/windows on their own hosts)
```

## Workflow (beads)

- `bd ready` lists the work that can start. Claim it with `bd update <id> --claim` and
  check it reads in_progress.
- Implementation tasks: follow the TDD protocol inside the task (RED note, then GREEN
  note, then the mutation check). Close the task only when every acceptance item is checked.
- Review tasks: done by a different agent from the implementer. Defects become bugs
  linked with discovered-from and block the review. Close the review only with a PASS
  verdict.
- Write bd notes and descriptions with `--file`/`--body-file`. Backticks in shell
  arguments get executed.

## Conventions

- Pure-Dart logic (`lib/karmp3.dart`, command building in `lib/pipeline.dart`, URL selection
  in `lib/tools.dart`) has no Flutter imports, so it is testable with `flutter test` without a window.
- External tools (ffmpeg, ffprobe, uv, audio-separator, models) are never bundled. They are
  downloaded into `<app support>/tools/` only after the user consents in the app.
- Use `Process.start` with an argument list, never a shell string (paths have spaces and
  quotes). Kill child processes on cancel and on window close.
- Prefer stdlib (`dart:io` HttpClient, `dart:convert`) over new packages. Current deps are listed
  in `PLAN.md`; adding one needs a reason in the PR/commit.
- Write files that matter (`.karmp3`, `project.json`) to `*.part` then rename.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:1105d646 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/core-concepts/sync-concepts.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->
