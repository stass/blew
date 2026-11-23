# Working agreement

blew is a macOS command-line tool for Bluetooth LE, written in Swift:
scanning, GATT reads, writes and subscriptions, a REPL and `exec`
scripts, a peripheral (advertising) mode, a Nordic UART Service bridge
and an MCP server. [DESIGN.md](DESIGN.md) is the architecture,
[README.md](README.md) the user-facing contract, [TESTS.md](TESTS.md)
the test plan and [TODO.md](TODO.md) the open work.

Layout:
- `Sources/BLEManager`: the CoreBluetooth wrapper (central and peripheral).
- `Sources/blew`: the CLI, `CommandRouter`, REPL, MCP, NUS and output
  renderers.
- `Sources/LineNoise`: the vendored line editor.
- `Plugins/` and `Scripts/`: build-time code generation from the git
  submodules in `Vendor/`.

## Collaboration

* Ask, don't assume. If intent, architecture or requirements are unclear,
  ask before writing code. Never make silent assumptions.
* Flag uncertainty explicitly. If you are not confident about an approach
  or a technical detail, say so before proceeding.
* **Two advisors before me.** Put a hard technical question first to two
  advisors: a Claude Opus subagent at `max` effort and a Codex
  `gpt-6-astra` pass at `high` reasoning effort in a read-only sandbox.
  Give both the options, the code and the documents, without your own
  conclusion. When they agree with each other and with you, decide and
  report the decision afterwards. Ask me only what you still cannot
  settle, with each advisor's recommendation and yours. Scope,
  priorities, releases, pushes, changes to what I have accepted, and
  edits to this file stay mine.
* **Open questions park only their slice.** A question waiting on me
  blocks only the work that depends on its answer. Keep building
  everything else meanwhile, and state the blocked slice when you ask.
* **Read the source, not your memory.** Work from the code, Apple's
  CoreBluetooth documentation, the Bluetooth SIG specifications in
  `Vendor/`, or the swift-sdk source checked out under `.build/`, citing
  file and line or section. A fact no source read in the task supports is
  marked unverified, or left for a test to settle.
* Use plain language in explanations, progress updates and documentation.
  Name the concrete file, command, input or result.
* Suggest better ways of doing things, especially ones with lasting
  impact over a tactical change.
* **Fix the tool, don't work around it.** When a tool, library, format or
  rule here is inadequate, stop and propose the change instead of
  absorbing the gap in workaround code. State what the gap costs.
* Security is on equal footing with correctness.
* **If you discover a bug, discrepancy or something unexpected, fix it**
  whether or not it relates to the task, if it is straightforward or
  needed for progress; otherwise record it in `TODO.md`.
* **Delegate with context, not checklists.** Give an agent the goal, the
  context and my constraints quoted verbatim; mark everything else as
  guidance and invite it to argue for a better approach. Never pass on a
  constraint I did not state as if I had.
* Read this file again after each context compaction.

## Design

* **Design before architectural change.** Analyze [DESIGN.md](DESIGN.md)
  before implementing a change and base the plan on it. When a change is
  architectural, update DESIGN.md in the same commit so it reflects the
  result.
* **No hedging, no fallbacks.** Make a reasoned decision about which
  values are valid and use them. When something unexpected happens,
  report an error; never substitute a default silently (an unknown `-f`
  format is an error, not hex).
* **Judge complexity by the model a maintainer must understand.** Compare
  the concepts, states, ownership rules and coordination obligations a
  change adds with those it removes. Lines of code are a proxy for review
  effort, not a goal.
* **Human readability is a requirement.** Another developer must
  understand purpose, data flow, invariants and failure paths without
  reading the conversation. One type per concept; one failure path per
  operation; defend once, at the trust boundaries listed under Code.
* **Functional core, effects at the edge.** Decisions that can be pure
  functions are: argument parsing, device selection, value formatting and
  decoding, and the NUS session steps. CoreBluetooth calls, file
  descriptors, sockets and the terminal stay in a thin layer around them,
  so the core is unit-tested without a radio.
* **Question every requirement before building for it.** Before adding a
  mechanism (a flag, a dependency, a mode, a special case), name the user
  or consumer that needs it and what breaks without it.
* **The common path first; the long tail goes to `TODO.md`.** Defer a case
  only when leaving it open fails safely, with an error and a nonzero exit.
  Never defer one that would hang, crash, act on the wrong device, or
  report a failure as success.
* **Fix the class, not the instance:** in the type or module that allowed
  the bug, not at the call site that hit it (for example, filter every
  CoreBluetooth event by peripheral in `BLEEventProcessor`, not per
  command).
* **Make misuse impossible to write, not checked for.** Prefer types and
  access control (`private`, `fileprivate`, validating initializers) over
  conventions a reviewer has to remember.
* **Fix what produced a wrong result, not the result.** When a generator
  (`Scripts/*.rb`) gives wrong output, fix the generator or its input;
  never patch its output.
* **One source for every fact.** Every table, format and decision has one
  implementation. A comment or test that keeps two copies in step means a
  generator or a shared helper is missing.

## Code

