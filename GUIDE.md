# Week 1 Thu — Timelock: delayed admin actions (step-by-step guide)

**Goal:** build a timelock that makes every admin action wait in public before it can run, put it between your
2-of-3 multisig and a contract it controls, and prove that a guardian can stop an attacker who holds two of the
three keys. Then build a security reviewer as a Claude Code subagent, and test it on a real bug you plant yourself.

**Why this project:** your multisig decides *who* can act. It says nothing about *when*. Your multisig README even
lists this as a known limitation: "There's no delay before execution." A timelock gives users and monitoring
systems time to notice a bad action and react. Compound, Uniswap and many other protocols put one in front of
their admin powers.

| Job requirement | Where you practice it |
|---|---|
| Access control, upgrade safety (Coinbase Stablecoins, Chainlink, FTI) | Steps 1, 3 |
| Onchain security, thinking like an attacker (Coinbase, Chainlink, Anchorage) | Steps 2, 4, 5 |
| *Well-tested code* | Steps 2, 3, 5 (boundary, fuzz, attack, integration tests) |
| *Uses generative AI responsibly, with human oversight* | Steps 4, 5 (you verify the reviewer, then measure it) |

**Claude Code technique today: a custom subagent.** A subagent is a specialist Claude that runs in **its own
context window**, with its own instructions and its own limited tools. It doesn't see your conversation. It
receives a task, does the work, and sends back a report. That makes it a good code reviewer, for three reasons:

1. **It didn't write the code,** so it doesn't carry the assumptions of the session that did.
2. **It can be read-only,** so it reports problems instead of quietly changing your code.
3. **It lives in a file,** so it's versioned in git, and you can reuse it in every later project.

**Time:** about 90 minutes. Everything runs locally with play money.

---

## How to use this guide with Claude Code

Every step has the same five parts:

- **Learn:** the concept, in a few sentences. Read it before prompting.
- **Prompt:** what to type into Claude Code. Use **plan mode** (`Shift+Tab` until the status bar shows
  `⏸ plan mode on`), read the plan, then approve it.
- **You check:** what *you* verify before accepting. Each check names the file and function to open.
- **Done when:** a command whose output proves the step works.
- **Commit:** the commit message to use. Ask Claude to commit, or run it yourself.

A leading `!` in the Claude Code prompt runs a shell command, as in `!forge test`.

Line numbers and exact wording in Claude's replies will differ from the examples here. The test names and test
counts should match, as long as you keep the prompts as written.

---

## Step 0 — Create the repo and add this guide (10 min)

**Learn.** Your `/new-project` skill creates the public repo, scaffolds Foundry, and pushes a first commit with
green CI. It asks before creating anything.

**Do it:** in Git Bash, go to the folder where you keep your project repos (**not** inside another git repo), then:

```bash
claude
```

**Prompt:**
> /new-project Week 1 Thu – Timelock: delayed admin actions

When it proposes a name, accept **`timelock`** (or pick your own and use it everywhere below). Confirm the language
is **`solidity`**. Approve the `gh repo create` and `git push` prompts when they appear.

When it finishes, quit Claude Code (`/exit`), then:

```bash
cd timelock
```

Save **this file** as `GUIDE.md` in the `timelock` folder. Then bring in the two contracts you wrote on Tuesday.
This copies them from your public repo:

```bash
curl -fsSL -o src/MultiSig.sol https://raw.githubusercontent.com/Syriacode/multisig-wallet/main/src/MultiSig.sol
curl -fsSL -o src/FeeController.sol https://raw.githubusercontent.com/Syriacode/multisig-wallet/main/src/FeeController.sol
ls src
```

You should see `Counter.sol`, `FeeController.sol` and `MultiSig.sol`. Then:

```bash
claude
```

**Prompt:**
> Delete the sample Counter files: src/Counter.sol, test/Counter.t.sol, and script/Counter.s.sol.
> Run forge build. Then commit GUIDE.md, src/MultiSig.sol, src/FeeController.sol and the deletions together.

