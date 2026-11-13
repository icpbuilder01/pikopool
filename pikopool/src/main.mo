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
import VarArray "mo:core/VarArray";
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

  // Mother's difficulty can now fall on its own while no block is found. Shares
  // must stay easier than the real target, or they stop splitting the work
  // and valid winning hashes get rejected as below the share target.
  transient let MIN_SHARE_BITS_BELOW_NETWORK : Nat = 6;
  // Every share is an update call this canister pays for, and a block takes
  // 2^(network - share) shares on average. With the share target fixed, that
  // count doubles with every bit the network climbs (about a million shares a
  // block at 36 bits), which would drain the pool. So the share target also
  // follows the network from below: at most 2^10 (~1k) shares a block, about
  // 10B cycles, well under what one block earns the family in cycles.
  transient let MAX_SHARE_BITS_BELOW_NETWORK : Nat = 10;
  func effectiveShareBits() : Nat {
    let network = cachedWork.difficultyBits;
    let ceiling = if (network > MIN_SHARE_BITS_BELOW_NETWORK) { network - MIN_SHARE_BITS_BELOW_NETWORK } else { 1 };
    let floor = if (network > MAX_SHARE_BITS_BELOW_NETWORK) { network - MAX_SHARE_BITS_BELOW_NETWORK } else { 1 };
    Nat.max(Nat.min(shareDifficultyBits, ceiling), floor);
  };

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

  // Public so anyone can unstick the pool, but each icrc2_approve costs the
  // pool a ledger fee: it used to approve on every call, so anyone could drain
  // the pool's ICP for free, one fee per call (found in the 2026-11-08 audit).
  // Now it first reads the remaining allowance (no ICP spent) and only
  // approves when that is running low, at most once per minute.
  transient let APPROVAL_MIN_INTERVAL_NANOS : Int = 60_000_000_000;
  transient let MAX_ROUND_PARTICIPANTS : Nat = 25;
  transient let ROUND_FULL_RETRY_NANOS : Nat = 60_000_000_000;
  transient var lastMotherApprovalAt : Int = 0;

  public shared func refreshMotherApproval() : async Types.ApproveResult {
    let IcpLedger : Types.LedgerActor = actor (Principal.toText(icpLedgerId));
    let remaining = try {
      (
        await IcpLedger.icrc2_allowance({
          account = { owner = Principal.fromActor(self); subaccount = null };
          spender = { owner = motherId; subaccount = null };
        })
      ).allowance;
    } catch (_e) {
      return #Err(#TemporarilyUnavailable);
    };
    let nextBlockNeeds = cachedWork.miningFeeE8s + ICP_LEDGER_FEE_E8S;
    if (remaining >= approvalCapE8s / 2 and remaining >= nextBlockNeeds) {
      return #Err(#GenericError({ error_code = 0; message = "allowance still sufficient" }));
    };
    let now = Time.now();
    if (now - lastMotherApprovalAt < APPROVAL_MIN_INTERVAL_NANOS) {
      return #Err(#TemporarilyUnavailable);
    };
    lastMotherApprovalAt := now;
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

  // A heartbeat is free to send, so on its own it must not keep the work timer
  // awake (one ping a minute cost ~360B cycles/day). It only shows the miner as
  // present and, at most every few minutes, refreshes a job gone stale while
  // the pool slept. Valid shares are what start the timer.
  transient let IDLE_REFRESH_INTERVAL_NANOS : Int = 300_000_000_000;
  transient var lastIdleRefreshAt : Int = 0;
  transient var lastValidShareAt : Int = 0;

  public shared ({ caller }) func heartbeat() : async () {
    if (Principal.isAnonymous(caller)) { return };
    let now = Time.now();
    Map.add(lastSeenAt, Principal.compare, caller, now);
    if (workTimerId == null and now - lastIdleRefreshAt >= IDLE_REFRESH_INTERVAL_NANOS) {
      lastIdleRefreshAt := now;
      try { ignore refreshCachedWork() } catch (_e) {};
    };
  };

  // Polling mother costs about 42M cycles per call, which every 10s came to
  // ~360B cycles/day whether or not anyone was mining. So the work timer only
  // runs while a valid share has arrived within ACTIVE_WINDOW_NANOS: it starts
  // on the first one and stops itself once they stop coming.
  // Returns true when this woke the timer up: cachedWork may then be hours
  // old, so the caller should refresh it right away.
  func noteValidShare<system>(miner : Principal) : Bool {
    let now = Time.now();
    Map.add(lastSeenAt, Principal.compare, miner, now);
    lastValidShareAt := now;
    if (workTimerId != null) { return false };
    armWorkTimer<system>();
    true;
  };

  func anyMinerActive() : Bool { Time.now() - lastValidShareAt < ACTIVE_WINDOW_NANOS };

  // Both maps get one entry per principal that ever calls, and principals are
  // free to make, so stale entries are dropped on every work tick. An entry
  // older than these windows no longer changes any answer.
  func pruneStaleMinerEntries() {
    let now = Time.now();
    let staleSeen = List.empty<Principal>();
    for ((p, seenAt) in Map.entries(lastSeenAt)) {
      if (now - seenAt >= ACTIVE_WINDOW_NANOS) { List.add(staleSeen, p) };
    };
    for (p in List.values(staleSeen)) { Map.remove(lastSeenAt, Principal.compare, p) };
    let staleAttempts = List.empty<Principal>();
    for ((p, at) in Map.entries(lastShareAttempt)) {
      if (now - at >= MIN_SHARE_INTERVAL_NANOS) { List.add(staleAttempts, p) };
    };
    for (p in List.values(staleAttempts)) { Map.remove(lastShareAttempt, Principal.compare, p) };
  };

  func onWorkTimer() : async () {
    pruneStaleMinerEntries();
    if (anyMinerActive()) {
      await refreshCachedWork();
    } else {
      switch (workTimerId) {
        case (?id) { Timer.cancelTimer(id) };
        case null {};
      };
      workTimerId := null;
    };
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

  // What a participant can really pay right now: transfer_from debits both their
  // balance and their allowance for the amount plus the ledger fee.
  // async* (not async) on the helpers below that move funds: they run inside
  // the caller's message instead of as self-calls. A self-call can fail to even
  // be sent when the canister is short of cycles, and that failure would skip
  // the rest of the caller (a payout or refund lost). Found by a load test on
  // PikoBlackjack, 2026-11-07.
  func payingCapacity(p : Principal) : async* Nat {
    let IcpLedger : Types.LedgerActor = actor (Principal.toText(icpLedgerId));
    let account = { owner = p; subaccount = null };
    let allowance = try {
      (await IcpLedger.icrc2_allowance({ account; spender = { owner = Principal.fromActor(self); subaccount = null } })).allowance;
    } catch (_e) { 0 };
    let balance = try { await IcpLedger.icrc1_balance_of(account) } catch (_e) { 0 };
    let spendable = Nat.min(allowance, balance);
    if (spendable > ICP_LEDGER_FEE_E8S) { spendable - ICP_LEDGER_FEE_E8S } else { 0 };
  };

  // Reads every participant at once rather than one after the other: each ICP
  // ledger call is a cross-subnet round trip of a few seconds, and until the
  // proof reaches mother another miner can take the block.
  func readCapacities(entries : [(Principal, Nat)], capacities : [var Nat]) : async* () {
    let IcpLedger : Types.LedgerActor = actor (Principal.toText(icpLedgerId));
    let spender = { owner = Principal.fromActor(self); subaccount = null };
    let allowanceCalls = List.empty<(Nat, async Types.Allowance)>();
    let balanceCalls = List.empty<(Nat, async Nat)>();
    for (i in Nat.range(0, entries.size())) {
      let account = { owner = entries[i].0; subaccount = null };
      try { List.add(allowanceCalls, (i, IcpLedger.icrc2_allowance({ account; spender }))) } catch (_e) {};
      try { List.add(balanceCalls, (i, IcpLedger.icrc1_balance_of(account))) } catch (_e) {};
    };
    let allowances = VarArray.repeat<Nat>(0, entries.size());
    let balances = VarArray.repeat<Nat>(0, entries.size());
    for ((i, call) in List.values(allowanceCalls)) {
      allowances[i] := try { (await call).allowance } catch (_e) { 0 };
    };
    for ((i, call) in List.values(balanceCalls)) {
      balances[i] := try { await call } catch (_e) { 0 };
    };
    for (i in Nat.range(0, entries.size())) {
      let spendable = Nat.min(allowances[i], balances[i]);
      capacities[i] := if (spendable > ICP_LEDGER_FEE_E8S) { spendable - ICP_LEDGER_FEE_E8S } else { 0 };
    };
  };

  // Who can cover their share of the fee. Dropping a participant raises what
  // the others owe, so this repeats until everyone left can afford their share.
  func payingCohort(entries : [(Principal, Nat)], totalFeeE8s : Nat) : async* { eligible : [Bool]; weight : Nat } {
    let capacities = VarArray.repeat<Nat>(0, entries.size());
    await* readCapacities(entries, capacities);
    let eligible = VarArray.repeat<Bool>(true, entries.size());
    var weight = 0;
    for ((_, c) in entries.vals()) { weight += c };
    var changed = true;
    while (changed and weight > 0) {
      changed := false;
      let weightThisPass = weight;
      for (i in Nat.range(0, entries.size())) {
        // + 1: the waterfall in distributeRoundReward can round a share up by one.
        if (eligible[i] and totalFeeE8s * entries[i].1 / weightThisPass + 1 > capacities[i]) {
          eligible[i] := false;
          weight -= entries[i].1;
          changed := true;
        };
      };
    };
    { eligible = Array.fromVarArray(eligible); weight };
  };

  // Pay first: the round's fee is collected from participants BEFORE the proof
  // goes to mother, so the pool never spends ICP it has not already received.
  // Advancing the fee and collecting afterwards let one participant who could not
  // pay drain the pool's ICP (drained below the fee in 2026-10, and every win then
  // failed for five weeks). A failed proof refunds everyone instead.
  type RoundPayment = { participant : Principal; shares : Nat; paid : Nat };
  type RoundFee = { payments : [RoundPayment]; fullyFunded : Bool };

  // Waterfall among those who can pay: each share is recomputed against what is
  // still needed, so a transfer that fails anyway falls on whoever comes next.
  func collectRoundFee(entries : [(Principal, Nat)], totalFeeE8s : Nat) : async* RoundFee {
    let cohort = await* payingCohort(entries, totalFeeE8s);
    let IcpLedger : Types.LedgerActor = actor (Principal.toText(icpLedgerId));
    let payments = List.empty<RoundPayment>();
    var feeNeeded = totalFeeE8s;
    var shareWeight = cohort.weight;
    for (i in Nat.range(0, entries.size())) {
      if (cohort.eligible[i] and shareWeight > 0) {
        let (participant, shares) = entries[i];
        let feeShare = feeNeeded * shares / shareWeight;
        shareWeight -= shares;
        let collected = if (feeShare == 0) { true } else {
          let outcome = try {
            ?(
              await IcpLedger.icrc2_transfer_from({
                spender_subaccount = null;
                from = { owner = participant; subaccount = null };
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
        if (collected) {
          feeNeeded -= feeShare;
          List.add(payments, { participant; shares; paid = feeShare });
        };
      };
    };
    { payments = List.toArray(payments); fullyFunded = feeNeeded == 0 };
  };

  // Each refund costs the pool one ledger fee, so it comes out of the refund.
  // Anything that fails stays claimable through claimFeeRefund.
  let pendingFeeRefunds : Map.Map<Principal, Nat> = Map.empty<Principal, Nat>();

  func addFeeRefund(p : Principal, amount : Nat) {
    let prev = switch (Map.get(pendingFeeRefunds, Principal.compare, p)) {
      case (?v) v;
      case null 0;
    };
    Map.add(pendingFeeRefunds, Principal.compare, p, prev + amount);
  };

  func sendFeeRefund(p : Principal, owed : Nat) : async* Types.TransferResult {
    if (owed <= ICP_LEDGER_FEE_E8S) { return #Err(#GenericError({ error_code = 0; message = "nothing to refund, or too small to cover the network fee" })) };
    let IcpLedger : Types.LedgerActor = actor (Principal.toText(icpLedgerId));
    let outcome = try {
      ?(
        await IcpLedger.icrc1_transfer({
          from_subaccount = null;
          to = { owner = p; subaccount = null };
          amount = owed - ICP_LEDGER_FEE_E8S : Nat;
          fee = null;
          memo = null;
          created_at_time = null;
        })
      );
    } catch (_e) { null };
    switch (outcome) {
      case (? #Ok(idx)) { #Ok(idx) };
      case (? #Err(e)) { addFeeRefund(p, owed); #Err(e) };
      case null { addFeeRefund(p, owed); #Err(#TemporarilyUnavailable) };
    };
  };

  func refundRoundFee(payments : [RoundPayment]) : async* () {
    for (payment in payments.vals()) {
      if (payment.paid > ICP_LEDGER_FEE_E8S) { ignore (await* sendFeeRefund(payment.participant, payment.paid)) };
    };
  };

  public shared ({ caller }) func claimFeeRefund() : async Types.TransferResult {
    if (Principal.isAnonymous(caller)) {
      return #Err(#GenericError({ error_code = 0; message = "anonymous caller" }));
    };
    let owed = switch (Map.get(pendingFeeRefunds, Principal.compare, caller)) {
      case (?v) v;
      case null 0;
    };
    Map.remove(pendingFeeRefunds, Principal.compare, caller); // clear before awaiting -- no double-claim
    await* sendFeeRefund(caller, owed);
  };

  public shared query ({ caller }) func getMyFeeRefund() : async Nat {
    switch (Map.get(pendingFeeRefunds, Principal.compare, caller)) {
      case (?v) v;
      case null 0;
    };
  };

  // Credits the won block to those who paid, then closes the round. Whoever did
  // not pay forfeits: their PIKO ends up with the biggest paying contributor,
  // along with the integer-division dust.
  func creditRound(reward : Nat, entries : [(Principal, Nat)], nonces : [Nat], payments : [RoundPayment]) {
    var total = 0;
    for ((_, c) in entries.vals()) { total += c };
    var distributed = 0;
    var highestPrincipal : ?Principal = null;
    var highestCount = 0;
    for (payment in payments.vals()) {
      let cut = reward * payment.shares / total;
      distributed += cut;
      let prevPending = switch (Map.get(pendingPoolRewards, Principal.compare, payment.participant)) {
        case (?v) v;
        case null 0;
      };
      Map.add(pendingPoolRewards, Principal.compare, payment.participant, prevPending + cut);
      if (payment.shares > highestCount) { highestCount := payment.shares; highestPrincipal := ?payment.participant };
    };
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
    // Only this round's snapshot: shares and nonces that arrived during the
    // awaits belong to the next round, including those of its participants.
    for ((p, counted) in entries.vals()) {
      let now = switch (Map.get(currentRoundShares, Principal.compare, p)) { case (?c) c; case null 0 };
      if (now > counted) { Map.add(currentRoundShares, Principal.compare, p, now - counted : Nat) } else {
        Map.remove(currentRoundShares, Principal.compare, p);
      };
    };
    for (n in nonces.vals()) { Map.remove(usedNoncesThisRound, Nat.compare, n) };
  };

  // Only one win at a time, or two winning shares would each collect the fee. A
  // timestamp rather than a flag, so a trap mid-win cannot block wins forever.
  transient var winStartedAt : Int = 0;
  transient let WIN_GUARD_NANOS : Int = 300_000_000_000;

  public shared ({ caller }) func submitShare<system>(height : Nat, nonce : Nat) : async Types.ShareResult {
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
    if (zeroBits < effectiveShareBits()) { return #Err(#BelowShareTarget) };
    if (noteValidShare<system>(caller)) { try { ignore refreshCachedWork() } catch (_e) {} };

    // At most MAX_ROUND_PARTICIPANTS distinct participants per round: a win
    // makes ~3 sequential ICP ledger calls per participant, so an unbounded
    // round (cheap shares from many fresh principals) could take longer than
    // WIN_GUARD_NANOS on mainnet. A newcomer to a full round is told to retry
    // later (TooSoon, which existing miners already handle), unless the share
    // wins the block outright: the pool never turns down a block.
    if (
      not Map.containsKey(currentRoundShares, Principal.compare, caller) and
      Map.size(currentRoundShares) >= MAX_ROUND_PARTICIPANTS and
      zeroBits < cachedWork.difficultyBits
    ) {
      return #Err(#TooSoon({ retryAfterNanos = ROUND_FULL_RETRY_NANOS }));
    };

    // Reject a nonce already credited this round, to anyone -- the hash
    // only depends on (previousHash, height, nonce), never on the caller,
    // so without this check the exact same one-time proof of work could be
    // resubmitted (by the same caller, or copied by a different one) for
    // unlimited extra share credit. See usedNoncesThisRound's own comment.
    if (Map.containsKey(usedNoncesThisRound, Nat.compare, nonce)) {
      return #Err(#DuplicateNonce);
    };
    Map.add(usedNoncesThisRound, Nat.compare, nonce, ());

    // A newcomer must be able to pay a share of a block's fee. Otherwise a few
    // free throwaway identities could take every seat of the round and lock
    // real miners out. A share that wins the block outright is never refused.
    if (not Map.containsKey(currentRoundShares, Principal.compare, caller) and zeroBits < cachedWork.difficultyBits) {
      let capacity = await* payingCapacity(caller);
      let stillRoom = Map.containsKey(currentRoundShares, Principal.compare, caller) or Map.size(currentRoundShares) < MAX_ROUND_PARTICIPANTS;
      if (capacity < cachedWork.miningFeeE8s / MAX_ROUND_PARTICIPANTS or not stillRoom) {
        Map.remove(usedNoncesThisRound, Nat.compare, nonce);
        return #Err(#TooSoon({ retryAfterNanos = ROUND_FULL_RETRY_NANOS }));
      };
      if (height != cachedWork.height) {
        Map.remove(usedNoncesThisRound, Nat.compare, nonce);
        return #Err(#StaleWork);
      };
    };

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

    // This share also solves the real block.
    if (now - winStartedAt < WIN_GUARD_NANOS) {
      return #Ok({ accepted = true; isBlockWinner = false; poolSubmitResult = null });
    };
    winStartedAt := now;

    let entries = Iter.toArray(Map.entries(currentRoundShares));
    let nonces = Iter.toArray(Map.keys(usedNoncesThisRound));
    // What this win costs the pool: mother's pull debits the fee plus one ledger
    // fee, and refreshing the allowance afterwards costs one more.
    let roundFee = await* collectRoundFee(entries, cachedWork.miningFeeE8s + 2 * ICP_LEDGER_FEE_E8S);
    if (not roundFee.fullyFunded) {
      await* refundRoundFee(roundFee.payments);
      winStartedAt := 0;
      return #Ok({ accepted = true; isBlockWinner = true; poolSubmitResult = ?#Err(#IcpFeeFailed(#InsufficientAllowance({ allowance = 0 }))) });
    };

    let Mother : Types.MotherActor = actor (Principal.toText(motherId));
    let result : Types.SubmitResult = try {
      await Mother.submitProof(nonce);
    } catch (_e) { #Err(#IcpFeeFailed(#TemporarilyUnavailable)) };
    switch (result) {
      case (#Ok(ok)) {
        creditRound(ok.reward, entries, nonces, roundFee.payments);
        blocksWon += 1;
        totalPikoDistributed += ok.reward;
        // Each win consumes the allowance, so renew it now rather than lose a
        // later win to it (seen 2026-09-20).
        try { ignore refreshMotherApproval() } catch (_e) {};
        try { ignore refreshCachedWork() } catch (_e) {}; // don't wait for the next timer tick to see the new height
        // Participants are credited above; if mother's mint to this canister
        // failed, the reward waits in mother under this canister's name.
        try { ignore claimRewardFromMother() } catch (_e) {};
      };
      case (#Err(e)) {
        // Shares stay credited and carry over to the next win.
        switch (e) {
          case (#IcpFeeFailed(#InsufficientAllowance(_))) { try { ignore refreshMotherApproval() } catch (_e) {} };
          case (#StaleWork) { try { ignore refreshCachedWork() } catch (_e) {} };
          case _ {};
        };
        // StaleWork: mother already kept the fee (another proof won the race
        // while it was being pulled), so it is gone, as it would be for a solo
        // miner. Refunding it would come out of the pool's own reserve.
        if (e != #StaleWork) { await* refundRoundFee(roundFee.payments) };
      };
    };
    winStartedAt := 0;
    #Ok({ accepted = true; isBlockWinner = true; poolSubmitResult = ?result });
  };

  // Anyone may trigger it: it can only move PIKO from mother to this canister,
  // to back rewards already credited to participants.
  transient let MOTHER_CLAIM_MIN_INTERVAL_NANOS : Int = 60_000_000_000;
  transient var lastMotherClaimAt : Int = 0;

  public shared func claimRewardFromMother() : async Types.SubmitResult {
    let now = Time.now();
    if (now - lastMotherClaimAt < MOTHER_CLAIM_MIN_INTERVAL_NANOS) {
      return #Err(#TooSoon({ retryAfterNanos = Int.abs(MOTHER_CLAIM_MIN_INTERVAL_NANOS - (now - lastMotherClaimAt)) }));
    };
    lastMotherClaimAt := now;
    let Mother : Types.MotherActor = actor (Principal.toText(motherId));
    await Mother.claimPendingReward();
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
    { shareDifficultyBits = effectiveShareBits(); networkDifficultyBits = cachedWork.difficultyBits; height = cachedWork.height };
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

  // ---- Timer setup ----
  func armWorkTimer<system>() {
    switch (workTimerId) {
      case (?id) { Timer.cancelTimer(id) };
      case null {};
    };
    workTimerId := ?Timer.recurringTimer<system>(#seconds REFRESH_INTERVAL_SECONDS, onWorkTimer);
  };

  // Timers do not survive upgrades, and workTimerId resets with them, so the
  // next heartbeat or share simply starts the timer again.

  // ---- Ingress filter (anti-spam) ----
  //
  // Runs before a user's call is accepted; a call refused here costs this
  // canister no cycles. It is only an early "no": it runs on one node and
  // canister callers skip it, so every method still does all of its own
  // checks. Public methods are listed explicitly; anything else (admin
  // methods, queries sent as paid update calls, timer-only maintenance) is
  // left to controllers. Timers call their methods as self-calls, which never
  // come through here.
  transient let HEARTBEAT_MIN_INTERVAL_NANOS : Int = 15_000_000_000; // the miner sends one every 20 s

  system func inspect({
    caller : Principal;
    arg : Blob;
    msg : {
      #setMotherId : Any;
      #lockMotherId : Any;
      #setPikoLedgerId : Any;
      #lockPikoLedgerId : Any;
      #setIcpLedgerId : Any;
      #lockIcpLedgerId : Any;
      #setShareDifficultyBits : Any;
      #setApprovalCapE8s : Any;
      #refreshMotherApproval : Any;
      #heartbeat : Any;
      #claimFeeRefund : Any;
      #getMyFeeRefund : Any;
      #submitShare : () -> (Nat, Nat);
      #claimRewardFromMother : Any;
      #claimPoolReward : Any;
      #getPoolConfig : Any;
      #getPoolStats : Any;
      #getMyShare : Any;
    };
  }) : Bool {
    if (arg.size() > 1024) { return false };
    let now = Time.now();
    switch msg {
      case (#submitShare f) {
        let (workHeight, nonce) = f();
        not Principal.isAnonymous(caller) and workHeight == cachedWork.height
        and not Map.containsKey(usedNoncesThisRound, Nat.compare, nonce)
        and leadingZeroBits(computeHash(cachedWork.previousHash, workHeight, nonce)) >= effectiveShareBits();
      };
      // A miner's first heartbeats can be refused until its first share: the
      // client ignores the answer and the share itself marks it as seen.
      case (#heartbeat _) {
        not Principal.isAnonymous(caller) and (
          switch (Map.get(lastSeenAt, Principal.compare, caller)) {
            case (?seen) { now - seen >= HEARTBEAT_MIN_INTERVAL_NANOS };
            case null { workTimerId == null and now - lastIdleRefreshAt >= IDLE_REFRESH_INTERVAL_NANOS };
          }
        );
      };
      case (#claimFeeRefund _) { Map.containsKey(pendingFeeRefunds, Principal.compare, caller) };
      case (#claimPoolReward _) {
        switch (Map.get(pendingPoolRewards, Principal.compare, caller)) {
          case (?owed) { owed > PIKO_LEDGER_FEE };
          case null { false };
        };
      };
      case (#claimRewardFromMother _) { now - lastMotherClaimAt >= MOTHER_CLAIM_MIN_INTERVAL_NANOS };
      case _ { Principal.isController(caller) };
    };
  };
};
