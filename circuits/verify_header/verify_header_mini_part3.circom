pragma circom 2.0.3;

include "./header_verification_split.circom";

// Part 3: FinalExponentiate + Verification  
// MINI version for testing (same constraints as production - ~5M)
// Estimated: ~5M constraints, ~12-15GB RAM
component main { public [ miller_out ] } = VerifyHeaderPart3(55, 7);
