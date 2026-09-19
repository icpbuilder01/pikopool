import Principal "mo:core/Principal";
import Int "mo:core/Int";
import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Array "mo:core/Array";
import Time "mo:core/Time";
import Runtime "mo:core/Runtime";
import Timer "mo:core/Timer";
import Map "mo:core/Map";
import List "mo:core/List";
import Iter "mo:core/Iter";
import Sha256 "mo:sha2/Sha256";
import Types "types";

// PikoPool -- an on-chain, proportional-per-round mining pool for PIKO.
// Turns "rare full jackpot, most people never win" into small, steady,
// shared payouts: participants submit "shares" (nonces clearing a lower,
// easier difficulty than the real network target) for credit, and
// whenever a share also happens to clear the REAL network difficulty,
// this canister submits it to `mother` under its OWN principal and splits
// the reward across everyone who contributed a share since the last win.
//
// Zero commission: hosting/ops for the whole PIKO family (including this
// canister's own ICP fee to `mother`) is already subsidized by the mining
// auto-top-up system, so 100% of every won block's PIKO reward is split
// among participants. See mother/src/main.mo in the piko-icp repo for the
// protocol this integrates with (unmodified -- this canister is purely
// additive).
actor self {
  // ---- Configuration (settable pre-lock, mirrors pikopoker's
  // setPikoLedgerId/lockPikoLedgerId pattern for the same reason: lets
  // local testing point at test canisters, then gets locked once mainnet
  // behavior is verified) ----
  var motherId : Principal = Principal.fromText("45mjf-rqaaa-aaaaj-qsedq-cai");
  var motherIdLocked : Bool = false;
  var pikoLedgerId : Principal = Principal.fromText("56aad-fiaaa-aaaaj-qsefa-cai");
  var pikoLedgerIdLocked : Bool = false;
  var icpLedgerId : Principal = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
  var icpLedgerIdLocked : Bool = false;

  func requireController(caller : Principal) {
    if (not Principal.isController(caller)) {
      Runtime.trap("caller is not a controller");
    };
  };

  public shared ({ caller }) func setMotherId(id : Principal) : async () {
    requireController(caller);
    if (motherIdLocked) { Runtime.trap("motherId is locked") };
    motherId := id;
  };
  public shared ({ caller }) func lockMotherId() : async () {
    requireController(caller);
    motherIdLocked := true;
  };
  public shared ({ caller }) func setPikoLedgerId(id : Principal) : async () {
    requireController(caller);
    if (pikoLedgerIdLocked) { Runtime.trap("pikoLedgerId is locked") };
    pikoLedgerId := id;
  };
  public shared ({ caller }) func lockPikoLedgerId() : async () {
    requireController(caller);
    pikoLedgerIdLocked := true;
  };
  public shared ({ caller }) func setIcpLedgerId(id : Principal) : async () {
    requireController(caller);
    if (icpLedgerIdLocked) { Runtime.trap("icpLedgerId is locked") };
    icpLedgerId := id;
  };
  public shared ({ caller }) func lockIcpLedgerId() : async () {
    requireController(caller);
    icpLedgerIdLocked := true;
  };

  // ---- Share difficulty (controller-adjustable, no timelock needed --
  // same reasoning as mother's setMiningFeeE8s: moves credit-granularity
  // for everyone equally, can't target anyone, low blast radius) ----
  var shareDifficultyBits : Nat = 16; // conservative default, tune after watching real submission volume

  public shared ({ caller }) func setShareDifficultyBits(bits : Nat) : async () {
    requireController(caller);
    shareDifficultyBits := bits;
  };

  // Generous fixed allowance cap for mother's own ICP fee pulls -- refreshed
  // on demand (see refreshMotherApproval) rather than on a timer, since
  // icrc2_approve itself costs a real ledger transfer fee each time and the
  // mining fee rarely changes. 1 ICP is comfortably above any plausible
  // per-block miningFeeE8s for the foreseeable future; controller-adjustable
  // if that ever stops being true.
  var approvalCapE8s : Nat = 100_000_000;
  public shared ({ caller }) func setApprovalCapE8s(e8s : Nat) : async () {
    requireController(caller);
    approvalCapE8s := e8s;
  };

  // ---- Cached job (refreshed periodically from mother; see the timer
  // arming at the bottom of this file) ----
  var cachedWork : Types.Work = {
    height = 0;
    previousHash = Blob.fromArray([]);
    difficultyBits = 256; // impossible to satisfy -- safe default before the first real refresh lands
    reward = 0;
    miningFeeE8s = 0;
  };
  let REFRESH_INTERVAL_SECONDS : Nat = 10;
  transient var workTimerId : ?Timer.TimerId = null;

  func refreshCachedWork() : async () {
    let Mother : Types.MotherActor = actor (Principal.toText(motherId));
    try {
      cachedWork := await Mother.getWork();
    } catch (_e) {
      // Best-effort -- next timer tick (or the next submitShare's own
      // early-refresh trigger) tries again; a transient failure here just
      // means a few seconds of shares get rejected as stale, never a
      // wrong/unsafe state.
    };
  };

  public shared func refreshMotherApproval() : async Types.ApproveResult {
    let IcpLedger : Types.LedgerActor = actor (Principal.toText(icpLedgerId));
    await IcpLedger.icrc2_approve({
      from_subaccount = null;
      spender = { owner = motherId; subaccount = null };
      amount = approvalCapE8s;
      expected_allowance = null;
      expires_at = null;
      fee = null;
      memo = null;
      created_at_time = null;
    });
  };

  // ---- Share bookkeeping ----
  // currentRoundShares/pendingPoolRewards are real, specific value owed to
  // specific participants -- must be persisted (plain `let`), NOT
  // transient. Mirrors mother.mo's own pendingRewards, whose comment spells
  // out exactly this mistake ("as an earlier version of this file did")
  // and why it matters: `transient` here would silently zero every
  // participant's owed PIKO on the canister's very first upgrade. Found
  // the hard way during local testing (2026-09-18) before this ever went
  // near mainnet -- see PIKO_LEDGER_FEE's comment below for the other real
  // bug found in the same session.
  let currentRoundShares : Map.Map<Principal, Nat> = Map.empty<Principal, Nat>();
  let pendingPoolRewards : Map.Map<Principal, Nat> = Map.empty<Principal, Nat>();
  // Every nonce ever credited this round, regardless of who submitted it --
  // NOT scoped per-caller, since the hash only depends on
  // (previousHash, height, nonce), never on the caller: two different
  // principals submitting the identical nonce would otherwise both get
  // credited for the exact same one-time proof of work. Without this,
  // resubmitting one already-credited nonce every MIN_SHARE_INTERVAL_NANOS
  // for the rest of the round manufactures unlimited share credit for zero
  // additional work -- confirmed live during a 2026-09-18 post-crash
  // re-verification session (one real share replayed 5x -> 6 credited
  // shares from a single hash computation). Persisted (plain `let`), same
  // reasoning as currentRoundShares/pendingPoolRewards above, and cleared
  // alongside currentRoundShares at the end of each round in
  // distributeRoundReward.
  let usedNoncesThisRound : Map.Map<Nat, ()> = Map.empty<Nat, ()>();
  // Just an anti-spam rate-limit cache, safe to lose on upgrade -- same
  // reasoning as mother's own transient lastAttempt map.
  transient let lastShareAttempt : Map.Map<Principal, Int> = Map.empty<Principal, Int>();
  let MIN_SHARE_INTERVAL_NANOS : Int = 300_000_000; // 0.3s, same anti-spam reasoning as mother's own MIN_SUBMIT_INTERVAL_NANOS

  // Presence tracking, entirely separate from share credit -- a share only
  // arrives when someone gets lucky against shareDifficultyBits (a Poisson
  // process, rare enough that "distinct principals credited a share since
  // the last win" can't answer "who's mining right now"). The client pings
  // this on a fixed cadence while actively mining, independent of whether
  // any given search attempt happens to clear a share. Just a liveness
  // signal, safe to lose on upgrade -- same class as lastShareAttempt.
  transient let lastSeenAt : Map.Map<Principal, Int> = Map.empty<Principal, Int>();
  let ACTIVE_WINDOW_NANOS : Int = 60_000_000_000; // 60s -- comfortably above the client's own heartbeat interval

  public shared ({ caller }) func heartbeat() : async () {
    if (Principal.isAnonymous(caller)) { return };
    Map.add(lastSeenAt, Principal.compare, caller, Time.now());
  };

  // Fixed for the ICP ledger's whole history, same constant mother/
  // PikoNativeMiner both hardcode. Real cost of THIS canister's own
  // ICP balance per won block is `miningFeeE8s + this fee` -- mother's own
  // icrc2_transfer_from pull (see submitProof there) debits its `from`
  // (this canister) for `amount + fee`, not just `amount`. Must be folded
  // into what's collected from participants below, or the pool leaks
  // exactly this much on every single block forever, however small.
  let ICP_LEDGER_FEE_E8S : Nat = 10_000;

  var blocksWon : Nat = 0;
  var totalSharesAllTime : Nat = 0;
  var totalPikoDistributed : Nat = 0;

  func natToBytes8(n : Nat) : [Nat8] {
    let n64 = Nat64.fromNat(n);
    Array.tabulate<Nat8>(8, func(i) { Nat8.fromNat(Nat64.toNat((n64 >> Nat64.fromNat((7 - i) * 8)) & 0xFF)) });
  };

  func leadingZeroBits(b : Blob) : Nat {
    let bytes = Blob.toArray(b);
    var count = 0;
    label scan for (byte in bytes.vals()) {
      if (byte == 0) { count += 8 } else {
        var v = byte;
        var i = 0;
        while (i < 8 and (v & 0x80) == 0) { count += 1; v := v << 1; i += 1 };
        break scan;
      };
    };
    count;
  };

  // Exact same header layout as mother.mo/pikonativeminer's miner.rs/the
  // GPU shader: sha256(previousHash(32) || height(8, BE) || nonce(8, BE)).
  func computeHash(prev : Blob, atHeight : Nat, nonce : Nat) : Blob {
    Sha256.fromArray(#sha256, Array.concat(Array.concat(Blob.toArray(prev), natToBytes8(atHeight)), natToBytes8(nonce)));
  };

  // Collects each participant's proportional share of the ICP mining fee
  // this canister just advanced to mother, THEN credits their PIKO reward
  // -- no successful collection, no reward, full stop. This is the entire
  // sustainability mechanism: without it, this canister's own ICP balance
  // (only ever seeded once, up front) would slowly drain to zero as it
  // keeps advancing mother's fee on every win with no way to replenish
  // itself, which doesn't scale and isn't something the dev should have
  // to keep topping up by hand forever (found while designing this: the
  // family's existing `topUpProject` auto-funding only distributes
  // CYCLES, never ICP tokens, so it cannot cover this cost at all).
  // Requires each participant to have `icrc2_approve`d this canister on
  // the ICP ledger beforehand (same one-time gesture as approving mother
  // for solo mining) -- a participant who never approves simply forfeits
  // that round's share, with no separate pre-check needed anywhere else.
  func distributeRoundReward(reward : Nat, totalFeeE8s : Nat) : async () {
    var total = 0;
    for ((_, c) in Map.entries(currentRoundShares)) { total += c };
    if (total == 0) { return }; // shouldn't happen -- this only runs right after crediting a share this round

    // Snapshot now, before any awaits below -- submitShare calls that land
    // concurrently during fee collection add to currentRoundShares (and
    // usedNoncesThisRound) for the NEXT round and must not be touched by
    // this round's payout or cleanup.
    let entries = Iter.toArray(Map.entries(currentRoundShares));
    let usedNonceKeysThisRound = Iter.toArray(Map.keys(usedNoncesThisRound));
    let IcpLedger : Types.LedgerActor = actor (Principal.toText(icpLedgerId));

    // Pass 1 -- cheap allowance PRE-check (query, moves no funds) against
    // each participant's own nominal share of the full fee. This is what
    // makes the redistribution below order-independent: without it, a
    // non-payer only inflates what LATER entries (in Map's own iteration
    // order, effectively arbitrary) end up owing, and does nothing at all
    // if they happen to be ordered last. Anyone who fails this check is
    // excluded from `payableTotal` up front, so every eligible entry's
    // real feeShare below is computed against the same, already-correct
    // pool of payers regardless of iteration order.
    var payableTotal = 0;
    let eligible = List.empty<Bool>();
    for ((p, c) in entries.vals()) {
      let nominalShare = totalFeeE8s * c / total;
      let ok = if (nominalShare == 0) { true } else {
        let allowance = try {
          ?(
            await IcpLedger.icrc2_allowance({
              account = { owner = p; subaccount = null };
              spender = { owner = Principal.fromActor(self); subaccount = null };
            })
          );
        } catch (_e) { null };
        switch (allowance) {
          case (?a) a.allowance >= nominalShare;
          case null false;
        };
      };
      if (ok) { payableTotal += c };
      List.add(eligible, ok);
    };

    var distributed = 0;
    var highestPrincipal : ?Principal = null;
    var highestCount = 0;
    // Pass 2 -- waterfall allocation among the pre-checked-eligible cohort
    // only: feeShare is recomputed against `shareWeight` (starts at
    // payableTotal, shrinks as each eligible entry is processed) rather
    // than a fixed per-participant amount, so if a real transfer_from
    // still fails despite passing pass 1 (e.g. real balance short despite
    // a healthy allowance -- rarer, but the pre-check can't catch it),
    // whoever's processed after them absorbs the gap the same way.
    // Without either pass, a single non-paying participant permanently
    // drained pikopool's own ICP reserve by exactly their share, every
    // single win, with nothing else ever making up the difference --
    // confirmed live: pikopool's real balance drained from ~0.26 ICP to
    // ~0.0097 ICP over just 3 real wins, well below the 0.2501 ICP a win
    // costs, silently failing the next win attempt with IcpFeeFailed.
    // This mirrors the PIKO reward side's own existing sweep-to-biggest-
    // contributor mechanism (below), which already guarantees 100% of the
    // REWARD gets distributed -- this does the same for the FEE side.
    var feeNeeded = totalFeeE8s;
    var shareWeight = payableTotal;
    var i = 0;
    for ((p, c) in entries.vals()) {
      let isEligible = switch (List.get(eligible, i)) { case (?v) v; case null false };
      i += 1;
      let feeShare = if (not isEligible or shareWeight == 0) { 0 } else { feeNeeded * c / shareWeight };
      let collected = if (not isEligible) { false } else if (feeShare == 0) { true } else {
        let outcome = try {
          ?(
            await IcpLedger.icrc2_transfer_from({
              spender_subaccount = null;
              from = { owner = p; subaccount = null };
              to = { owner = Principal.fromActor(self); subaccount = null };
              amount = feeShare;
              fee = null;
              memo = null;
              created_at_time = null;
            })
          );
        } catch (_e) { null };
        switch (outcome) {
          case (? #Ok(_)) true;
          case _ false;
        };
      };
      // Remove this participant's weight from the remaining payable pool
      // (only meaningful for eligible entries -- shareWeight only ever
      // counted payableTotal to begin with) so whoever's processed after
      // them has their share of the STILL-needed fee recomputed against
      // what's left. On success, feeNeeded also drops by what they just
      // paid; on a same-pass failure despite passing pass 1, it's left
      // untouched, so their unpaid portion becomes everyone-after-them's
      // problem -- exactly mirroring how their own forfeited PIKO reward
      // (below) already gets swept to the round's biggest paying
      // contributor.
      if (isEligible) { shareWeight -= c };
      if (collected) {
        feeNeeded -= feeShare;
        let cut = reward * c / total;
        distributed += cut;
        let prevPending = switch (Map.get(pendingPoolRewards, Principal.compare, p)) {
          case (?v) v;
          case null 0;
        };
        Map.add(pendingPoolRewards, Principal.compare, p, prevPending + cut);
        if (c > highestCount) { highestCount := c; highestPrincipal := ?p };
      };
      // else: didn't cover their share of the fee -- forfeits this
      // round's PIKO too. Their share count for the round is simply
      // dropped below when this round's entries are removed; nothing
      // else to reverse, since nothing was credited to them.
    };
    // Integer-division dust (from whoever DID get paid) goes to the
    // round's biggest paying contributor -- same remainder convention
    // pikopoker uses for split pots.
    let remainder = Int.abs(reward - distributed);
    if (remainder > 0) {
      switch (highestPrincipal) {
        case (?p) {
          let prevPending = switch (Map.get(pendingPoolRewards, Principal.compare, p)) {
            case (?v) v;
            case null 0;
          };
          Map.add(pendingPoolRewards, Principal.compare, p, prevPending + remainder);
        };
        case null {};
      };
    };
    // Remove only this round's own snapshot -- NOT Map.clear, which would
    // also wipe any new shares (or nonces) that arrived (for the next
    // round) during this function's awaits above.
    for ((p, _) in entries.vals()) {
      Map.remove(currentRoundShares, Principal.compare, p);
    };
    for (n in usedNonceKeysThisRound.vals()) {
      Map.remove(usedNoncesThisRound, Nat.compare, n);
    };
  };

  public shared ({ caller }) func submitShare(height : Nat, nonce : Nat) : async Types.ShareResult {
    if (Principal.isAnonymous(caller)) { return #Err(#Anonymous) };

    let now = Time.now();
    switch (Map.get(lastShareAttempt, Principal.compare, caller)) {
      case (?last) {
        let remaining = MIN_SHARE_INTERVAL_NANOS - (now - last);
        if (remaining > 0) {
          return #Err(#TooSoon({ retryAfterNanos = Int.abs(remaining) }));
        };
      };
      case null {};
    };
    Map.add(lastShareAttempt, Principal.compare, caller, now);

    if (height != cachedWork.height) { return #Err(#StaleWork) };

    let candidateHash = computeHash(cachedWork.previousHash, height, nonce);
    let zeroBits = leadingZeroBits(candidateHash);
    if (zeroBits < shareDifficultyBits) { return #Err(#BelowShareTarget) };

    // Reject a nonce already credited this round, to anyone -- the hash
    // only depends on (previousHash, height, nonce), never on the caller,
    // so without this check the exact same one-time proof of work could be
    // resubmitted (by the same caller, or copied by a different one) for
    // unlimited extra share credit. See usedNoncesThisRound's own comment.
    if (Map.containsKey(usedNoncesThisRound, Nat.compare, nonce)) {
      return #Err(#DuplicateNonce);
    };
    Map.add(usedNoncesThisRound, Nat.compare, nonce, ());

    // Valid share -- credit it now, regardless of what happens below.
    let prevCount = switch (Map.get(currentRoundShares, Principal.compare, caller)) {
      case (?c) c;
      case null 0;
    };
    Map.add(currentRoundShares, Principal.compare, caller, prevCount + 1);
    totalSharesAllTime += 1;

    if (zeroBits < cachedWork.difficultyBits) {
      // Real share, but doesn't clear the actual network target -- done.
      return #Ok({ accepted = true; isBlockWinner = false; poolSubmitResult = null });
    };

    // This share also solves the real block -- claim it under this
    // canister's own principal, then split the reward across the round.
    // Captured before the call (not read back off cachedWork afterwards):
    // this is the fee mother is actually about to pull from THIS
    // canister's own account right now, which is what participants need
    // to collectively reimburse, regardless of what miningFeeE8s becomes
    // by the time cachedWork next refreshes.
    let feeE8sAtWin = cachedWork.miningFeeE8s;
    let Mother : Types.MotherActor = actor (Principal.toText(motherId));
    let result = await Mother.submitProof(nonce);
    switch (result) {
      case (#Ok(ok)) {
        // + ICP_LEDGER_FEE_E8S: mother's own pull above debited this
        // canister for feeE8sAtWin PLUS that ledger's transfer fee, not
        // just feeE8sAtWin -- see the constant's own comment.
        await distributeRoundReward(ok.reward, feeE8sAtWin + ICP_LEDGER_FEE_E8S);
        blocksWon += 1;
        totalPikoDistributed += ok.reward;
        ignore refreshCachedWork(); // don't wait for the next timer tick to see the new height
      };
      case (#Err(#IcpFeeFailed(_))) {
        // Most likely: this canister's mother-spender allowance ran out.
        // Best-effort self-heal so the NEXT winning share (whenever the
        // next block is found) has a fresh approval; this round's share
        // credit is not lost either way.
        ignore refreshMotherApproval();
      };
      case (#Err(#StaleWork)) {
        // Someone else (another pool, a solo miner) won this height
        // first. No one is penalized -- shares already credited this
        // round carry over toward the next win.
        ignore refreshCachedWork();
      };
      case (#Err(_)) {};
    };
    #Ok({ accepted = true; isBlockWinner = true; poolSubmitResult = ?result });
  };

  // Same standard ICRC-1 fee the rest of the PIKO family already documents
  // to users (e.g. PikoPoker's wallet: "Transfers use the standard ICRC-1
  // ledger fee (0.0001 PIKO)"). Must come out of what the claimant
  // receives, not out of pikopool's own balance -- otherwise the sum of
  // every pendingPoolRewards entry (which exactly equals total distributed
  // rewards, see distributeRoundReward) would exceed pikopool's real
  // balance by one fee per claim ever made, and whichever claim happens
  // to run last would fail with InsufficientFunds. Found exactly this way
  // during local testing (2026-09-18): a real, load-bearing bug, not a
  // hypothetical -- same class as the PikoLock ledger-fee-shortfall bug.
  let PIKO_LEDGER_FEE : Nat = 10_000;

  public shared ({ caller }) func claimPoolReward() : async Types.TransferResult {
    if (Principal.isAnonymous(caller)) {
      return #Err(#GenericError({ error_code = 0; message = "anonymous caller" }));
    };
    let owed = switch (Map.get(pendingPoolRewards, Principal.compare, caller)) {
      case (?v) v;
      case null 0;
    };
    if (owed <= PIKO_LEDGER_FEE) {
      return #Err(#GenericError({ error_code = 0; message = "nothing to claim, or pending reward is too small to cover the network fee" }));
    };
    // Clear before awaiting -- prevents a double-claim race, same pattern
    // as mother's claimPendingReward / pikopoker's claimPendingPayout.
    Map.add(pendingPoolRewards, Principal.compare, caller, 0);

    let payout = owed - PIKO_LEDGER_FEE : Nat;
    let PikoLedger : Types.LedgerActor = actor (Principal.toText(pikoLedgerId));
    let outcome = try {
      ?(
        await PikoLedger.icrc1_transfer({
          from_subaccount = null;
          to = { owner = caller; subaccount = null };
          amount = payout;
          fee = null;
          memo = null;
          created_at_time = null;
        })
      );
    } catch (_e) { null };

    switch (outcome) {
      case (? #Ok(idx)) { #Ok(idx) };
      case (? #Err(e)) {
        // Re-add on failure so the claim can be retried later.
        let prevPending = switch (Map.get(pendingPoolRewards, Principal.compare, caller)) {
          case (?v) v;
          case null 0;
        };
        Map.add(pendingPoolRewards, Principal.compare, caller, prevPending + owed);
        #Err(e);
      };
      case null {
        let prevPending = switch (Map.get(pendingPoolRewards, Principal.compare, caller)) {
          case (?v) v;
          case null 0;
        };
        Map.add(pendingPoolRewards, Principal.compare, caller, prevPending + owed);
        #Err(#TemporarilyUnavailable);
      };
    };
  };

  // ---- Queries ----
  public query func getPoolConfig() : async Types.PoolConfig {
    { shareDifficultyBits; networkDifficultyBits = cachedWork.difficultyBits; height = cachedWork.height };
  };

  public query func getPoolStats() : async Types.PoolStats {
    var currentRoundTotalShares = 0;
    for ((_, c) in Map.entries(currentRoundShares)) { currentRoundTotalShares += c };
    // Distinct principals credited at least one share since the last win --
    // a much steadier, more legible number for the UI than a hashrate
    // ESTIMATE derived from Poisson-distributed share timing, which stays
    // noisy no matter how it's averaged when the real share rate is low
    // (a lone or small pool). Resets with the rest of the round on a win.
    let activeMinersThisRound = Map.size(currentRoundShares);
    let now = Time.now();
    var activeMinersNow = 0;
    for ((_, seenAt) in Map.entries(lastSeenAt)) {
      if (now - seenAt < ACTIVE_WINDOW_NANOS) { activeMinersNow += 1 };
    };
    { blocksWon; totalSharesAllTime; totalPikoDistributed; currentRoundTotalShares; activeMinersThisRound; activeMinersNow };
  };

  public shared query ({ caller }) func getMyShare() : async { sharesThisRound : Nat; pendingReward : Nat } {
    {
      sharesThisRound = switch (Map.get(currentRoundShares, Principal.compare, caller)) {
        case (?c) c;
        case null 0;
      };
      pendingReward = switch (Map.get(pendingPoolRewards, Principal.compare, caller)) {
        case (?v) v;
        case null 0;
      };
    };
  };

  // ---- Timer setup (does not survive upgrades under enhanced orthogonal
  // persistence -- same reasoning/pattern as mother's own armSweepTimer:
  // the top-level call runs on first install, postupgrade re-arms it
  // afterwards) ----
  func armWorkTimer<system>() {
    switch (workTimerId) {
      case (?id) { Timer.cancelTimer(id) };
      case null {};
    };
    workTimerId := ?Timer.recurringTimer<system>(#seconds REFRESH_INTERVAL_SECONDS, refreshCachedWork);
  };

  system func postupgrade() {
    armWorkTimer<system>();
  };

  // (No initial synchronous fetch here -- top-level actor init has no send
  // capability for an async call. The timer's first fire, up to
  // REFRESH_INTERVAL_SECONDS after install, populates cachedWork for real;
  // until then every submitShare's height check safely fails as #StaleWork.)
  armWorkTimer<system>();
};