**You check:** `!git status` is clean, and `!git log --oneline` shows two commits.

**Done when:** `!forge build` prints `Compiler run successful!` or `No files changed, compilation skipped`. Lint notes
about `MultiSig.sol` are fine.

**Commit:** `Add GUIDE.md, bring in MultiSig and FeeController, remove sample Counter`

---

## Step 1 — The timelock contract (15 min)

**Learn.**

An action moves through this life cycle:

```text
          queue()              delay passes            GRACE_PERIOD ends
not queued ─────► waiting ───────────────────► ready ─────────────────────► expired
                    │                            │
                    │ cancel()                   │ execute()
                    ▼                            ▼
                 removed                      executed
```

- **Queue:** the admin announces the exact action (target, ETH value, calldata). An event makes it public.
- **Delay:** no one can run it yet. This window is the whole point: people can read the action, and leave or object.
- **Execute:** after the delay, **anyone** can run the action. The approval already happened in the queue step.
  Open execution also means no single key can block an approved action by refusing to send the transaction.
- **Grace period:** after 14 days, the action expires. Without this, an old forgotten action could run years later.
- **Guardian:** a separate key that can only **cancel**. It can't start anything, so stealing it can't move funds.
- **Self-call:** `setDelay` only accepts calls from the timelock itself, so changing the delay must wait through
  the current delay. Otherwise a stolen admin key would set the delay to the minimum first, and then act.
- **Action ID:** a hash of the action's details. `queue` stores the time under that ID, and `execute` recomputes it
  from what the caller passes in. That hash is what ties the action people reviewed to the action that runs.
  Remember this for Step 5.
- **`salt`:** an extra value in the hash, so the same action can be queued again later under a new ID.

**Real incident.** In April 2022, the Beanstalk protocol lost about $181M. It had a one-day wait between creating a
proposal and emergency execution, but **no wait between voting and execution**. The attacker made a proposal, came
back a day later, took a flash loan, voted with it, and executed, all in one transaction. A delay only protects
you if it comes **after** the decision.

**Prompt (plan mode):**
> Create src/Timelock.sol (pragma ^0.8.24, MIT license), a contract `Timelock` with:
> - constants `MIN_DELAY = 1 hours`, `MAX_DELAY = 30 days`, `GRACE_PERIOD = 14 days`
> - immutables `admin` and `guardian`, and `uint256 public delay`
> - `mapping(bytes32 id => uint256 time) public readyAt`, where 0 means not queued
> - events `Queued(bytes32 indexed id, address indexed target, uint256 value, bytes data, bytes32 salt, uint256 readyTime)`,
>   `Executed(bytes32 indexed id, address indexed target, uint256 value, bytes data)`,
>   `Cancelled(bytes32 indexed id, address indexed by)`, `DelayChanged(uint256 oldDelay, uint256 newDelay)`,
>   `Received(address indexed sender, uint256 amount)`
> - custom errors `NotAdmin()`, `NotAdminOrGuardian()`, `NotSelf()`, `ZeroAddress()`, `DelayOutOfRange(uint256 delay)`,
>   `AlreadyQueued(bytes32 id)`, `NotQueued(bytes32 id)`, `NotReady(bytes32 id, uint256 readyTime)`,
>   `Expired(bytes32 id, uint256 deadline)`, `ExecutionFailed()`
> - constructor `(address admin_, address guardian_, uint256 delay_)`: reject zero addresses with ZeroAddress and an
>   out-of-range delay with DelayOutOfRange
> - `receive()` payable that emits Received
> - `getId(address target, uint256 value, bytes calldata data, bytes32 salt)` public pure: returns
>   `keccak256(abi.encode(target, value, data, salt))`
> - `queue(address target, uint256 value, bytes calldata data, bytes32 salt)` returns the id: admin only (NotAdmin),
>   reject a zero target, revert AlreadyQueued if `readyAt[id]` isn't 0, set `readyAt[id]` to `block.timestamp + delay`,
>   emit Queued
> - `execute(address target, uint256 value, bytes calldata data, bytes32 salt)`, callable by anyone and not payable:
>   compute the id. Checks: NotQueued if readyAt is 0, NotReady if `block.timestamp < readyTime`, Expired if
>   `block.timestamp > readyTime + GRACE_PERIOD`. Effects: delete `readyAt[id]`, emit Executed. Interactions:
>   `target.call{value: value}(data)`, revert ExecutionFailed if it fails. Mark the three parts with comments.
> - `cancel(bytes32 id)`: admin or guardian only (NotAdminOrGuardian), NotQueued if readyAt is 0, delete it, emit Cancelled
> - `setDelay(uint256 newDelay)`: only callable by the contract itself (NotSelf), enforce the range, emit DelayChanged,
>   store the new value
>
> Don't write tests yet. Run forge build and forge fmt.

