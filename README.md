# Weir Disperse

`src/Disperse.sol`: pays many recipients one ERC-20 in a single transaction on Robinhood Chain (chain id 4663,
Arbitrum Orbit). The Weir app uses it to pay several contest winners at once from the admin's own wallet, in USDG,
WEIR, IMD, WETH or any other plain ERC-20. The product never holds the money: funds move straight from the caller
to each recipient.

The source is byte-for-byte the `Disperse` already live on Base and Base Sepolia at
`0x320418D854f3eD0E59e691dD7c767A22B8E5C9E9` (pay-usdc). Nothing in it is chain or token specific.

**Not audited.** Tests and a swarm review are not an audit.

## Contract

- `disperse(token, to[], amounts[])`: `transferFrom(msg.sender → to[i], amounts[i])` for every row. Needs a prior
  approval of at least the sum.
- `disperseWithPermit(token, to[], amounts[], deadline, v, r, s)`: same, with an EIP-2612 permit for exactly the
  sum. `permit` is wrapped in `try/catch`, so a front-run replay of the signature cannot block the send; the
  allowance check afterwards is the real gate. When the permit fails AND the allowance is short, the permit's own
  revert reason is bubbled. On a token without `permit`, pass zeros and approve first.
- `sumOf(to[], amounts[])`: view helper, same validation, returns the total.
- Reverts: `Empty`, `LengthMismatch`, `ZeroRecipient(i)`, `SelfRecipient(i)` (the Disperse contract itself),
  `ZeroAmount(i)`, `InsufficientAllowance(needed, have)`.
- One event per call: `Dispersed(sender, token, total, count)`. Per-recipient detail is in the token's own
  `Transfer` logs, each with `from` = the caller, which is what the app's payout check reads.

