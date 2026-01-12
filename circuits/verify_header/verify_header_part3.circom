pragma circom 2.0.3;

include "./header_verification_split.circom";

// Part 3: FinalExponentiate + Verification
// Production version
// Inputs: miller_out (from Part2)
// Constrains: signature is valid (FinalExp result == 1)
component main { public [ miller_out ] } = VerifyHeaderPart3(55, 7);
