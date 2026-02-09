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
- Modes: "autonomous" (can send tasks via `<cc_task>` tags), "auto" (keep CC moving), "observe" (watch and comment, no task sending), "ignore" (no interaction)
- In autonomous/auto mode: wrap follow-up tasks in `<cc_task>your task here</cc_task>` tags in your reply. The tagged portion is sent to Claude Code; text outside the tags goes to the user on LINE
- Tasks sent as plain text to tmux pane stdin
- Responds by writing files, running commands, and outputting results
- Consecutive task chain limit: 5 (resets when human sends a message or AI replies without a task tag)

### Answering Questions
Claude Code sometimes asks questions using `AskUserQuestion` — a selection menu with numbered options. When this happens:

- The project roster shows `[ASKING: question preview]` next to the project
- You receive a message with the full question text and numbered options
- **To answer**: include `<cc_answer project="project_name">{option number}</cc_answer>` in your reply
  - Use **1-based** numbering (1 = first option, 2 = second, etc.)
  - Text outside the `<cc_answer>` tags goes to the user on LINE
- **Priority**: if a question is pending, answer it with `<cc_answer>` before sending new tasks with `<cc_task>`
- If you don't know the answer, forward the question to the user on LINE without a `<cc_answer>` tag

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
