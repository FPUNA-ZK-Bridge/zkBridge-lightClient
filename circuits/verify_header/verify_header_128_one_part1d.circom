pragma circom 2.0.3;

include "./header_verification_128_one.circom";

// Part 1D ONE: ClearCofactorG2 (first half) - same as production
component main = VerifyHeader128Part1D(55, 7);

