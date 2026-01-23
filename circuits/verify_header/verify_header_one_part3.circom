pragma circom 2.0.3;

include "../utils/circom-pairing/circuits/final_exp.circom";
include "../utils/circom-pairing/circuits/bls12_381_func.circom";

// Part 3: FinalExponentiate (TEST-ONLY - NO VERIFICATION)
// ONE validator version for testing circuit flow
// Estimated: ~5M constraints, ~12-15GB RAM
//
// ⚠️ WARNING: This does NOT verify the signature!
// It only computes FinalExponentiate without checking the result.
// Use this to test the circuit pipeline, not for production.
// This allows testing even when signing_root is incorrect or signatures don't match.

template VerifyHeaderPart3TestOnly(n, k) {
    signal input miller_out[6][2][k];

    var q[50] = get_BLS12_381_prime(n, k);

    component finalexp = FinalExponentiate(n, k, q);
    for (var i = 0; i < 6; i++) {
        for (var j = 0; j < 2; j++) {
            for (var idx = 0; idx < k; idx++) {
                finalexp.in[i][j][idx] <== miller_out[i][j][idx];
            }
        }
    }
    
    // Output the result but don't verify it equals 1
    // This allows testing the circuit flow without valid signatures
    signal output result[6][2][k];
    for (var i = 0; i < 6; i++) {
        for (var j = 0; j < 2; j++) {
            for (var idx = 0; idx < k; idx++) {
                result[i][j][idx] <== finalexp.out[i][j][idx];
            }
        }
    }
}

component main { public [ miller_out ] } = VerifyHeaderPart3TestOnly(55, 7);
