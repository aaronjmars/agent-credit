# Contributing to Agent Credit

Thanks for helping make agent credit delegation safer and more useful. The scripts
are plain bash + Foundry's `cast`, so they run anywhere with a shell — and because
they move real funds against a human's collateral, **correctness and the safety
checks are the whole point.** Read [`safety.md`](../safety.md) and
[`SECURITY.md`](SECURITY.md) before touching the borrow path.

## Ways to contribute

- **Bug fixes to the scripts** (`aave-borrow.sh`, `aave-repay.sh`,
  `aave-setup.sh`, `aave-status.sh`) — especially the safety checks.
- **New chain / asset support** — extend `config.example.json`,
  [`deployments.md`](../deployments.md), and [`contracts.md`](../contracts.md).
- **Test coverage** — more scenarios in `tests/` against the mock `cast`.
- **Docs** — clearer setup, safety, or contract references.

## Before you start

- **Fork and branch from `main`.** Use a descriptive branch name (`feat/…`,
  `fix/…`, `docs/…`).
- **One change per PR.** Don't bundle unrelated edits.
- **Title as a [Conventional Commit](https://www.conventionalcommits.org/)** —
  `feat: …`, `fix: …`, `docs: …`. PRs are squash-merged, so the title becomes the
  commit subject.
- **Never weaken a safety check without tests proving it's still safe.** The
  borrow-time checks (delegation cap, projected health factor, cross-asset
  normalization, gas floor) are load-bearing — see PRs #5–#7 for the bar.
- **Never commit a real key.** `config.json` (with `agentPrivateKey`) is
  gitignored; only `config.example.json` is tracked, with placeholder values.

## Development setup

**Prerequisites:** a POSIX shell, [Foundry](https://book.getfoundry.sh/) (`cast`),
plus `jq` and `bc`.

```bash
git clone https://github.com/aaronjmars/agent-credit.git && cd agent-credit
cp config.example.json config.json      # then fill in your own values (gitignored)
./aave-setup.sh                          # verify config, deps, and delegation status
```

The scripts are for the **agent** to run; the delegator only approves delegation
on-chain. Test against a throwaway agent wallet before anything real.

## Testing & CI

CI (`.github/workflows/ci.yml`) runs two jobs on every push and PR:

```bash
# 1. Lint every script (the CI gate uses --severity=warning)
shellcheck --severity=warning aave-borrow.sh aave-repay.sh aave-setup.sh \
  aave-status.sh tests/test-borrow-contract.sh tests/mocks/cast

# 2. Contract tests — exercise aave-borrow.sh against a mock cast (no network, no RPC)
bash tests/test-borrow-contract.sh      # needs jq + bc
```

`tests/mocks/cast` is a stub that emits canned RPC responses per scenario, so the
suite runs fully offline. **Add or extend a scenario there for any change to the
borrow logic** — a fix without a failing-then-passing test won't land.

## Submitting a pull request

- Keep the diff focused and the title conventional; it becomes the squash commit.
- Explain **what** changed and **why**; link the issue (`Fixes #123`).
- `shellcheck --severity=warning` is clean and `tests/test-borrow-contract.sh`
  passes locally.
- If you touched a safety check, describe the scenario you added and why the check
  still holds.

## Reporting bugs & requesting features

Open an issue with the script, chain, Aave version, and a (key-redacted) repro.

**Found a way to bypass the safety checks or leak the key?** Don't open an issue —
that's directly exploitable. Follow [`SECURITY.md`](SECURITY.md) and report it
privately.

## License

By contributing, you agree that your contributions are licensed under the
repository's [LICENSE](LICENSE).
