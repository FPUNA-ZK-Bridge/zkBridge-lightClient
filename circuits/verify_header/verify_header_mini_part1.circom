pragma circom 2.0.3;

include "./header_verification_split.circom";

// Part 1: HashToField + Aggregation + Checks + MapToG2 + bitSum + Poseidon
// MINI version with only 8 validators for testing on low-RAM machines
// Estimated: ~7M constraints, ~15-20GB RAM
component main { public [ signing_root ] } = VerifyHeaderPart1(8, 55, 7);