* **Untrusted input.** Everything that comes from a device (advertised
  names, manufacturer data, characteristic values, GATT layout), from an
  MCP client, from a TCP or pty client of the NUS bridge, and from config
  files and command-line arguments is untrusted. It is validated
  once, at entry, and never reaches an API that traps or raises on bad
  input. `CBUUID(string:)` and `CBMutableDescriptor` raise Objective-C
  exceptions Swift cannot catch, so UUIDs and descriptors are validated
  before they get there. Bad input gives an error and a nonzero exit,
  never a crash or a hang.
* **Text from devices reaches the terminal and kv output only through one
  escaping function per output format.** Raw control characters on a
  terminal are an attack (ANSI and OSC escape injection), so the text
  renderer escapes C0 and C1 controls, bidirectional overrides and invalid
  UTF-8. The kv renderer also escapes tab, newline and backslash, so one
  record stays one line. Bytes a user asked to stream raw (`nus` stdio,
  `read -f raw`) are delivered unchanged.
* **Concurrency.** CoreBluetooth callbacks run on the `blew.cb` queue;
  shared state has one owner and one lock or actor. Every continuation is
  resumed exactly once on every path: success, error, timeout,
  cancellation, disconnect and Bluetooth power-off. Every wait has a
  deadline or is cancellable.
* **Exit codes are a contract.** The codes in `Sources/blew/ExitCodes.swift`
  and README.md agree, every failure path exits nonzero with the documented
  code, and each code has a test.
* **Never fabricate.** Output shows unknown, partial, unsupported and
  timed-out results as such, never as a value or as success.
* **Generated files are not checked in.** The build plugin generates them
  from the submodules and the generators; commit the input and the
  generator, never the output.
* **No temporal or campaign-specific marks** in code, comments or docs: no
  "now fixed", "previously broken", "as of <date>", "fixes B4". Code and
  docs describe the current state. The why and when belong in commit
  messages.
* Don't use emojis in documentation or logs.

## Tests

* Write the tests that would catch a real break in what you build: its
  behaviour and its main failure paths. No tests of the test tooling and
  no exhaustive matrices, except for a protocol state machine (the NUS
  session, REPL key handling).
* **When fixing a non-trivial bug, write the regression test first.**
  Confirm it fails against the unfixed tree, then apply the fix and
  confirm it passes. Trivial typo and obvious one-line fixes are exempt;
  anything touching concurrency, continuations, timeouts, signal handling,
  parsing or decoding is not trivial.
* **Two tiers of gates.**
  * **While developing:** `swift test --filter <Suite>` for the code the
    change affects.
  * **Before a commit:** `swift build` with no new warnings, and the full
    `swift test` once.
  * **Before a release, and for changes to BLEManager, MCP or NUS
    concurrency:** `swift test --sanitize=thread` and
    `swift test --sanitize=address`.
  * Send long output to a file and read the failures from it.
* **Agreement with ground truth.** GATT decoding is checked against the
  Bluetooth SIG specifications in `Vendor/bluetooth-SIG`; a decoded value
  that disagrees with the specification is a bug until a test pins the
  explanation.
* Behaviour that needs a real radio is listed in [TESTS.md](TESTS.md) as a
  manual check and exercised before a release.

## Committing

* Commit each piece of solid progress.
* **Linear history: rebase, then fast-forward.** No merge commits. A branch
  takes master's changes with `git rebase master` and lands with
  `git merge --ff-only`. Run the gate on the rebased tip.
* Before committing code:
  - Launch a code-review subagent **first**, before running tests. Ask it
    to enumerate bugs, design issues, AND security and information-leak
    concerns, framing the security pass explicitly. Ask for readability
    findings with specific functions as evidence.
  - Address every CRITICAL and HIGH finding before committing. Record
    MEDIUM findings in `TODO.md` or the commit message if not fixed.
* **External review.** Complex changes, and the release branch before it
  is tagged, also get a Codex review once the internal review passes:
  `codex exec -m gpt-6.1-sol -c model_reasoning_effort='"xhigh"' -s read-only -C <tree> "<prompt>" < /dev/null > review.log 2>&1`
  (use `high` effort when the code is not especially complex). Close
  stdin, or `codex exec` waits forever. Take the review from the log, as
  the last `codex` block before the `tokens used` line. Its findings
  follow the same rules as internal findings.
* Whenever user-facing functionality or behaviour changes, update
  README.md in the same commit.

## Documents

* **Document roles.**
  * [DESIGN.md](DESIGN.md) is the architecture, in the present tense.
    Edit it when the design changes, not to record what shipped or what
    is deferred.
  * [README.md](README.md) is the user-facing contract: commands, options,
    output formats and exit codes. Every example in it must run as
    written.
  * [TESTS.md](TESTS.md) is the test plan, including manual hardware
    checks.
  * [TODO.md](TODO.md) is the index of open work.
* **`TODO.md` structure.** Items are grouped by priority (P0 to P3) and
  subsystem. Each one has an ID, a file:line pointer, the defect and a
  failure scenario. The release an item targets is stated in its
  section heading. When an item is closed, delete it in the commit that
  fixes it, citing its ID in the commit message; git history is the
  record of completed work.
* **`TODO.md` holds only work worth doing.** A limitation users should
  know about belongs in README.md, not in `TODO.md`.
