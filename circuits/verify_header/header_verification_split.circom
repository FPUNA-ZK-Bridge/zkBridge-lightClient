pragma circom 2.0.3;

include "../utils/pubkey_poseidon.circom";
include "./aggregate_bls_verify.circom";
include "../utils/circom-pairing/circuits/bls_signature_split.circom";

// =============================================================================
// Split Header Verification Templates
// =============================================================================
// These templates divide VerifyHeader into 3 parts to reduce RAM usage:
//   Part1: HashToField + AccumulatedECCAdd + CoreVerifyPart1 + bitSum + Poseidon
//   Part2: CoreVerifyPart2 (MillerLoop)
//   Part3: CoreVerifyPart3 (FinalExponentiate + check)
// =============================================================================


// -----------------------------------------------------------------------------
// Part 1: All preprocessing + first part of BLS verification
// -----------------------------------------------------------------------------
// This part handles:
//   - HashToField: Convert signing_root to field elements
//   - AccumulatedECCAdd: Aggregate public keys based on bitmask
//   - CoreVerifyPart1: Range checks, subgroup checks, MapToG2
//   - bitSum: Count of participating validators
//   - PubkeyPoseidon: Merkle root of pubkeys
//
// Inputs: pubkeys, pubkeybits, signature, signing_root
// Outputs: Hm_G2 (G2 point), aggregated_pubkey, bitSum, syncCommitteePoseidon
// -----------------------------------------------------------------------------
template VerifyHeaderPart1(b, n, k) {
    signal input pubkeys[b][2][k];
    signal input pubkeybits[b];
    signal input signature[2][2][k];
    signal input signing_root[32];

    // Outputs that chain to Part2
    signal output Hm_G2[2][2][k];           // G2 point from MapToG2
    signal output aggregated_pubkey[2][k];   // Aggregated public key
    
    // Final outputs (computed here, verified at end)
    signal output bitSum;
    signal output syncCommitteePoseidon;

    // =========================================================================
    // Step 1: HashToField - Convert signing_root to field elements (Fp2)
    // =========================================================================
    component hashToField = HashToField(32, 2);
    for (var i = 0; i < 32; i++) {
        hashToField.msg[i] <== signing_root[i];
    }
    
    signal hash_field[2][2][k];
    for (var i = 0; i < 2; i++) {
        for (var j = 0; j < 2; j++) {
            for (var l = 0; l < k; l++) {
                hash_field[i][j][l] <== hashToField.result[i][j][l];
            }
        }
    }

    // =========================================================================
    // Step 2: Aggregate public keys
    // =========================================================================
    component aggregateKey = AccumulatedECCAdd(b, n, k);
    for (var i = 0; i < b; i++) {
        aggregateKey.pubkeybits[i] <== pubkeybits[i];
        for (var j = 0; j < k; j++) {
            aggregateKey.pubkeys[i][0][j] <== pubkeys[i][0][j];
            aggregateKey.pubkeys[i][1][j] <== pubkeys[i][1][j];
        }
    }
    
    // Output aggregated pubkey for Part2
    for (var i = 0; i < 2; i++) {
        for (var j = 0; j < k; j++) {
            aggregated_pubkey[i][j] <== aggregateKey.out[i][j];
        }
    }

    // =========================================================================
    // Step 3: CoreVerifyPart1 - Checks + MapToG2
    // =========================================================================
    component blsPart1 = CoreVerifyPart1(n, k);
    
    for (var i = 0; i < 2; i++) {
        for (var j = 0; j < k; j++) {
            blsPart1.pubkey[i][j] <== aggregateKey.out[i][j];
        }
    }
    
    for (var i = 0; i < 2; i++) {
        for (var j = 0; j < 2; j++) {
            for (var l = 0; l < k; l++) {
                blsPart1.signature[i][j][l] <== signature[i][j][l];
                blsPart1.hash[i][j][l] <== hash_field[i][j][l];
            }
        }
    }
    
    // Output Hm_G2 for Part2
    for (var i = 0; i < 2; i++) {
        for (var j = 0; j < 2; j++) {
            for (var l = 0; l < k; l++) {
                Hm_G2[i][j][l] <== blsPart1.Hm[i][j][l];
            }
        }
    }

    // =========================================================================
    // Step 4: Calculate bitSum
    // =========================================================================
    signal partialSum[b-1];
    for (var i = 0; i < b - 1; i++) {
        if (i == 0) {
            partialSum[i] <== pubkeybits[0] + pubkeybits[1];
        } else {
            partialSum[i] <== partialSum[i-1] + pubkeybits[i+1];
        }
    }
    bitSum <== partialSum[b-2];

    // =========================================================================
    // Step 5: Calculate Poseidon merkle root of pubkeys
    // =========================================================================
    component poseidonSyncCommittee = PubkeyPoseidon(b, k);
    for (var i = 0; i < b; i++) {
        for (var j = 0; j < k; j++) {
            poseidonSyncCommittee.pubkeys[i][0][j] <== pubkeys[i][0][j];
            poseidonSyncCommittee.pubkeys[i][1][j] <== pubkeys[i][1][j];
        }
    }
    syncCommitteePoseidon <== poseidonSyncCommittee.out;
}


// -----------------------------------------------------------------------------
// Part 2: MillerLoop
// -----------------------------------------------------------------------------
// This part handles the computationally intensive Miller loop.
//
// Inputs: aggregated_pubkey, signature, Hm_G2 (from Part1)
// Outputs: miller_out (Fp12 element)
// -----------------------------------------------------------------------------
template VerifyHeaderPart2(n, k) {
    signal input aggregated_pubkey[2][k];
    signal input signature[2][2][k];
    signal input Hm_G2[2][2][k];
    
    signal output miller_out[6][2][k];

    component blsPart2 = CoreVerifyPart2(n, k);
    
    for (var i = 0; i < 2; i++) {
        for (var j = 0; j < k; j++) {
            blsPart2.pubkey[i][j] <== aggregated_pubkey[i][j];
        }
    }
    
    for (var i = 0; i < 2; i++) {
        for (var j = 0; j < 2; j++) {
            for (var l = 0; l < k; l++) {
                blsPart2.signature[i][j][l] <== signature[i][j][l];
                blsPart2.Hm[i][j][l] <== Hm_G2[i][j][l];
            }
        }
    }
    
    for (var i = 0; i < 6; i++) {
        for (var j = 0; j < 2; j++) {
            for (var l = 0; l < k; l++) {
                miller_out[i][j][l] <== blsPart2.miller_out[i][j][l];
            }
        }
    }
}


// -----------------------------------------------------------------------------
// Part 3: FinalExponentiate + Verification
// -----------------------------------------------------------------------------
// This part handles the final exponentiation and verifies the result equals 1.
//
// Inputs: miller_out (from Part2)
// Outputs: (none - just constrains that the signature is valid)
// -----------------------------------------------------------------------------
template VerifyHeaderPart3(n, k) {
    signal input miller_out[6][2][k];

    component blsPart3 = CoreVerifyPart3(n, k);
    
    for (var i = 0; i < 6; i++) {
        for (var j = 0; j < 2; j++) {
            for (var l = 0; l < k; l++) {
                blsPart3.miller_out[i][j][l] <== miller_out[i][j][l];
            }
        }
    }
    // CoreVerifyPart3 internally constrains that FinalExp(miller_out) == 1
}
