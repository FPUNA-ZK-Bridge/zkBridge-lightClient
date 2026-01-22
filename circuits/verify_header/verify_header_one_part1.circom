pragma circom 2.0.3;

include "./header_verification_split.circom";

// Part 1: HashToField + Aggregation + Checks + MapToG2 + bitSum + Poseidon
// ONE validator version - minimal for testing with limited RAM
// Estimated: ~6M constraints, ~15GB RAM
component main { public [ signing_root ] } = VerifyHeaderPart1(1, 55, 7);
