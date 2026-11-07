# PikoPool

An on-chain mining pool for [PIKO](https://www.piko.network/), running on the Internet Computer.

Miners submit shares, meaning nonces that clear a lower difficulty than the network target. When a share also clears the real difficulty, the pool submits it to PIKO's `mother` canister under its own principal. The block reward is then split in proportion to the shares each miner contributed since the last win.

- **Canister:** `feqm6-7aaaa-aaaap-quzsa-cai`
- **Commission:** none. 100% of each block's PIKO reward goes to participants.
- **Mining fee:** each participant pays their share of the block's ICP fee before the proof is submitted. To do that, they approve the pool once on the ICP ledger. A participant who cannot pay gets no reward for that round. If the proof then fails, the fee is refunded minus ledger fees.
- **Client:** [PikoNativeMiner](https://github.com/icpbuilder01/pikonativeminer) has a pool mode.

## How it works

The pool caches the current work from `mother`, and refreshes it every 10 seconds only while a miner is active. A miner counts as active for 60 seconds after a heartbeat or a share. With no active miners, the pool makes no calls to `mother`.

Each nonce can only be credited once per round. Rewards stay in the pool until claimed with `claimPoolReward`, and the ledger fee comes out of the amount claimed.

The canister's controllers can still upgrade it. Check the current controllers and module hash before relying on it:

```
icp canister status feqm6-7aaaa-aaaap-quzsa-cai -n ic
```

## Local development

Deploys the pool against test versions of `mother` and the two ledgers, never the mainnet ones:

```
./scripts/deploy-local.sh
```

Requires [icp-cli](https://github.com/dfinity/icp-cli) and [mops](https://mops.one/).

## License

MIT
