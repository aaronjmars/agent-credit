# Security Policy

Agent Credit lets an AI agent **borrow real funds against a human's Aave
collateral** via credit delegation. The scripts hold an agent private key, submit
on-chain borrows, and enforce the safety checks that stand between "autonomous
funding" and "drained wallet / liquidated position." That makes correctness here a
security property. This policy is about **reporting vulnerabilities**; for the
operational threat model and how to run it safely, see
[`safety.md`](../safety.md).

## Reporting a vulnerability

**Please don't open a public issue for a security problem** — a bypass of the
borrow safety checks is directly exploitable. Use GitHub's **Private Vulnerability
Reporting (PVR)**:

➡️ **[Report a vulnerability](https://github.com/aaronjmars/agent-credit/security/advisories/new)**

(Repo → **Security** tab → **Report a vulnerability**.) This opens a private
advisory that only the maintainers can see — never a public issue, so a fix can
ship before the details are out.

Please include what you can:

- The script and check affected (`aave-borrow.sh`, `aave-repay.sh`,
  `aave-setup.sh`, `aave-status.sh`).
- A minimal reproduction — ideally a scenario against `tests/mocks/cast` showing
  the check that should have failed but passed.
- The impact you can demonstrate — a borrow that exceeds the delegation cap,
  bypasses the projected-health-factor check, mishandles decimals/cross-asset
  normalization, leaks the agent key, or trusts unvalidated RPC data.
- Chain, Aave version (V2/V3), and the config you tested with (redact keys).

**Response targets** — best effort; this is a small project. Anything that risks
funds is triaged first:

| Stage | Target |
|-------|--------|
| Acknowledge the report | within 7 days |
| Initial assessment / severity | within 14 days |
| Fix or mitigation on `main` | as fast as the severity warrants |

We follow **coordinated disclosure**: please give us a reasonable window to ship a
fix before you disclose publicly. We'll credit you in the advisory unless you'd
rather stay anonymous.

## Supported versions

Security fixes land on the `main` branch of
[`aaronjmars/agent-credit`](https://github.com/aaronjmars/agent-credit).

| Version | Supported |
|---------|-----------|
| `main` (latest) | ✅ Yes |
| Older commits | ❌ No — pull latest |

## Security model

The safety guarantee is the **borrow-time checks** in `aave-borrow.sh`. A
vulnerability is anything that defeats them or the trust assumptions around them.

- **Delegation caps must bind.** Approvals are per debt token via
  `approveDelegation()`; the delegator sets explicit caps and should **never** use
  `type(uint256).max`. A borrow that exceeds the approved cap — including via
  cross-asset base-currency normalization or a decimals error — is a critical
  finding. (The cross-asset cap and projected-HF gaps closed in PRs #5–#7 are the
  reference bar; the `tests/test-borrow-contract.sh` fixtures encode them.)
- **Health factor must be projected, not just current.** A borrow that leaves the
  *current* HF healthy but drives the *projected* HF below `safety.minHealthFactor`
  must fail. Bypassing this risks liquidating the delegator's collateral.
- **The agent key is a low-trust hot wallet.** `config.json` holds
  `agentPrivateKey`; it must stay gitignored and hold only gas. Any path that logs,
  commits, or exfiltrates it is in scope. Real capital comes from the delegator's
  position, so the delegation cap — not the agent's balance — is the true limit.
- **Prompt injection → wallet drain is the headline risk.** As in
  [`safety.md`](../safety.md), an attacker who injects instructions into the agent
  could try to borrow the max delegated amount and move it. Mitigations live in the
  caps and checks above; a bug that weakens them is a vulnerability.
- **RPC data is a trust input.** The scripts read balances, prices, and HF from an
  RPC endpoint. Logic that can be fooled by a malicious/misconfigured RPC into
  approving an unsafe borrow is in scope.

## Scope

**In scope:**

- Borrowing beyond the delegation cap, or defeating the projected-HF / gas-floor /
  cross-asset checks.
- Disclosure or exfiltration of the agent private key or other secrets.
- Decimal, unit, or normalization errors that under-count a borrow against its cap.
- Injection or argument handling in the scripts that leads to unintended
  transactions.

**Out of scope:**

- The delegator's own risky configuration (an over-large cap, `minHealthFactor`
  set too low, an uncapped `approveDelegation`, market volatility causing
  liquidation within the configured limits).
- Vulnerabilities in Aave, Foundry/`cast`, the RPC provider, or an agent framework
  (OpenClaw, Claude Code, Bankr) — report those to the respective project.
- Losses from ordinary market movements while operating inside the safety limits.

---

> **Maintainers:** the Report-a-vulnerability link only works once PVR is enabled
> — **Settings → Code security and analysis → Private vulnerability reporting →
> Enable**.

Thanks for helping keep Agent Credit — and the collateral behind it — safe.