**You check:** open `src/Timelock.sol`.
- In `execute`, `delete readyAt[id]` comes **before** `target.call`. Ask Claude: *"What can a malicious target do if
  these two lines are swapped?"*
- All three time checks in `execute` also come **before** `target.call`. This matters. OpenZeppelin's
  `TimelockController` before version 4.3.1 checked `isOperationReady` only **after** the call (in `_afterCall`). An
  account with the executor role could run an action that wasn't queued, use that call to set the delay to 0 and
  make itself a proposer, and queue the action from inside the call, so the late check passed. That's
  [CVE-2021-39167](https://osv.dev/vulnerability/GHSA-fg47-3c2x-m2wr), severity 10.0. Keep this for Interview Q4.
- In `setDelay`, the check is `msg.sender != address(this)`, not an admin check. Ask Claude: *"How does a call to
  setDelay ever get through this check, if no one can call it directly?"*
- `readyAt` uses 0 to mean "not queued". Ask Claude: *"Could `readyAt` ever really be 0 for a queued action?"*

> ℹ️ `forge build` also prints lint notes: `screaming-snake-case-immutable` for `admin` and `guardian`, `asm-keccak256`
> for `getId`, and `unwrapped-modifier-logic` for `MultiSig.sol`. They're style suggestions, not errors, and CI still
> passes. Don't let Claude "fix" them. In particular, keep the plain `keccak256(abi.encode(...))` line, because Step 5 edits it.

**Done when:** `!forge build` prints `Compiler run successful!`, or `No files changed, compilation skipped` if Claude
already built it.

**Commit:** `Add Timelock with queue, execute, cancel and self-governed delay`

---

## Step 2 — Tests: moving time with `vm.warp` (15 min)

**Learn (Foundry).**
- `vm.warp(t)` sets `block.timestamp` to `t`, so a two-day wait takes no time in a test.
- **Boundary tests** are where time bugs hide. The difference between `<` and `<=` is a single second, so test
  one second before the limit, exactly at it, and one second after it.
- `vm.expectRevert(abi.encodeWithSelector(Error.selector, arg1, arg2))` checks an error **and** its arguments.

> ⚠️ Today's test list has a hole in it, on purpose. Don't add extra tests in this step. You'll find the hole in Step 5.

**Prompt (plan mode):**
> Create test/Timelock.t.sol for @src/Timelock.sol. Put these helper contracts at the top of the file:
> - `Box`, with `uint256 public number`, `store(uint256 n)`, and `fail()`, which always reverts with "nope"
> - `ReentrantPayee`, which stores the Timelock and a salt. Its `receive()` calls
>   `timelock.execute(address(this), 1 ether, "", salt)` while the timelock's balance is at least 1 ether.
>
> Then `TimelockTest`, with `DELAY = 2 days`, `SALT = bytes32(uint256(1))`, makeAddr for admin, guardian and stranger,
> `data = abi.encodeCall(Box.store, (42))`, and a helper `_queue()` that queues that call to the box as admin and
> returns the id. Tests, using exactly these names:
> 1. test_QueueStoresReadyTimeAndEmits: check Queued with vm.expectEmit, and the stored readyAt
> 2. test_RevertWhen_StrangerQueues: NotAdmin
> 3. test_RevertWhen_GuardianQueues: NotAdmin
> 4. test_RevertWhen_QueuedTwice: AlreadyQueued(id)
> 5. test_SameActionWithNewSaltIsSeparate: the two ids differ
> 6. test_RevertWhen_ExecutedOneSecondEarly: warp to readyAt - 1, expect NotReady(id, readyTime)
> 7. test_ExecutesExactlyAtReadyTime: warp to readyAt, a stranger executes, box.number() is 42, readyAt is back to 0
> 8. test_ExecutesOnLastSecondOfGracePeriod: warp to readyAt + GRACE_PERIOD, it still runs
> 9. test_RevertWhen_ExecutedAfterGracePeriod: one second later, expect Expired(id, deadline)
> 10. test_RevertWhen_NeverQueued: NotQueued(id)
> 11. test_RevertWhen_ExecutedTwice: the second execute reverts with NotQueued(id)
> 12. test_FailedCallStaysQueuedAndRetryable: queue Box.fail, execute reverts with ExecutionFailed, readyAt is still set
> 13. test_GuardianCancels: the guardian cancels, then after the delay execute reverts with NotQueued(id)
> 14. test_AdminCancels: readyAt is 0 afterward
> 15. test_RevertWhen_StrangerCancels: NotAdminOrGuardian
> 16. test_RevertWhen_SetDelayCalledDirectly: the admin calls setDelay directly, expect NotSelf
> 17. test_SetDelayGoesThroughTheQueue: queue a setDelay(3 days) call to the timelock itself, warp, execute, delay() is 3 days
> 18. test_RevertWhen_NewDelayOutOfRange: the same flow with 1 minutes, execute reverts with ExecutionFailed
> 19. test_RevertWhen_ConstructorDelayOutOfRange: DelayOutOfRange(1 minutes)
> 20. test_ReentrantPayeeCannotDrain: fund the timelock with 5 ether, deploy ReentrantPayee, queue a 1 ether payment to it,
>     warp, and call execute inside `try ... {} catch {}`. Then assert the payee's balance plus the timelock's balance is
>     5 ether, and the timelock still holds at least 4 ether, with the message "timelock drained".
> 21. testFuzz_NeverExecutesBeforeReadyTime: bound the wait from 0 to DELAY - 1, warp forward by it, expect NotReady
>
> Run forge fmt, then forge test -vv, and show me the output.

**You check:** open `test/Timelock.t.sol`.
- Tests 6, 7, 8 and 9 sit on the exact edges of the time window. Find the `vm.warp` line in each.
- Test 18 expects `ExecutionFailed`, not `DelayOutOfRange`. Ask Claude: *"Why does the inner error change to
  ExecutionFailed by the time it reaches the test? What does the caller lose because of that?"*
- In `testFuzz_NeverExecutesBeforeReadyTime`, the `bound` call has an upper limit of `DELAY - 1`. Ask: *"What would
  happen if the upper limit were DELAY?"*

Now prove a test protects something. Type this (no plan mode needed):

> Break @src/Timelock.sol on purpose: in execute, change `block.timestamp < readyTime` to `block.timestamp <= readyTime`.
> Don't touch the tests. Run forge test and tell me which tests fail and why. Then change it back and run forge test again.

You should see 5 tests fail, including `test_ExecutesExactlyAtReadyTime`, and then all 21 pass again after the change
is undone. One changed character breaks five tests, so this boundary is well protected.

> ℹ️ `forge build` may print a `note[screaming-snake-case-immutable]` lint note about `ReentrantPayee`. It's a naming-style
> note, not an error. CI still passes.

**Done when:** `!forge test -vv` ends with `21 tests passed, 0 failed`, the fuzz line shows `runs: 256`, and `!git status`
shows only the new test file.

**Commit:** `Add Timelock unit, boundary, reentrancy and fuzz tests`

---

## Step 3 — The full stack: multisig → timelock → fee controller (15 min)

**Learn.** Now you put Tuesday's contracts and today's together:

```text
Alice, Bob, Carol        Guardian (separate key)
       │ 2 of 3              │ cancel only
       ▼                     ▼
    MultiSig ──queue──►   Timelock ──after the delay──►  FeeController
    (who may act)         (when it may act)              (admin = the Timelock)
```

`FeeController.admin` is the **timelock**, not the multisig. So even a valid 2-of-3 approval can't change the fee
directly. The only path goes through the public queue.

Your multisig tests showed that one stolen key can't do anything alone. Today's main test goes further: **two** stolen
keys pass the multisig, which is exactly the case your Tuesday README said it couldn't handle. The guardian still stops them.

**Prompt (plan mode):**
> Create test/Stack.t.sol for @src/Timelock.sol, @src/MultiSig.sol and @src/FeeController.sol. In setUp, deploy
> `MultiSig([alice, bob, carol])`, then `Timelock(address(multisig), guardian, 2 days)`, then
> `FeeController(address(timelock))`. Use makeAddr for alice, bob, carol, guardian and stranger.
> Add `_viaMultisig(address to, bytes memory data, address first, address second)`: `first` submits and approves,
> `second` approves, `first` executes.
> Add `_queueFee(uint256 newFee, address first, address second)`: it builds the setFee calldata and sends a
> Timelock.queue call through _viaMultisig, then returns the id and the calldata.
> Tests, using exactly these names:
> 1. test_FeeChangesAfterDelay: alice and bob queue a fee of 100, warp 2 days, a stranger executes, feeBps is 100
> 2. test_TwoStolenKeysStoppedByGuardian: bob and carol (both keys stolen) queue a fee of 9999. Executing right away
>    reverts with NotReady. The guardian cancels. After 2 days, execute reverts with NotQueued. feeBps is still 0.
> 3. test_MultisigCannotSkipTheTimelock: 2 of 3 owners approve a direct setFee call to the FeeController. Executing it
>    reverts with MultiSig.ExecutionFailed, and feeBps is still 0.
>
> Run forge fmt, then forge test -vv, and show me the output.

**You check:** open `test/Stack.t.sol`.
- In `setUp`, read the deployment order. Ask Claude: *"Why does the order have to be multisig, then timelock, then
  fee controller? Is there a circular dependency here?"*
- In `test_TwoStolenKeysStoppedByGuardian`, trace who calls what. Both stolen keys have done everything the multisig
  requires. Point to the line that actually stops them.
- Ask Claude: *"The attacker can queue the same action again with a new salt right after the guardian cancels it.
  What does that mean for the guardian?"* (Keep the answer for Known limitations.)

**Done when:** `!forge test` ends with `24 tests passed, 0 failed`.

**Commit:** `Add end-to-end tests for multisig, timelock and fee controller`

---

## Step 4 — Build the security reviewer subagent (15 min)

**Learn (Claude Code).** A custom subagent is one Markdown file:

- **`.claude/agents/`** holds this project's subagents. `~/.claude/agents/` holds subagents for all your projects.
- **The frontmatter** (the part between the `---` lines) has the settings:
  - `name`: how you refer to it.
  - `description`: tells Claude **when** to use it. Claude reads this to decide whether to delegate.
  - `tools`: the only tools it may use. Without this line, it gets everything. This is your permission rules idea from
    Day 0, applied to one specialist.
- **The body** is its system prompt: its job and how to report.

What it receives: its own instructions, your `CLAUDE.md`, a git status snapshot, and the task message your main session
writes for it. What it **doesn't** receive: your conversation. When it finishes, only its report comes back, so its
long file reads don't fill up your main session.

**Why `tools: Read, Grep, Glob` and no `Bash`?** You can't give a subagent only `forge test` through this line. Bash
is all or nothing here, and a reviewer with Bash could change files. A reviewer that can't edit can't "helpfully" fix
something you never reviewed.

**Prompt (no plan mode needed):**

> Create .claude/agents/security-reviewer.md with exactly this content:
>
> ```markdown
> ---
> name: security-reviewer
> description: Reviews Solidity contracts for security bugs. Use when asked for a security review or audit. Read-only: it reports findings and never changes code.
> tools: Read, Grep, Glob
> ---
>
> You are a senior smart contract security auditor. You did not write this code, and you assume it has a bug
> until you have tried to prove otherwise. You can read files but you can't run or change anything.
>
> Work in this order:
>
> 1. Read the contract named in your task, plus any contract it calls or inherits. Don't trust comments,
>    names, or documentation: check what the code actually does.
> 2. List the roles and what each one is trusted to do. Then state the contract's main security promise in
>    one sentence.
> 3. For each external or public function, ask how an attacker could use it to break that promise.
>    Consider every input the caller controls, every state change, the order of operations, and every
>    external call. Also consider a role acting maliciously, and a sequence of calls across several
>    transactions.
> 4. Before you report a finding, walk through the attack step by step against the real code. Drop it if a
>    check stops the attack. Never invent a finding to look thorough.
>
> Report in this format, most severe first:
>
> ### [Severity] Short title
> - **Where:** `file:line`, function name
> - **Attack:** numbered steps, from who calls what to what they gain
> - **Impact:** what is lost or broken
> - **Fix:** the smallest change that solves it
> - **Confidence:** High, Medium, or Low, and why
>
> Severity levels: Critical (funds or control lost with no special role), High (the main security promise
> is broken), Medium (needs unusual conditions), Low (minor), Info (design note, no attack).
>
> End with a section called **What I checked and found safe**, naming the checks you traced. If you found
> nothing above Info, say so plainly.
> ```

**Restart now.** Claude Code loads edits to an existing agents folder on its own, but `.claude/agents/` didn't exist
when this session started. So run `/exit`, then `claude`.

**Run it on your clean code.** In the prompt box, type `@security`, and pick the entry marked **(agent)** from the menu.
That guarantees this subagent runs. Then finish the sentence:

> @"security-reviewer (agent)" review src/Timelock.sol. Show me the full report.

If the menu doesn't show it, type this instead: `Use the security-reviewer subagent to review src/Timelock.sol. Show me
the full report.`

**You check:**
- In Claude Code's output, you should see the subagent running as its own item, not your main session reading the file.
- When I tested this reviewer on the correct contract, it found **nothing above Low**. It reported things like: a failed
  call hides the target's revert reason, an expired action blocks re-queueing the same ID until it's cancelled, and
  `admin` and `guardian` can't be rotated. Your run will differ somewhat, because the reviewer isn't deterministic.
- **Don't accept the report on trust.** Reviewers can be wrong in both directions. Pick the top finding, then ask your
  **main** session (not the reviewer):

> For the top finding in that report, open the code and tell me if it's real. Walk through it step by step
> and say what stops it, if anything. Don't change any files.

- Copy any real finding you decide not to fix into a scratch note. Step 5's `/clear` erases the report from your
  session, and you'll paste those findings into Step 6's prompt.

**Done when:** you have a report, and `!git status` shows `.claude/agents/security-reviewer.md` as the **only** change.
That proves the reviewer changed nothing.

**Commit:** `Add read-only security-reviewer subagent`

Commit **now**, before Step 5. Git is your safety net while you experiment.

---

## Step 5 — Test your reviewer: plant a bug it has never seen (15 min)

**Learn.** A security tool is only worth trusting if you've measured it. So you'll plant a real bug and run a **blind
test**. Three things keep it blind:

- **You edit the code by hand,** so no Claude session wrote the bug.
- **`/clear` wipes the main session,** so it can't pass hints into the task message.
- **The reviewer has no `Bash`,** so it can't run `git diff` to see what changed. Its git status snapshot only shows
  that `src/Timelock.sol` has been modified.

**The bug.** The action ID is what connects "what people reviewed" to "what runs". If the hash doesn't cover the
calldata, then the reviewed action and the executed action can be different. Instead of removing `data` (the compiler
warns about an unused parameter), you'll hash only its **length**, which compiles cleanly and looks deliberate.

**5a. Plant it.** Open `src/Timelock.sol` in your editor and find `getId`. Change this line by hand:

```solidity
return keccak256(abi.encode(target, value, data, salt));
```

to:

```solidity
return keccak256(abi.encode(target, value, data.length, salt));
```

Save the file. **Predict before you run it:** will the tests catch this?

```text
!forge test
```

`24 tests passed, 0 failed`, and no compiler warning. **Every test is green, and the timelock is broken.** Calldata
for `setFee(100)` and `setFee(9999)` is the same length, so anyone can queue the first and execute the second. The
hole in Step 2's list was that no test ever tried to execute something different from what was queued.

**5b. Run the blind review.** Clear the session, so the main Claude knows nothing:

```text
/clear
```

Then, using the `@` menu as before:

> @"security-reviewer (agent)" review src/Timelock.sol. Show me the full report.

**You check:**
- I ran this exact test twice. Both times, the top finding was at `getId`, rated **High** once and **Critical** once:
  the ID commits to `data.length`, not the calldata, so anyone can call `execute` with different calldata of the same
  length. Either rating is fine, as long as it's the top finding.
- **If yours misses the bug,** that's a real result too. Run it once more, and write what happened in your README.
  Then ask yourself how much you would have trusted a clean report.
- If Claude offers to fix it, say **no**. You'll restore the file yourself below.

**5c. Turn the finding into a test.** The bug is still in the file, so this test should fail, which proves it detects the bug:

**Prompt (plan mode):**
> Add these three tests to the TimelockTest contract in @test/Timelock.t.sol. Don't change anything in src/.
> 1. test_RevertWhen_DataDiffersFromQueued: queue with `_queue()`, warp to readyAt, then execute with calldata of the same
>    length, `abi.encodeCall(Box.store, (9999))`. Expect NotQueued with the id of the swapped action, from getId.
> 2. test_RevertWhen_ValueDiffersFromQueued: queue with `_queue()`, fund the timelock with 1 ether, warp, execute the same
>    call with value 1 ether. Expect NotQueued with that action's id.
> 3. test_RevertWhen_TargetDiffersFromQueued: queue with `_queue()`, deploy a second Box, warp, execute the same call on the
>    second Box. Expect NotQueued with that action's id.
>
> Run forge fmt, then forge test, and show me the output. I expect at least one test to fail. Don't try to fix it.

Claude may point out the bug in `getId` by itself, since it now reads that file. That's fine. Don't let it change `src/`.

**You check:** you should see

```text
[FAIL: next call did not revert as expected] test_RevertWhen_DataDiffersFromQueued()
```

and `26 tests passed, 1 failed`. That failure says the swapped action **ran**.

**5d. Fix it, using git.** Your hand edit isn't something rewind tracks, because rewind only tracks Claude's edits. Git
does the job instead, and it restores only this one file:

```text
!git restore src/Timelock.sol
!forge test
```

`27 tests passed, 0 failed`.

**Done when:** `!git status` shows only `test/Timelock.t.sol` as modified, and `!git diff --stat src/` prints nothing.

**Commit:** `Add tests that the executed action must match the queued action`

---

## Step 6 — README, INTERVIEW.md, push, green CI (15 min)

**Prompt 1 (README):**
> Update @README.md: replace the "Design decisions" TODO with short bullets on: why anyone can call execute, the grace
> period, why setDelay can only be called by the timelock itself, why the guardian can only cancel, why the FeeController's
> admin is the timelock and not the multisig, and why the action ID must hash the full calldata (mention my planted
> data.length bug and that all 24 tests stayed green). Replace the "Known limitations" TODO with:
> admin and guardian are immutable, a stolen admin can re-queue after every cancel so the guardian must keep watching,
> a stolen guardian can veto everything, the revert reason of a failed call is lost, an expired action must be cancelled
> before the same id can be queued again, there's no batching or dependencies between actions as in OpenZeppelin's
> TimelockController, and the delay only helps if someone is monitoring the Queued events.
> Also add these reviewer findings that I decided not to fix: <paste your scratch note here, or delete this sentence>.
> Mention that src/MultiSig.sol and
> src/FeeController.sol are copied from my multisig-wallet repo. Don't touch the "How I used Claude Code" section.

**Prompt 2 (INTERVIEW.md):**
> Fill in @INTERVIEW.md with these 5 questions and short model answers (5–8 sentences each), based on this code:
> 1. Why add a timelock on top of a multisig? What does each one protect against, and what can still go wrong with both in place? Use test_TwoStolenKeysStoppedByGuardian.
> 2. Walk through an action's life cycle in my Timelock. Why is there a grace period, why can anyone execute, and why must setDelay go through the queue?
> 3. I changed the ID hash to use data.length instead of data and all 24 tests stayed green. Why was that a critical bug, why did the tests miss it, and what does that say about test coverage?
> 4. OpenZeppelin's TimelockController had CVE-2021-39167 before 4.3.1: execute checked isOperationReady only after the call. How could an executor take over, and which lines of my execute prevent that kind of attack?
> 5. In the Beanstalk attack there was a one-day wait, yet the attacker still took the funds in one transaction. Why didn't the wait help, and where must a delay sit? What are the trade-offs of a long delay, for example in an emergency?

**You check:** read every answer. Rewrite at least one in your own words. If an answer says something you can't explain
out loud, ask Claude about it until you can. For Q4, the answer must name the real difference: OpenZeppelin checked readiness
after the call, and your `execute` checks it before.

**Write "How I used Claude Code" yourself** in `README.md`: what the subagent found on clean code, what happened in the
blind test, one finding you checked by hand, and whether you'd trust a clean report from it now.

**Done when:**

```bash
forge fmt --check && forge build && forge test -vv
```

all pass, with `27 tests passed, 0 failed`. Then commit and push (Claude will ask before `git push`):

**Commit:** `Add README design notes and interview Q&A`

Then check CI:

```text
!gh run list --branch main --limit 1
```

Wait until the newest run shows success (a ✓, or `completed` / `success`). Re-run the command every few seconds while it
says `in_progress`. If it fails, open it with `!gh run view <id> --log-failed`, then ask Claude to fix it.

**Optional (2 min): use the reviewer everywhere.** Copy it to your user-level folder, so every future project has it:

```bash
mkdir -p ~/.claude/agents
cp .claude/agents/security-reviewer.md ~/.claude/agents/
```

Next time you start Claude Code, it's available in any repo. Good first uses: the Week 2 ERC-4626 vault, and the
"Break it, fix it" weekend.

---

## When you're done

Tell the roadmap chat **"done"**. It will review the repo, run the tests, and tick this row in the roadmap.

## Level up

**Give the reviewer a different job from the builder, and measure it before you trust it.** A subagent has fresh context,
limited tools, and a single job, so use one whenever you'd want a second person: for reviews, or for anything noisy that
would fill your main session. Keep its tools as narrow as the job allows. Then plant a bug and run it blind, because a
clean report means nothing until you've seen the reviewer catch something. And when it finds a real bug, don't stop at the
fix: turn the finding into a test first, so that bug can never quietly come back.
