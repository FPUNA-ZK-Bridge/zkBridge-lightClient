pragma circom 2.0.3;

include "./header_verification_split.circom";

// Part 2: MillerLoop
// ONE validator version (same as mini/production - ~8M constraints)
// Estimated: ~8M constraints, ~20GB RAM
component main { public [ aggregated_pubkey, signature, Hm_G2 ] } = VerifyHeaderPart2(55, 7);
