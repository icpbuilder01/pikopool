#!/usr/bin/env bash
# Deploys PikoPool to its own local ICP network (free, for development/
# testing) against test-mother/test-icp-ledger/test-piko-ledger, never the
# real mainnet mother/ledgers. Same two-phase trick as piko-icp/pikopoker's
# own deploy-local.sh: test-piko-ledger's minting_account must be
# test-mother's own principal, which only exists once test-mother has been
# created.
set -euo pipefail
cd "$(dirname "$0")/.."

get_or_create() {
  icp canister create "$1" -q 2>/dev/null || icp canister status "$1" -i
}

echo "==> Writing placeholder ledger init args so the project can load..."
PLACEHOLDER="2vxsx-fae" # anonymous principal, syntactically valid placeholder
sed "s/__DEPLOYER_PRINCIPAL__/$PLACEHOLDER/" test-icp-ledger/icrc1_ledger_init.args.template > test-icp-ledger/icrc1_ledger_init.args
sed -e "s/__TEST_MOTHER_PRINCIPAL__/$PLACEHOLDER/" -e "s/__DEPLOYER_PRINCIPAL__/$PLACEHOLDER/" \
  test-piko-ledger/icrc1_ledger_init.args.template > test-piko-ledger/icrc1_ledger_init.args

echo "==> Starting local ICP network..."
icp network start -d

echo "==> Creating test-mother to reserve its principal..."
TEST_MOTHER_ID=$(get_or_create test-mother)
DEPLOYER_ID=$(icp identity principal)
echo "    test-mother principal: $TEST_MOTHER_ID"
echo "    deployer principal:    $DEPLOYER_ID"

echo "==> Regenerating ledger init args with real principals..."
sed "s/__DEPLOYER_PRINCIPAL__/$DEPLOYER_ID/" test-icp-ledger/icrc1_ledger_init.args.template > test-icp-ledger/icrc1_ledger_init.args
sed -e "s/__TEST_MOTHER_PRINCIPAL__/$TEST_MOTHER_ID/" -e "s/__DEPLOYER_PRINCIPAL__/$DEPLOYER_ID/" \
  test-piko-ledger/icrc1_ledger_init.args.template > test-piko-ledger/icrc1_ledger_init.args

echo "==> Deploying both test ledgers (reinstall -- minting_account can't change via upgrade)..."
for c in test-icp-ledger test-piko-ledger; do
  icp canister create "$c" -q 2>/dev/null || true
  icp build "$c"
  icp canister install "$c" --mode reinstall --args-file "$c/icrc1_ledger_init.args" -y
done

echo "==> Deploying test-mother and pikopool..."
icp deploy test-mother pikopool -y

TEST_ICP_LEDGER_ID=$(icp canister status test-icp-ledger -i)
TEST_PIKO_LEDGER_ID=$(icp canister status test-piko-ledger -i)
PIKOPOOL_ID=$(icp canister status pikopool -i)

echo "==> Wiring test-mother to the local test ledgers..."
icp canister call test-mother testSetLedgers "(principal \"$TEST_PIKO_LEDGER_ID\", principal \"$TEST_ICP_LEDGER_ID\")"

echo "==> Wiring pikopool to test-mother and the local test ledgers..."
icp canister call pikopool setMotherId "(principal \"$TEST_MOTHER_ID\")"
icp canister call pikopool setPikoLedgerId "(principal \"$TEST_PIKO_LEDGER_ID\")"
icp canister call pikopool setIcpLedgerId "(principal \"$TEST_ICP_LEDGER_ID\")"

echo ""
echo "==> Done. Canister ids:"
echo "    test-mother:      $TEST_MOTHER_ID"
echo "    test-icp-ledger:  $TEST_ICP_LEDGER_ID"
echo "    test-piko-ledger: $TEST_PIKO_LEDGER_ID"
echo "    pikopool:         $PIKOPOOL_ID"
echo ""
echo "==> To fund pikopool with test-ICP (so it can pay test-mother's mining fee), mint from the deployer and send some to pikopool's own principal:"
echo "    icp canister call test-icp-ledger icrc1_transfer \"(record { to = record { owner = principal \\\"$PIKOPOOL_ID\\\" }; amount = 100_000_000_000 })\""
echo "==> Then have pikopool approve test-mother as a spender:"
echo "    icp canister call pikopool refreshMotherApproval"
echo "==> Set a real mining fee on test-mother to exercise that path (0 by default):"
echo "    icp canister call test-mother testSetWork \"(16, 100_000_000_000, 10_000)\""
