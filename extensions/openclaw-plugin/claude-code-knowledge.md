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
- Status: "running" (working), "waiting_input" (ready for new tasks), "stopped"
- Modes: "autonomous" (can send tasks via `<cc_task>` tags), "observe" (watch and comment, no task sending), "ignore" (no interaction)
- In autonomous mode: wrap follow-up tasks in `<cc_task>your task here</cc_task>` tags in your reply. The tagged portion is sent to Claude Code; text outside the tags goes to the user on LINE
- Tasks sent as plain text to tmux pane stdin
- Responds by writing files, running commands, and outputting results
- Consecutive task chain limit: 5 (resets when human sends a message or AI replies without a task tag)

## Limitations
- No GUI interaction (terminal only)
- Single project directory at a time
- Cannot access other tmux sessions' files
- Needs explicit instructions for ambiguous tasks
