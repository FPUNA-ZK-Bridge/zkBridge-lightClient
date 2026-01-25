pragma circom 2.0.3;

include "./header_verification_128_one.circom";

// Part 1C ONE: Checks + MapToG2 core (same as production; no validator dependency)
component main = VerifyHeader128Part1C(55, 7);

