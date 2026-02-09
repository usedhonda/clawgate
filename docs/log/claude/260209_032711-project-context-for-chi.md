# Project Context for Chi (AI)

## Summary
Chi (OpenClaw AI) にプロジェクトコンテキストを提供する機能を実装。
tmux completion 時はフルコンテキスト、LINE メッセージ時はコンパクト一覧を注入。

## New Files
- `extensions/openclaw-plugin/src/context-reader.js` — プロジェクトファイル読み取り (CLAUDE.md, git info, work logs)
- `extensions/openclaw-plugin/src/context-cache.js` — TTL 5分キャッシュ + パス解決
- `extensions/openclaw-plugin/claude-code-knowledge.md` — Claude Code 能力定義（静的）

## Modified Files
- `extensions/openclaw-plugin/src/client.js:160-173` — `resolveTmuxWorkingDir()` 追加
- `extensions/openclaw-plugin/src/gateway.js:16-34` — import 追加
- `extensions/openclaw-plugin/src/gateway.js:48-61` — CC knowledge 読み込み + session state tracking
- `extensions/openclaw-plugin/src/gateway.js:199-207` — `buildRosterPrefix()` 関数追加
- `extensions/openclaw-plugin/src/gateway.js:248-254` — `buildMsgContext` にroster prefix注入
- `extensions/openclaw-plugin/src/gateway.js:335-377` — `handleTmuxCompletion` にフルコンテキスト注入
- `extensions/openclaw-plugin/src/gateway.js:510-517` — ポーリングループでセッション状態トラック

## Architecture
```
tmux completion event
  -> resolveProjectPath (tmux pane_current_path)
  -> invalidateProject (cache clear)
  -> getProjectContext (read CLAUDE.md, git, logs)
  -> body = [project context] + [CC knowledge] + [task summary]

LINE message
  -> buildRosterPrefix (compact list of active projects)
  -> BodyForAgent = [location] + [roster] + [message]
```

## Token Budget
- Per-project context: max 6000 chars (CLAUDE.md 2000 + git + logs)
- CC knowledge: ~500 chars
- Roster: ~200 chars total (all projects)
- Cache TTL: 5 minutes, invalidated on task completion

## Privacy
- Never reads: .env, .local/, credentials, node_modules/, source code
- Only reads: CLAUDE.md, AGENTS.md, README.md, docs/log/claude/, git info
- Opt-in: only observe/autonomous projects appear in roster
