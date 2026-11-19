# claude-code-java-hooks

Three Claude Code hooks for a Java/Spring Boot repo: block an obvious secret before it's written, format a file after it's edited, and refuse to end a turn on a red build.

## What this is / what it isn't

- **Is:** three POSIX shell scripts plus the `settings.json` block that wires them into Claude Code's `PreToolUse`, `PostToolUse` and `Stop` hooks. MIT-licensed.
- **Is:** a small example Spring Boot app (`example/`) you can use to see the `Stop` hook block a red build, step by step.
- **Isn't:** a secret scanner, a Claude Code plugin, a framework, or a product with a promise of future updates. What you see here is what you get.

## Requirements

- `bash`
- `python3` 3.8+
- Maven, or Gradle with the caveat in "Maven and Gradle" below
- [Claude Code](https://claude.com/claude-code)
- JDK 21+ (required by `google-java-format` 2.0.0, used in the format-on-edit hook); the `example/` project targets Java 21.
- Windows: these are shell scripts, so you need **WSL2** or **Git Bash**; there is no native Command Prompt or PowerShell version.

## Install in 3 steps

1. Copy the `.claude/` folder from this repository into the root of your project.
2. `chmod +x .claude/hooks/*.sh`
3. Reopen Claude Code in that project and run `/hooks` to confirm the three hooks are registered.

If your project already has a `.claude/settings.json`, don't overwrite it: open both files and merge the `hooks` key by hand, keeping any hooks you already had alongside these three.

## The three hooks

| Script | Event | Matcher | What it does | Can it block? | Cost when it fires |
|---|---|---|---|---|---|
| `block-secrets.sh` | `PreToolUse` | `Edit\|Write` | Scans what a `Write` would write or an `Edit` would insert against four patterns (AWS key, GitHub token, private key header, generic `key=`/`token=`/`password=` assignment) and refuses the write if one matches. | Yes | A 10-second timeout budget; the check itself runs in well under a second. |
| `format-on-edit.sh` | `PostToolUse` | `Edit\|Write` | On a saved `.java` file, runs Spotless scoped to that one file. On any file that can change build behavior (`.java`, `pom.xml`, `*.sql`, `application*.{yml,yaml,properties}`), marks a build as owed for the `Stop` hook. | No, it only warns on stderr | A 60-second timeout budget; in practice, one Spotless run on a single file. |
| `require-green-build.sh` | `Stop` | none (`Stop` has no matcher) | If a build is owed, runs your test command once. Green: clears the marker and lets the turn end. Red: blocks the turn and shows the last 20 lines of the failure. | Yes | Whatever your `BUILD_CMD` costs — the default is `mvn -q test`, so one full test run of your project. |

## Maven and Gradle

The scripts and the example in this repository are Maven. Gradle is **documented here, not tested** — swap these two lines if your project uses Gradle:

- In `require-green-build.sh`: `BUILD_CMD="mvn -q test"` → `BUILD_CMD="./gradlew test"`
- In `format-on-edit.sh`: `FORMAT_CMD="mvn -q spotless:apply"` → `FORMAT_CMD="./gradlew spotlessApply"`, and the check right above it, `grep -q spotless "$PROJECT_DIR/pom.xml"`, → `grep -q spotless "$PROJECT_DIR/build.gradle"` (or `build.gradle.kts`, if that's what your project uses).

One detail worth knowing either way: `-DspotlessFiles=<path>` (the Maven flag `format-on-edit.sh` passes to scope the format to one file) is matched as a **list of regular expressions against the file's path**, not a literal path string. An absolute path with dots and slashes still matches as a regex in practice, but if you ever see the formatter catching more files than you expected, that's why.

## See it work

### (a) `block-secrets.sh` catching a key

```
$ cat hook-input.json
{"tool_input":{"file_path":"src/main/resources/application.yml","content":"aws:\n  access-key: \"AKIAIOSFODNN7EXAMPLE\"\n"}}

$ .claude/hooks/block-secrets.sh < hook-input.json
Blocked: this looks like a AWS access key (AKIAIOSFODNN...). This file ships with your repo (every clone, every fork) -- a secret in it is a secret in git history forever, even after you edit it out.
Use an environment variable or a placeholder instead, e.g. ${AWS_ACCESS_KEY} in application.yml (Spring resolves it from the environment) or <your-key-here> in docs.
False positive, or need a looser rule? Edit PATTERNS in .claude/hooks/block-secrets.sh -- this hook is the one place that list lives.

$ echo $?
2
```

`AKIAIOSFODNN7EXAMPLE` is AWS's own public example key, used in AWS's documentation for exactly this purpose — it is not a real credential.

### (b) `require-green-build.sh` blocking a red build, then letting it go

The hooks assume the Maven project is at the root of `$CLAUDE_PROJECT_DIR`. In this repository the example app lives in a subfolder (`example/`), so the demo below points `CLAUDE_PROJECT_DIR` at that subfolder by hand — that's a one-off for this README, not something you need to do once the hooks are installed in your own project, where `CLAUDE_PROJECT_DIR` already points at the project root.

First, break a test on purpose: open `example/src/main/java/com/izzrlabs/hooksdemo/web/GreetingController.java` and change `"Hello, "` to `"Hi, "`. That's a `.java` file, so the marker that tells `Stop` a build is owed gets created (normally by `format-on-edit.sh`; the demo below creates it by hand to skip the Edit step):

```
$ mkdir -p example/.claude && echo 0 > example/.claude/.build-pending

$ CLAUDE_PROJECT_DIR="$PWD/example" .claude/hooks/require-green-build.sh <<< '{"stop_hook_active":false}'
require-green-build.sh: `mvn -q test` failed (attempt 1 of 3, stop_hook_active=false). Last 20 lines:
	at org.springframework.test.util.JsonPathExpectationsHelper.assertValue(JsonPathExpectationsHelper.java:172)
	at org.springframework.test.web.servlet.result.JsonPathResultMatchers.lambda$value$2(JsonPathResultMatchers.java:111)
	at org.springframework.test.web.servlet.MockMvc$1.andExpect(MockMvc.java:212)
	at com.izzrlabs.hooksdemo.web.GreetingControllerTest.defaultsToWorld(GreetingControllerTest.java:22)

[ERROR] Failures:
[ERROR]   GreetingControllerTest.defaultsToWorld:22 JSON path "$.message" expected:<Hello, world> but was:<Hi, world>
[ERROR]   GreetingControllerTest.greetsByName:30 JSON path "$.message" expected:<Hello, Ada> but was:<Hi, Ada>
[ERROR] Tests run: 2, Failures: 2, Errors: 0, Skipped: 0
[ERROR] Failed to execute goal org.apache.maven.plugins:maven-surefire-plugin:3.5.6:test (default-test) on project hooks-demo: There are test failures.
[ERROR]
[ERROR] See ~/code/claude-code-java-hooks/example/target/surefire-reports for the individual test results.
[ERROR] See dump files (if any exist) [date].dump, [date]-jvmRun[N].dump and [date].dumpstream.
[ERROR] -> [Help 1]
[ERROR]
[ERROR] For more information about the errors and possible solutions, please read the following articles:
[ERROR] [Help 1] http://cwiki.apache.org/confluence/display/MAVEN/MojoFailureException

$ echo $?
2
```

Now undo the edit (change `"Hi, "` back to `"Hello, "`) and run the same command again:

```
$ CLAUDE_PROJECT_DIR="$PWD/example" .claude/hooks/require-green-build.sh <<< '{"stop_hook_active":true}'

$ echo $?
0

$ ls example/.claude/.build-pending
ls: example/.claude/.build-pending: No such file or directory
```

Green build, no stderr, exit `0`, and the marker is gone — the turn is free to end.

## How it works

- `format-on-edit.sh` creates `.claude/.build-pending` **only if it doesn't already exist** (`[ -f "$MARKER" ] || echo 0 > "$MARKER"`). That file's content isn't a boolean, it's `require-green-build.sh`'s consecutive-failure counter. If something else touches the file with `touch` or `echo > `, it overwrites that counter back to nothing and the loop guard below resets with it — don't recreate the marker by hand outside of this flow.
- Editing only a `.md` file never creates the marker (it's not in `format-on-edit.sh`'s build-relevant list: `*.java`, `pom.xml`, `*.sql`, `application*.{yml,yaml,properties}`), so a documentation-only session's `Stop` hook exits immediately with nothing to check.
- `require-green-build.sh` runs `BUILD_CMD` at most once per `Stop` invocation. If it fails, the failure counter in the marker goes up by one and the hook exits `2`, which blocks the turn and shows Claude the build's stderr so it can try to fix the problem. After **3** consecutive red builds, the **next** `Stop` gives up instead of blocking again: it deletes the marker and exits `0`, letting the turn end anyway, on the idea that a human should look at this rather than get another automatic retry.
- `Stop` fires again with `stop_hook_active: true` in its input after a block — that's how the hook knows this is a retry, not a fresh turn; it doesn't change what the script does, but it's logged in the failure message.
- `block-secrets.sh` fails closed: if it can't parse its own JSON input at all, it blocks rather than silently letting the write through.

## Configuration

- **`PATTERNS`** in `block-secrets.sh`: a list of `(name, compiled regex)` pairs. Add, loosen or drop an entry; nothing else in the file needs to change.
- **`FORMAT_CMD`** in `format-on-edit.sh`: the single-file formatter command, default `mvn -q spotless:apply`.
- **`BUILD_CMD`** in `require-green-build.sh`: the test command, default `mvn -q test`. In a multi-module project, scope it with Maven's `-pl`/`-am` flags, for example `mvn -q test -pl my-service -am`.
- **`MAX_CONSECUTIVE_FAILURES`** in `require-green-build.sh`: default `3`, see "How it works" above.
- **`timeout`** values in `settings.json` (10s / 60s / 300s): these are choices made for this repository's scripts, not Claude Code's own default, which is 600s for a `command` hook. The `Stop` hook here is set to 300s, tighter than that default, so that `mvn -q test` doesn't run unbounded — but if your own project's test suite takes longer than 300s, Claude Code cancels the command, `require-green-build.sh` never gets to report red, and the turn ends anyway with a build that hasn't actually been checked. If your build is slow, raise this value in `settings.json` rather than relying on the 600s default.

## Limitations

- Both scripts that need to see tool input only match `Edit` and `Write` in their `matcher`. A write through `Bash` (`cat > file.yml <<EOF ... EOF`, `sed -i`, a script that generates a file) skips both of them entirely.
- `block-secrets.sh` checks four regular expressions. It doesn't read git history, doesn't check already-committed files, and the "generic secret assignment" pattern is placeholder-friendly by design — a sufficiently disguised or encoded secret can still get through.
- If `block-secrets.sh` can't parse the JSON it's given on stdin, it blocks the write rather than letting it through — a deliberate fail-closed choice, but it means a malformed or unexpected hook payload shape shows up to you as a block, not a silent skip.
- `format-on-edit.sh`'s formatting job never blocks anything: if Spotless isn't configured in the project (no `spotless` string in `pom.xml`) or if it fails, the file is left as-is and the session continues with no error visible beyond a line on stderr.
- `Stop` does not run when the user interrupts a turn, and it runs again with `stop_hook_active: true` in its input the next time the turn tries to end after a block — see "How it works".
- `Stop` also does not run when a turn ends because of an API error — that fires the separate `StopFailure` event instead, which this repo doesn't hook. If a build marker is pending when that happens, it's left on disk untouched, and the build simply isn't checked for that turn; the next turn that reaches a real `Stop` is the first one that acts on it.
- After 3 consecutive red builds, the next `Stop` gives up and lets the turn end anyway instead of blocking again; a fourth red build in a row does not get caught.
- `require-green-build.sh` runs one command against one project root. In a multi-module build you're responsible for scoping `BUILD_CMD` with `-pl`/`-am` (or your Gradle equivalent) yourself; it does not discover or walk modules on its own.
- These are POSIX shell scripts. There is no CMD or PowerShell version; on Windows you need WSL2 or Git Bash.

## If you want the rest

These three hooks are the same files, unmodified beyond a couple of comments — and they're free. The [Claude Code Kit for Java & Spring Boot](https://izzrlabs.gumroad.com/l/weloxy) ($39, one-time) builds on them with, by name only: 3 subagents, 3 skills, 6 slash commands, 5 `CLAUDE.md` templates, a Claude Code plugin manifest, a multi-module example project, and a 7-part guide.

If you're studying for a Java/Spring Boot interview instead, there's also the [Modern Java & Spring Boot Interview Guide](https://izzrlabs.gumroad.com/l/kxtubc).

## License

MIT. See [`LICENSE`](LICENSE). Claude Code is a product of Anthropic; this repository is independent and not affiliated with Anthropic, Oracle (Java) or Broadcom (Spring).
