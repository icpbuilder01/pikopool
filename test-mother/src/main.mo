import Principal "mo:core/Principal";
import Int "mo:core/Int";
import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Array "mo:core/Array";
import Time "mo:core/Time";
import Cycles "mo:core/Cycles";
import Map "mo:core/Map";
import Sha256 "mo:sha2/Sha256";
import Types "types";

// TEST DOUBLE ONLY -- never deployed to mainnet. Exists purely so
// pikopool's own local tests exercise the exact same candid shapes and
// core submitProof mechanics (rate limit, hash check before fee pull, fee
// pull from caller, stale-work re-check, immediate reward mint) that the
// real ~/piko-icp/mother/src/main.mo implements, without pikopool's repo
// having to vendor/duplicate mother's real, evolving business logic
// (halving, retargeting, leaderboard, admin timelocks -- none of that is
// relevant to testing pikopool's own code and is deliberately left out).
// If mother's real submitProof contract ever changes, this file needs a
// matching update for local tests to stay meaningful.
actor self {
  var pikoLedgerId : Principal = Principal.fromText("aaaaa-aa"); // set via testSetLedgers before use
  var icpLedgerId : Principal = Principal.fromText("aaaaa-aa");

  var height : Nat = 0;
  var previousHash : Blob = Blob.fromArray([]);
  var difficultyBits : Nat = 8; // deliberately low default, easy to satisfy in tests
  var reward : Nat = 100_000_000_000; // 1,000 test-PIKO per block
  var miningFeeE8s : Nat = 0; // tests can turn the fee on via testSetWork

  let MIN_SUBMIT_INTERVAL_NANOS : Int = 300_000_000; // 0.3s, mirrors real mother
  transient let lastAttempt = Map.empty<Principal, Int>();

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

  func computeHash(prev : Blob, atHeight : Nat, nonce : Nat) : Blob {
    Sha256.fromArray(#sha256, Array.concat(Array.concat(Blob.toArray(prev), natToBytes8(atHeight)), natToBytes8(nonce)));
  };

  // --- Test-only controls, no auth (never deployed to mainnet) ---

  public shared func testSetLedgers(piko : Principal, icp : Principal) : async () {
    pikoLedgerId := piko;
    icpLedgerId := icp;
  };

  public shared func testSetWork(newDifficultyBits : Nat, newReward : Nat, newMiningFeeE8s : Nat) : async () {
    difficultyBits := newDifficultyBits;
    reward := newReward;
    miningFeeE8s := newMiningFeeE8s;
  };

  // --- Real interface, mirrors mother/src/main.mo ---

  public query func getWork() : async Types.Work {
    { height; previousHash; difficultyBits; reward; miningFeeE8s };
  };

  public shared ({ caller }) func submitProof<system>(nonce : Nat) : async Types.SubmitResult {
    if (Principal.isAnonymous(caller)) { return #Err(#Anonymous) };

    let now = Time.now();
    switch (Map.get(lastAttempt, Principal.compare, caller)) {
      case (?last) {
        let remaining = MIN_SUBMIT_INTERVAL_NANOS - (now - last);
        if (remaining > 0) { return #Err(#TooSoon({ retryAfterNanos = Int.toNat(remaining) })) };
      };
      case null {};
    };
    Map.add(lastAttempt, Principal.compare, caller, now);
    ignore Cycles.accept<system>(Cycles.available());

    let submittedHeight = height;
    let candidateHash = computeHash(previousHash, submittedHeight, nonce);
    if (leadingZeroBits(candidateHash) < difficultyBits) { return #Err(#InvalidProof) };

    if (miningFeeE8s > 0) {
      let IcpLedger : Types.IcpLedgerActor = actor (Principal.toText(icpLedgerId));
      let feeOutcome = try {
        ?(
          await IcpLedger.icrc2_transfer_from({
            spender_subaccount = null;
            from = { owner = caller; subaccount = null };
            to = { owner = Principal.fromActor(self); subaccount = null };
            amount = miningFeeE8s;
            fee = null;
            memo = null;
            created_at_time = null;
          })
        );
      } catch (_e) { null };
      switch (feeOutcome) {
        case (? #Ok(_)) {};
        case (? #Err(e)) { return #Err(#IcpFeeFailed(e)) };
        case null { return #Err(#IcpFeeFailed(#TemporarilyUnavailable)) };
      };
    };

    if (height != submittedHeight) { return #Err(#StaleWork) };

    height += 1;
    previousHash := candidateHash;

    if (reward > 0) {
      let PikoLedger : Types.PikoLedgerActor = actor (Principal.toText(pikoLedgerId));
      ignore (try {
        ?(
          await PikoLedger.icrc1_transfer({
            from_subaccount = null;
            to = { owner = caller; subaccount = null };
            amount = reward;
            fee = null;
            memo = null;
            created_at_time = null;
          })
        );
      } catch (_e) { null });
    };

    #Ok({ height = submittedHeight; reward; hash = candidateHash });
  };
};
