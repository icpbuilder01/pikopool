import Principal "mo:core/Principal";
import Int "mo:core/Int";
import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Array "mo:core/Array";
import Time "mo:core/Time";
import Runtime "mo:core/Runtime";
import Timer "mo:core/Timer";
import Map "mo:core/Map";
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
  transient let currentRoundShares = Map.empty<Principal, Nat>();
  transient let pendingPoolRewards = Map.empty<Principal, Nat>();
  transient let lastShareAttempt = Map.empty<Principal, Int>();
  let MIN_SHARE_INTERVAL_NANOS : Int = 300_000_000; // 0.3s, same anti-spam reasoning as mother's own MIN_SUBMIT_INTERVAL_NANOS

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

  func distributeRoundReward(reward : Nat) {
    var total = 0;
    for ((_, c) in Map.entries(currentRoundShares)) { total += c };
    if (total == 0) { return }; // shouldn't happen -- this only runs right after crediting a share this round

    var distributed = 0;
    var highestPrincipal : ?Principal = null;
    var highestCount = 0;
    for ((p, c) in Map.entries(currentRoundShares)) {
      let cut = reward * c / total;
      distributed += cut;
      let prevPending = switch (Map.get(pendingPoolRewards, Principal.compare, p)) {
        case (?v) v;
        case null 0;
      };
      Map.add(pendingPoolRewards, Principal.compare, p, prevPending + cut);
      if (c > highestCount) { highestCount := c; highestPrincipal := ?p };
    };
    // Integer-division dust goes to the round's biggest contributor -- same
    // remainder convention pikopoker uses for split pots.
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
    Map.clear(currentRoundShares);
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
    let Mother : Types.MotherActor = actor (Principal.toText(motherId));
    let result = await Mother.submitProof(nonce);
    switch (result) {
      case (#Ok(ok)) {
        distributeRoundReward(ok.reward);
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

  public shared ({ caller }) func claimPoolReward() : async Types.TransferResult {
    if (Principal.isAnonymous(caller)) {
      return #Err(#GenericError({ error_code = 0; message = "anonymous caller" }));
    };
    let owed = switch (Map.get(pendingPoolRewards, Principal.compare, caller)) {
      case (?v) v;
      case null 0;
    };
    if (owed == 0) {
      return #Err(#GenericError({ error_code = 0; message = "nothing to claim" }));
    };
    // Clear before awaiting -- prevents a double-claim race, same pattern
    // as mother's claimPendingReward / pikopoker's claimPendingPayout.
    Map.add(pendingPoolRewards, Principal.compare, caller, 0);

    let PikoLedger : Types.LedgerActor = actor (Principal.toText(pikoLedgerId));
    let outcome = try {
      ?(
        await PikoLedger.icrc1_transfer({
          from_subaccount = null;
          to = { owner = caller; subaccount = null };
          amount = owed;
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
    { blocksWon; totalSharesAllTime; totalPikoDistributed; currentRoundTotalShares };
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
