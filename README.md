# HouseWorks Agent Skills

[![skills.sh](https://skills.sh/b/houseworksinc/skills)](https://skills.sh/houseworksinc/skills)

Internal Coding Agent skills for the HouseWorks engineering team.

## Install

```bash
npx skills add houseworksinc/skills
```

> Requires Node.js and access to this repo.

## Available Skills

| Skill | What it does |
|---|---|
| `rca-writer` | Generates a structured post-mortem `.md` from your Claude Code / Codex session, git diffs, or log snippets — following the HouseWorks incident template. Creates and links Linear tickets tagged `incident`. |

## Usage

Once installed, just describe what you want inside Claude Code:

```
write up the incident
```
```
let's do the post-mortem for INC-091
```
```
generate the RCA from this session
```

Claude will ask for metadata it can't infer (Incident ID, Sev, IST timestamps), enforce a strong root cause standard, infer action items, optionally create Linear tickets, and output a ready-to-share `.md` file.

## Repo structure

```
skills/
  rca-writer/
    SKILL.md
```

## Adding more skills

Drop a new folder under `skills/` with a `SKILL.md` and it's automatically available on the next `npx skills add`.

---

Maintained by the HouseWorks platform engineering team.