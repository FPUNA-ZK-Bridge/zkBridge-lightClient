pragma circom 2.0.3;

include "./header_verification_128_one.circom";

// Part 1A ONE: HashToField + bitSum + PubkeyPoseidon (b=1)
component main { public [ signing_root ] } = VerifyHeader128OnePart1A(55, 7);

