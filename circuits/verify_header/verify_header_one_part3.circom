pragma circom 2.0.3;

include "./header_verification_split.circom";

// Part 3: FinalExponentiate + Verification
// ONE validator version (same as mini/production - ~5M constraints)
// Estimated: ~5M constraints, ~12GB RAM
component main { public [ miller_out ] } = VerifyHeaderPart3(55, 7);
