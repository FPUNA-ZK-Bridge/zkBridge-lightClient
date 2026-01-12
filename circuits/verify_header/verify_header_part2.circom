pragma circom 2.0.3;

include "./header_verification_split.circom";

// Part 2: MillerLoop
// Production version
// Inputs: aggregated_pubkey, signature, Hm_G2 (from Part1)
// Outputs: miller_out
component main { public [ aggregated_pubkey, signature, Hm_G2 ] } = VerifyHeaderPart2(55, 7);
