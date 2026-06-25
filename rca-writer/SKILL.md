---
name: rca-writer
description: >
  Generates a complete, structured Post-Mortem / RCA (Root Cause Analysis) document as a downloadable
  Markdown file, using the HouseWorks incident post-mortem template. Use this skill whenever the user
  mentions writing a post-mortem, RCA, incident report, or retrospective after fixing a production issue.
  Also trigger when the user says things like "write up the incident", "document what happened", "let's
  do the post-mortem", or "generate the RCA". Works from any combination of: Claude Code / Codex
  conversation history, git diffs, log snippets, or a freeform incident summary typed by the user.
  Always trigger this skill — do not attempt to write the RCA freehand without it.
---

# RCA Writer

Generates a structured, honest Post-Mortem document following the HouseWorks incident template.

---

## Workflow

### Step 1 — Gather metadata upfront (always ask these before writing)

Ask the user for the following fields in a single message — do not proceed to writing until you have them:

```
1. Incident ID (e.g., INC-042)
2. Severity (Sev 1 / 2 / 3 / 4)
3. Date of incident (YYYY-MM-DD)
4. Author name
5. Attendees (if a post-mortem meeting was held; else "N/A")
6. Timeline timestamps in IST — ask for the key moments:
   - When the alert fired or first customer report came in
   - When on-call acknowledged
   - When root cause was identified
   - When fix was applied / service restored
   - When incident was resolved in All Quiet
```

Frame it naturally: *"Before I write the RCA, I need a few fields I can't infer from the technical context..."*

If the user provides partial answers (e.g., "I'll fill author later"), accept what they give and use `[FILL: <field>]` placeholders for the rest.

---

### Step 2 — Synthesize technical context

From the available inputs (conversation history, git diffs, log snippets, freeform summary), extract:

- **What broke** — the system, service, or component
- **How it was detected** — alert, customer report, monitoring
- **What the investigation path looked like** — commands run, hypotheses tested, red herrings
- **What the actual fix was** — code change, config change, rollback
- **User impact** — who was affected, for how long, what they experienced

Use this to populate: Summary, Timeline (sequence), Root Cause, What Went Well, What Went Poorly, Where We Got Lucky.

---

### Step 3 — Root Cause quality gate (enforce this)

The Root Cause section has a strong standard: **not "human error"** — it must name the underlying system condition that made the failure possible.

Examples of weak root causes to reject:
- "Developer forgot to add validation"
- "Config was wrong"
- "Someone deployed without testing"

Examples of strong root causes to push for:
- "The deploy pipeline lacked a schema validation gate, so a breaking migration could reach production without pre-flight checks"
- "The feature flag service had no circuit breaker — when it degraded, all flag evaluations blocked synchronously, cascading into request timeouts"

**If the input is shallow:** ask one targeted follow-up before writing the root cause section:
> *"The root cause draft reads as human error. What was the system condition or missing safeguard that made this possible? E.g., missing validation, no circuit breaker, no alerting on X."*

Wait for the answer, then write.

---

### Step 4 — Generate Action Items + Linear tickets

From the fix and the root cause, infer at least 2–3 concrete action items. Each should be:
- Specific (not "improve monitoring" — "add P95 latency alert on `/api/orders` endpoint")
- Assigned to a role if the owner isn't named (use `[FILL: owner]`)
- Prioritized (High if it directly prevents recurrence, Med/Low otherwise)

**Then ask the user:**
> *"Should I create Linear tickets for these action items? I'll tag each one with `incident` and link them in the RCA."*

**If yes — create Linear tickets:**
- Use the Linear MCP tool (requires Linear to be connected in Claude.ai / Claude Code)
- For each action item, create one ticket with:
  - **Title:** the action item text
  - **Label / tag:** `incident`
  - **Priority:** map High → Urgent, Med → Medium, Low → Low
  - **Description:** include the Incident ID for traceability (e.g., *"Follow-up from INC-042 post-mortem"*)
- Capture the returned ticket URL for each
- Add a `Ticket` column to the Action Items table: `| Action | Owner | Due Date | Priority | Ticket |`
- Insert the Linear URL as a Markdown link: `[ENG-123](https://linear.app/...)`

**If Linear is not connected:**
- Inform the user: *"Linear isn't connected — add it via the tools menu in Claude.ai to enable ticket creation. I'll leave a `[FILL: ticket]` placeholder in the table."*
- Use `[FILL: ticket]` in the Ticket column and proceed to write the file

**If user says no:**
- Omit the Ticket column entirely from the Action Items table

---

### Step 5 — Write the .md file

Use the exact template structure below. Output as a `.md` file saved to `/mnt/user-data/outputs/INC-XXX-postmortem.md` (use the actual incident ID in the filename).

Then call `present_files` to surface it to the user.

---

## Template

```markdown
## Post-Mortem: <Incident Title>

**Incident ID:** INC-XXX
**Date of Incident:** YYYY-MM-DD
**Date of Post-Mortem:** YYYY-MM-DD
**Severity:** Sev X
**Author:** <name>
**Attendees (if meeting held):** <names>

---

### Summary
*One paragraph: what happened, what the user impact was, how long it lasted.*

---

### Timeline (all times in IST)

| Time | Event |
|---|---|
| HH:MM | Alert fired in All Quiet / first customer report |
| HH:MM | On-call acknowledged |
| HH:MM | Incident declared, IC assigned |
| HH:MM | Root cause identified |
| HH:MM | Fix applied |
| HH:MM | Service restored |
| HH:MM | Incident resolved in All Quiet |

**Time to Detect (TTD):** X min
**Time to Resolve (TTR):** X hr Y min

---

### Root Cause
*Be specific. Not "human error" — what was the underlying system condition that made this possible?*

---

### What Went Well
-
-

---

### What Went Poorly
-
-

---

### Where We Got Lucky
*Things that could have made this worse but didn't.*
-

---

### Action Items

| Action | Owner | Due Date | Priority | Ticket |
|---|---|---|---|---|
| | | | High / Med / Low | [ENG-XXX](https://linear.app/...) |

---

### Lessons Learned
*What would an engineer need to know to handle this faster next time?*
```

---

## Quality checklist (run before presenting the file)

- [ ] Root cause names a system condition, not a human mistake
- [ ] Timeline has at least 5 timestamped entries
- [ ] TTD and TTR are calculated correctly
- [ ] At least 2 action items, each specific and prioritized
- [ ] If Linear tickets were created: each row has a working URL link with `incident` tag confirmed
- [ ] If Linear skipped: `[FILL: ticket]` placeholder present in each action item row
- [ ] No section left empty without a `[FILL: ...]` placeholder
- [ ] Filename uses actual Incident ID: `INC-XXX-postmortem.md`