pragma circom 2.0.3;

include "./header_verification_128_split.circom";

// =============================================================================
// ONE (b=1) wrappers for the 128-split design
// =============================================================================
// The original Part1A/Part1B templates assume b >= 2 (Part1A) and/or are not
// safe/meaningful for b=1 edge-cases. These wrappers make the 8-part split
// pipeline runnable with exactly one validator.
//
// Additionally, Part3B is modified to COMPUTE validity but NOT CONSTRAIN it to 1,
// so the circuit remains satisfiable even when the BLS verification fails.

// -----------------------------------------------------------------------------
// Part 1A ONE: HashToField + bitSum + PubkeyPoseidon
// -----------------------------------------------------------------------------
template VerifyHeader128OnePart1A(n, k) {
    signal input pubkeys[1][2][k];
    signal input pubkeybits[1];
    signal input signing_root[32];

    signal output hash_field[2][2][k];
    signal output bitSum;
    signal output syncCommitteePoseidon;

    component hashToField = HashToField(32, 2);
    for (var i = 0; i < 32; i++) {
        hashToField.msg[i] <== signing_root[i];
    }

    for (var i = 0; i < 2; i++) {
        for (var j = 0; j < 2; j++) {
            for (var l = 0; l < k; l++) {
                hash_field[i][j][l] <== hashToField.result[i][j][l];
            }
        }
    }

    bitSum <== pubkeybits[0];

    component poseidonSyncCommittee = PubkeyPoseidon(1, k);
    for (var j = 0; j < k; j++) {
        poseidonSyncCommittee.pubkeys[0][0][j] <== pubkeys[0][0][j];
        poseidonSyncCommittee.pubkeys[0][1][j] <== pubkeys[0][1][j];
    }
    syncCommitteePoseidon <== poseidonSyncCommittee.out;
}

// -----------------------------------------------------------------------------
// Part 1B ONE: aggregated_pubkey (single key)
// -----------------------------------------------------------------------------
template VerifyHeader128OnePart1B(n, k) {
    signal input pubkeys[1][2][k];
    signal input pubkeybits[1];

    signal output aggregated_pubkey[2][k];

    // Enforce we always aggregate this single key (avoids "point at infinity"
    // representation questions for b=1).
    pubkeybits[0] === 1;

    for (var i = 0; i < 2; i++) {
        for (var j = 0; j < k; j++) {
            aggregated_pubkey[i][j] <== pubkeys[0][i][j];
        }
    }

    // Groth16 requires >= 1 R1CS constraint. With b=1 all constraints above
    // are linear and --O1 eliminates them entirely. This quadratic constraint
    // (cross-product of two free-input pubkey limbs) survives optimization.
    signal _nonlinGuard;
    _nonlinGuard <== pubkeys[0][0][0] * pubkeys[0][1][0];
}

// -----------------------------------------------------------------------------
// Part 3B ONE: FinalExpHardPart + computed validity (NOT constrained)
// -----------------------------------------------------------------------------
template VerifyHeader128OnePart3B(n, k) {
    signal input easy_out[6][2][k];

    // 1 if pairing check passes, 0 otherwise (not a public signal by default)
    signal output isValid;

    var p[50] = get_BLS12_381_prime(n, k);

    component hardPart = FinalExpHardPart(n, k, p);
    for (var id = 0; id < 6; id++) {
        for (var eps = 0; eps < 2; eps++) {
            for (var j = 0; j < k; j++)
                hardPart.in[id][eps][j] <== easy_out[id][eps][j];
        }
    }

    // Same validity computation as VerifyHeader128Part3B, but without enforcing == 1
    component is_valid[6][2][k];
    var total = 12 * k;
    for (var i = 0; i < 6; i++) {
        for (var j = 0; j < 2; j++) {
            for (var idx = 0; idx < k; idx++) {
                is_valid[i][j][idx] = IsZero();
                if (i == 0 && j == 0 && idx == 0)
                    is_valid[i][j][idx].in <== hardPart.out[i][j][idx] - 1;
                else
                    is_valid[i][j][idx].in <== hardPart.out[i][j][idx];
                total -= is_valid[i][j][idx].out;
            }
        }
    }
    component valid = IsZero();
    valid.in <== total;
    isValid <== valid.out;
}

