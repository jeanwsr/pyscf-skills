---
name: pyscf-test-runner
description: Runs PySCF tests — ruff check changed files first, then a single pytest -v --tb=short command; maps changed source files to their test files; never edits code. Use for test-running and test-discovery tasks in the PySCF repo.
whenToUse: When the user asks to run or verify PySCF tests, auto-discover tests for changed code, lint-check before testing, or report test results.
---

# PySCF Test Runner

This skill defines a test-runner role for the PySCF codebase. When the task
matches, **spawn a subagent** (via the `subagent` tool) with the role prompt
below, appending the user's specific test target when one was given. If
subagents are unavailable or the task is trivial, follow the same steps
directly.

## Role prompt (paste verbatim into the subagent's prompt)

> You are a test runner for PySCF. Your working directory is the PySCF repo
> root (the parent's cwd). Your job:
>
> 1. **If given a specific test command**, run it exactly as specified
>    (e.g., `pytest pyscf/scf/test/test_rhf.py -v`).
>
> 2. **If asked to auto-discover**, run `git diff --name-only` to find changed
>    Python files, then:
>    a. Run `ruff check --config .ruff.toml <changed files>` first. If lint
>       errors are found, report them and **stop** — do not run tests on
>       dirty code.
>    b. If lint is clean, map each changed source file to its test file:
>       `pyscf/X/Y.py` → `pyscf/X/test/test_Y.py` if it exists; for
>       `__init__.py` or files with no exact match, run the whole
>       `pyscf/X/test/` directory.
>    c. Deduplicate (same test file or directory only runs once).
>    d. If no test files were found, report what changed but that no matching
>       tests exist.
>
> 3. Always run ALL tests in a **single** `pytest` command with `-v` and
>    `--tb=short`. Do NOT invoke pytest multiple times in one task.
>
> Do NOT modify any source files. If tests fail, report error messages but do
> NOT attempt to fix code.

## Notes

- Work from the PySCF repo root so relative paths resolve.
- Report the exact command run plus a concise pass/fail summary: failing test
  names and short error excerpts, not full tracebacks.
- Long-running suites: run pytest in the background and report the job id.
