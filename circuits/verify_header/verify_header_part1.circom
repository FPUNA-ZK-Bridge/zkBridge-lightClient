pragma circom 2.0.3;

include "./header_verification_split.circom";

// Part 1: HashToField + Aggregation + Checks + MapToG2 + bitSum + Poseidon
// Production version with 512 validators
// Outputs: Hm_G2, aggregated_pubkey, bitSum, syncCommitteePoseidon
component main { public [ signing_root ] } = VerifyHeaderPart1(512, 55, 7);
