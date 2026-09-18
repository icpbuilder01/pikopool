module {
  // Same minimal ICRC-1/ICRC-2 interface the rest of this family of
  // projects declares locally per canister (piko-icp's own convention,
  // see mother/pikopoker's types.mo) rather than importing cross-canister.
  public type Account = { owner : Principal; subaccount : ?Blob };

  public type TransferArg = {
    from_subaccount : ?Blob;
    to : Account;
    amount : Nat;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };

  public type TransferError = {
    #BadFee : { expected_fee : Nat };
    #BadBurn : { min_burn_amount : Nat };
    #InsufficientFunds : { balance : Nat };
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #TemporarilyUnavailable;
    #Duplicate : { duplicate_of : Nat };
    #GenericError : { error_code : Nat; message : Text };
  };

  public type TransferResult = { #Ok : Nat; #Err : TransferError };

  public type ApproveArgs = {
    from_subaccount : ?Blob;
    spender : Account;
    amount : Nat;
    expected_allowance : ?Nat;
    expires_at : ?Nat64;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };

  public type ApproveError = {
    #BadFee : { expected_fee : Nat };
    #InsufficientFunds : { balance : Nat };
    #AllowanceChanged : { current_allowance : Nat };
    #Expired : { ledger_time : Nat64 };
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #Duplicate : { duplicate_of : Nat };
    #TemporarilyUnavailable;
    #GenericError : { error_code : Nat; message : Text };
  };

  public type ApproveResult = { #Ok : Nat; #Err : ApproveError };

  public type TransferFromArgs = {
    spender_subaccount : ?Blob;
    from : Account;
    to : Account;
    amount : Nat;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };

  public type TransferFromError = {
    #BadFee : { expected_fee : Nat };
    #BadBurn : { min_burn_amount : Nat };
    #InsufficientFunds : { balance : Nat };
    #InsufficientAllowance : { allowance : Nat };
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #Duplicate : { duplicate_of : Nat };
    #TemporarilyUnavailable;
    #GenericError : { error_code : Nat; message : Text };
  };

  public type TransferFromResult = { #Ok : Nat; #Err : TransferFromError };

  public type LedgerActor = actor {
    icrc1_transfer : (TransferArg) -> async TransferResult;
    icrc1_balance_of : (Account) -> async Nat;
    icrc2_approve : (ApproveArgs) -> async ApproveResult;
    icrc2_transfer_from : (TransferFromArgs) -> async TransferFromResult;
  };

  // Mirrors mother/src/types.mo's Work/SubmitOk/SubmitError/SubmitResult
  // exactly -- must stay byte-for-byte in sync with the real mother's
  // candid interface for the inter-canister call in main.mo to decode
  // correctly. See test-mother/src/types.mo for the identical test-only copy.
  public type Work = {
    height : Nat;
    previousHash : Blob;
    difficultyBits : Nat;
    reward : Nat;
    miningFeeE8s : Nat;
  };

  public type SubmitOk = { height : Nat; reward : Nat; hash : Blob };

  public type SubmitError = {
    #Anonymous;
    #InvalidProof;
    #TooSoon : { retryAfterNanos : Nat };
    #NothingToClaim;
    #IcpFeeFailed : TransferFromError;
    #StaleWork;
  };

  public type SubmitResult = { #Ok : SubmitOk; #Err : SubmitError };

  public type MotherActor = actor {
    getWork : () -> async Work;
    submitProof : (Nat) -> async SubmitResult;
  };

  // Pool-specific result types.

  public type ShareOutcome = {
    accepted : Bool;
    isBlockWinner : Bool;
    poolSubmitResult : ?SubmitResult; // set only when isBlockWinner
  };

  public type ShareError = {
    #Anonymous;
    #TooSoon : { retryAfterNanos : Nat };
    #StaleWork; // height doesn't match the pool's current cached job
    #BelowShareTarget; // hash didn't even clear the (easier) share difficulty
  };

  public type ShareResult = { #Ok : ShareOutcome; #Err : ShareError };

  public type PoolConfig = {
    shareDifficultyBits : Nat;
    networkDifficultyBits : Nat;
    height : Nat;
  };

  public type PoolStats = {
    blocksWon : Nat;
    totalSharesAllTime : Nat;
    totalPikoDistributed : Nat;
    currentRoundTotalShares : Nat;
  };
}
