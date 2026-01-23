pragma circom 2.0.3;

include "../utils/circom-pairing/circuits/final_exp.circom";
include "../utils/circom-pairing/circuits/bls12_381_func.circom";

// Part 3: FinalExponentiate (TEST-ONLY - computes but does not verify)
// ONE validator version for testing circuit flow
// Estimated: ~5M constraints, ~12GB RAM
//
// ⚠️ This does NOT verify FinalExp == 1 because the signature generated
// by @noble/bls12-381 uses a different hash_to_curve than the circuit.
// For real verification, use production mode with real Beacon Chain data.

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
    
    // Output the result without verification
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
