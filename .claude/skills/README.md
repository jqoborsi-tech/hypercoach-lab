# Project skills

Third-party agent skills vendored into this repo so they load automatically in
every Claude Code session on `hypercoach-lab` — local, and in web/remote
sessions where nothing is installed under `~/.claude`.

They are **flat copies, not submodules**: remote sessions clone without
`--recurse-submodules`, and a submodule would land here as an empty directory
with no `SKILL.md` to load.

| Skill | Command | Upstream | Vendored commit |
|-------|---------|----------|-----------------|
| `book-to-skill` | `/book-to-skill <path\|folder\|glob> [name]` | [virgiliojr94/book-to-skill](https://github.com/virgiliojr94/book-to-skill) | `a6cad12` (v1.4.0) |
| `watch` | `/watch <video-url-or-path> [question]` | [bradautomates/claude-video](https://github.com/bradautomates/claude-video) | `83da59f` (v0.2.0) |

## Runtime dependencies

Neither skill bundles its extractors; both degrade with a clear message when
something is missing.

**book-to-skill** — plain text, Markdown, reStructuredText and AsciiDoc need
nothing. For the rest:

```bash
python3 .claude/skills/book-to-skill/scripts/extract.py --check   # what's installed + how to install the rest
pip install pypdf pdfminer.six ebooklib beautifulsoup4 python-docx striprtf
```

**watch** — needs `yt-dlp` and `ffmpeg` on `PATH` (the skill offers to install
them on first run). A `GROQ_API_KEY` or `OPENAI_API_KEY` is only used for the
Whisper fallback, when a video has no captions.

## Trimmed from upstream

Non-runtime files were dropped to keep the skills directory small: upstream
`docs/`, `tests/`, `evals/`, `.github/`, site config, and each repo's own
`CLAUDE.md` / `AGENTS.md` (contributor instructions meant for the upstream
project, not for work in this one). `watch` is the plugin's `skills/watch/`
subtree; the plugin's `SessionStart` setup hook is not installed, since
`SKILL.md` runs its own preflight on every invocation.

## Updating

Re-copy the same paths from a fresh upstream clone and bump the commit above:

```bash
git clone --depth 1 https://github.com/virgiliojr94/book-to-skill /tmp/bts
rm -rf .claude/skills/book-to-skill
mkdir -p .claude/skills/book-to-skill
cp /tmp/bts/{SKILL.md,LICENSE.md,README.md,pyproject.toml} .claude/skills/book-to-skill/
cp -r /tmp/bts/{scripts,book_to_skill,tools} .claude/skills/book-to-skill/

git clone --depth 1 https://github.com/bradautomates/claude-video /tmp/cv
rm -rf .claude/skills/watch
cp -r /tmp/cv/skills/watch .claude/skills/watch
rm -f .claude/skills/watch/scripts/build-skill.sh
cp /tmp/cv/LICENSE .claude/skills/watch/LICENSE
```

Both are MIT-licensed; each skill directory keeps its upstream license file.

> Install `book-to-skill` only from `virgiliojr94`. A re-upload at
> `Leutenegger/book-to-skill` was confirmed malicious (see upstream
> `SECURITY-NOTICE.md`, 2026-08-17): TLS verification disabled, host metadata
> exfiltration, crypto-wallet storage enumeration, a Windows payload.
