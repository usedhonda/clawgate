import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, readFileSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { resolveTmuxWorkingDir } from "../client.js";

test("tmux targets remain one literal argument, including shell metacharacters", () => {
  const dir = mkdtempSync(join(tmpdir(), "clawgate-tmux-client-"));
  const previousPath = process.env.PATH;
  const argvFile = join(dir, "argv.json");
  const marker = join(dir, "unexpected-shell-command");
  const target = `session:$(touch ${marker})\"; echo injected; #\`touch ${marker}\``;
  try {
    writeFileSync(join(dir, "tmux"), `#!/usr/bin/env node\nimport { writeFileSync } from 'node:fs';\nwriteFileSync(${JSON.stringify(argvFile)}, JSON.stringify(process.argv.slice(2)));\nprocess.stdout.write('/fixture/project with spaces\\n');\n`, { mode: 0o700 });
    process.env.PATH = `${dir}:${previousPath ?? ""}`;
    assert.equal(resolveTmuxWorkingDir(target), "/fixture/project with spaces");
    assert.equal(existsSync(marker), false, "target must never be evaluated by a shell");
    assert.deepEqual(JSON.parse(readFileSync(argvFile, "utf8")), [
      "display-message", "-p", "-t", target, "#{pane_current_path}",
    ]);
    writeFileSync(join(dir, "tmux"), "#!/bin/sh\nexit 1\n", { mode: 0o700 });
    assert.equal(resolveTmuxWorkingDir("missing-session"), null);
  } finally {
    if (previousPath === undefined) delete process.env.PATH;
    else process.env.PATH = previousPath;
    rmSync(dir, { recursive: true, force: true });
  }
});
