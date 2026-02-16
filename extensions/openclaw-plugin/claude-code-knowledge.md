# Claude Code Capabilities

Claude Code is an AI coding agent running in a terminal (tmux pane).

## Can Do
- Read, write, edit files in the project directory
- Run bash commands (build, test, deploy, git)
- Search code, browse web for docs
- Create git commits and PRs
- Use MCP tools if configured
- Install dependencies and manage packages
- Run and interpret test results

## Interaction

### Sending Tasks
- Status: "running" (working), "waiting_input" (ready for new tasks), "stopped"
- Modes: "autonomous" (can send tasks via `<cc_task>` tags), "auto" (keep CC moving), "observe" (watch CC's work and share your own opinions with user, no task sending, CC is unaware of you), "ignore" (no interaction)
- In autonomous/auto mode: wrap follow-up tasks in `<cc_task>your task here</cc_task>` tags in your reply. The tagged portion is sent to Claude Code; text outside the tags goes to the user
- Tasks sent as plain text to tmux pane stdin
- Responds by writing files, running commands, and outputting results
- Consecutive task chain limit: 5 (resets when human sends a message or AI replies without a task tag)

### Answering Questions
Claude Code sometimes asks questions using `AskUserQuestion` — a selection menu with numbered options. When this happens:

- The project roster shows `[ASKING: question preview]` next to the project
- You receive a message with the full question text and numbered options
- **To answer**: include `<cc_answer project="project_name">{option number}</cc_answer>` in your reply
  - Use **1-based** numbering (1 = first option, 2 = second, etc.)
  - Text outside the `<cc_answer>` tags goes to the user
- **Priority**: if a question is pending, answer it with `<cc_answer>` before sending new tasks with `<cc_task>`
- If you don't know the answer, forward the question to the user without a `<cc_answer>` tag

Example:
```
I'll select the recommended option for the auth method.
<cc_answer project="myapp">1</cc_answer>
```

## Limitations
- No GUI interaction (terminal only)
- Single project directory at a time
- Cannot access other tmux sessions' files
- Needs explicit instructions for ambiguous tasks

## Development Workflow

### CC's Typical Flow
CC works in iterative cycles:
1. Read/explore code to understand the codebase
2. Plan the implementation (may use Plan Mode for complex tasks)
3. Implement changes (edit files, run commands)
4. Test (run tests, verify behavior)
5. Deploy (if applicable via project scripts)

### Plan Mode
CC sometimes enters Plan Mode for complex tasks:
- Drafts a detailed implementation plan with file changes, approach, and rationale
- Presents the plan and asks "Ready to proceed?" or similar approval question
- The plan content appears in the pane context ABOVE the question

When you see a plan approval question:
- The question_context field contains the plan — read it carefully
- Evaluate: scope, risks, approach
- AUTO: approve unless the plan has clear issues
- AUTONOMOUS/OBSERVE: summarize the plan and assessment for the user

### Common Question Types

| Pattern | Meaning | What to Check |
|---|---|---|
| "Ready to proceed?" / "Should I proceed?" | Plan mode approval | Read question_context for the plan content |
| "Which approach/option?" | Design decision | Context shows options and trade-offs |
| "Do you want me to edit/create X?" | File modification | Is the file relevant to the task? |
| "Should I delete/reset X?" | Destructive action | Extra caution — verify with user |
| Multiple sequential questions | Multi-step wizard | Answer each step, CC auto-advances |

### Permission Prompts vs Questions
- Permission prompts (tool use): Auto-approved in auto mode. CC asking to run bash, edit files, etc.
- AskUserQuestion (decision needed): CC genuinely needs input. These are forwarded to you.

### Understanding Question Context
When a question event includes question_context, it contains the terminal output ABOVE the question.
This is essential for understanding:
- What CC was working on when it asked
- Plan content for approval questions
- Error output that prompted a clarification question
Always read question_context before answering or advising on a question.
