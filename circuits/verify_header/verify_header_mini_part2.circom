pragma circom 2.0.3;

include "./header_verification_split.circom";

// Part 2: MillerLoop
// MINI version for testing (same constraints as production - ~8M)
// Estimated: ~8M constraints, ~20-25GB RAM
component main { public [ aggregated_pubkey, signature, Hm_G2 ] } = VerifyHeaderPart2(55, 7);