Properties: no constructor arguments, no owner, no fee, no pause, no upgrade, no rescue, no storage. The contract
never holds tokens, so reentrancy cannot move anything the caller did not already approve. Fee-on-transfer and
rebasing tokens are unsupported and undetected. A batch is atomic: one recipient the token refuses (a frozen USDG
address, an address on IMD's owner-controlled blocklist) reverts the whole call and nothing moves; the revert
does not say which row.

What the caller (the app) must do, because the contract does not:

- Filter recipients. Only `address(0)` and the Disperse address are rejected. The token's own address,
  `0x…dEaD`, pools and other contracts are paid like anyone else, and holder lists contain them.
- Simulate each batch first (`eth_call`) and split on a revert to find the refused row.
- Trust logs only from known tokens and from the recorded Disperse address. A made-up token can emit
  `Transfer` and `Dispersed` with nothing moved, and `Dispersed.total` is what was asked, not proof of receipt.

## DisperseV2 (written, not deployed)

`src/DisperseV2.sol`: everything above, plus public messages. v1 stays deployed and keeps working; v2 is a separate
contract at a new address, because v1 cannot be changed.

- `disperse`, `disperseWithPermit`, `sumOf` and the `Dispersed` event keep v1's exact signatures.
- `disperseWithMemo(token, to[], amounts[], ref, memo, memos[], permit)`: the same send with
  - `ref`: the sender's own reference for the payout (the Weir app passes its payout id), zero if unused;
  - `memo`: a message for the whole payout, up to 280 bytes, may be empty;
  - `memos`: one message per recipient, up to 140 bytes each: an empty array, or one entry per recipient (any may be
    empty);
  - `permit`: `(deadline, v, r, s)` for exactly the sum; `deadline == 0` means none, use the allowance.
- Events: `Memo(sender, token, ref, total, count, memo)` once per call that has a reference or a payout memo;
  `Paid(sender, to, token, amount, ref, memo)` once per recipient whose own memo is not empty. `to` is indexed.
- New reverts: `MemoLengthMismatch`, `MemoTooLong(index)` (index is `type(uint256).max` for the payout memo),
  `TransferFailed(index, reason)`.

Two behaviours differ from v1 for callers of the kept functions:

- The token's own address is refused as a recipient (`SelfRecipient(i)`). v1 paid it and the money was stuck.
- A transfer the token refuses (a frozen or blocked recipient, a short balance) reverts with
  `TransferFailed(i, reason)`, naming the row, instead of the token's bare reason. The batch is still all or nothing.
  `reason` is the token's revert data cut to 256 bytes.

Reading v2's errors and events correctly:

- `TransferFailed(i)` says where the transfer failed, not whose fault it is. A frozen sender, or this contract
  being frozen by the token, fails at row 0 exactly as a frozen first recipient does; a balance that runs out names
  the first row it cannot cover; only the first failing row is named.
- `Memo` and `Paid` are notes, not proof. Anyone can emit any reference or address a note to anyone, using a token
  they made up or a dust amount of a real one. Trust them only for a sender and a token already known, and take the
  token's own `Transfer` logs as the record of what moved.

Reviewed 2026-11-12 by an independent adversarial pass: no critical or high findings; the `total` and `count` in
`Memo`, the wording above and several tests came out of it. Still not an audit.

**Messages are public and permanent.** They are copied from calldata into events and nothing else; they cannot
change who is paid or how much. Still no owner, no fee, no pause, no upgrade, no rescue, no storage, nothing payable.

Gas, from the live node's own estimate with real USDG and 250 fresh-balance recipients: about 8.54M with no memo
(34,100 each, the same as v1), 8.55M with a 280-byte payout memo, 10.6M with a 140-byte memo for every recipient
(42,500 each), against the chain's 32M per-transaction limit. The numbers the tests print are execution only and
vary with the forge version (33,656 and 39,689 per recipient on forge 1.5; higher on 1.8), which is why the tests
assert loose bounds and the absolute limit rather than exact figures.
The spec, the decisions behind it and the measured numbers are in the app repository at `docs/DISPERSE-V2.md`.

## Tokens on Robinhood Chain (checked on a fork, 2026-11-11)

| token | address | decimals | permit |
|---|---|---|---|
| USDG (Paxos Global Dollar) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` | 6 | yes, EIP-2612: `disperseWithPermit` works in one transaction |
| WEIR | `0x58b82fa656ecf47a0dca5be6bad06b92e22f7dbe` | 18 | no: approve, then `disperse` |

IMD (`0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127`, 18 decimals, no permit) and SVO also deliver exact amounts.
None of the four charges a transfer fee. USDG is an upgradeable proxy, so its behaviour can change.

Gas with real USDG: about 34,200 per fresh-balance recipient all in, so 250 recipients is about 8.6M (node
estimate) against the chain's 32M per-transaction maximum. The app caps a batch at 250, splits larger lists and
asks the node for the estimate rather than using a constant.

## Build and test

```sh
forge build
forge test
forge fmt --check
# fork tests against real USDG and WEIR; skipped when the variable is unset
RH_RPC_URL=https://robinhood-rpc.publicnode.com forge test --match-contract ForkTest -vv
```

90 tests. v1: 26 unit and fuzz (mocks for a 6-decimals permit token, a no-return token, a plain token and a
reentrant token) and 6 fork tests (USDG, WEIR, IMD). v2: 28 unit and fuzz of its own, v1's 25 pointed at it, and 5
fork tests, one of which freezes a recipient on the real USDG. `foundry.toml`, verbatim:

```toml
[profile.default]
src = "src"
test = "test"
out = "out"
libs = ["lib"]
solc = "0.8.26"
optimizer = true
optimizer_runs = 200
evm_version = "cancun"
via_ir = false
bytecode_hash = "none"
fs_permissions = []

[fuzz]
runs = 256

[profile.ci.fuzz]
runs = 2000

[rpc_endpoints]
robinhood = "${RH_RPC_URL}"
```

Dependencies are vendored under `lib/`: OpenZeppelin Contracts v5.5.0 and forge-std.

## Deploy

The IMD swarm deploys from `launch.json` (kind `evm_contracts`, chain 4663, no constructor arguments) after
auditing the repository as it arrived. v1 went out that way (request `docs/imd/launch-disperse-robinhood.json` in the
app repo, launch 3221). `launch.json` now names `DisperseV2` for its launch (`docs/imd/launch-disperse-v2.json`);
v1 is not deployed again. This folder is pushed to `weircool/disperse-contracts` as a subtree for that, as Townies is.

`script/Deploy.s.sol` is the owner's fallback: a deterministic CREATE2 deploy through the standard proxy at
`0x4e59b44847b379578588920cA78FbF26c0B4956C` (present on Robinhood Chain) that lands at the Base address
`0x320418D854f3eD0E59e691dD7c767A22B8E5C9E9`, refuses to broadcast if the bytecode drifted and skips when the
address already has code. A swarm deployment lands at the swarm deployer's own address instead; either works.
`script/DeployV2.s.sol` does the same for v2 (salt `weir.disperse.v2`, pinned `0x32133119DBb4e4C9Ba1b8cEDe3CA49C726F20983`).

## Deployed

| chain | id | address | tx |
|---|---|---|---|
| Robinhood Chain | 4663 | `0x49959c0326c4dF604a4d62D46CCBAe3C056CC158` | [`0xeae6a300…`](https://robin.etherscan.io/tx/0xeae6a3002240dd9eac8272d9cc27ea116b749a8b7bafc5611bfd55b12fd2bff5) (block 112219060) |

Deployed 2026-11-12 by the IMD swarm as launch 3221 from commit `f402a3a855b2f8f1c97aa0ea9367ebc975327eb3` of
this repository, after its review panel reported nothing at medium or above (two informational notes, both
described above: the atomic batch and the permit replacing a standing allowance). That panel is a first filter,
not an audit.

The deployed code is the tested code: `cast keccak $(cast code <address> --rpc-url $RH_RPC_URL)` gives
`0xb65a4cb1e0ebc66ee4e7d80658ed75d5013b6c01d003638138623e0968ba43ca`, the same runtime as on Base (checked
2026-11-12).

The app reads the address from `src/lib/robinhoodChain.ts` and the ABI from `public/weir/abi/Disperse.json`,
written with `forge inspect src/Disperse.sol:Disperse abi --json`.
