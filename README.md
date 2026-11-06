# timelock

A timelock that delays admin actions behind a 2-of-3 multisig, with a guardian who can cancel queued actions

Part of my [learning roadmap](https://github.com/Syriacode/Mini-Blockchain/blob/main/ROADMAP.md).

| | |
|---|---|
| Language | solidity |
| Claude Code technique practiced | custom subagent (security reviewer) |

## Run it

```bash
forge build
forge test -vv
forge fmt --check
```

## Design decisions

`src/MultiSig.sol` and `src/FeeController.sol` are copied from my multisig-wallet repo. `src/Timelock.sol` is new here.

- **Anyone can call `execute`.** The decision was made when the action was queued, and the ID ties the caller to that exact action, so the caller only chooses when it runs. Offline keys can't strand an approved action.
- **Grace period of 14 days.** Approvals go stale. Without a deadline, an action approved long ago could be run much later, when conditions have changed.
- **Only the timelock can call `setDelay`.** The change has to go through the queue and wait out the current delay. Otherwise two stolen keys could cut the delay to the 1-hour minimum straight away, leaving the guardian little time to react to whatever they queue next.
- **The guardian can only cancel.** It can't queue anything, so a stolen guardian key can block actions but can't push through its own. This keeps the worst case at a freeze rather than theft.
- **The FeeController's admin is the timelock, not the multisig.** If the multisig were the admin, it could change the fee directly and skip the delay. `test_MultisigCannotSkipTheTimelock` covers this.
- **The action ID must hash the full calldata.** The ID is what ties an approval to an action. I planted a bug that hashed `data.length` instead of `data`, and all 24 tests stayed green. Anyone could then have run different calldata of the same length, such as `setFee(9999)` in place of `setFee(100)`. The tests only ever executed the data they had queued, so I added tests that execute with a different target, value, data, selector and salt.

## Known limitations

- `admin` and `guardian` are immutable, so neither can be replaced without redeploying.
- A stolen admin can re-queue after every cancel, so the guardian must keep watching.
- A stolen guardian can veto everything.
- The revert reason of a failed call is lost. `execute` reverts with a bare `ExecutionFailed()`.
- An expired action must be cancelled before the same ID can be queued again.
- There is no batching and there are no dependencies between actions, unlike OpenZeppelin's TimelockController.
- The delay only helps if someone is monitoring the `Queued` events.

## How I used Claude Code

### What I delegated

### What I reviewed

### A bug I caught

### Something I changed by hand

### What I'd do differently
