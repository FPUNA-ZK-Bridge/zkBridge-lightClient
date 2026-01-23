#!/bin/bash

# =============================================================================
# Verify Header Split Circuit - Build and Proof Generation
# =============================================================================
# This script compiles, generates witnesses, trusted setup, and proofs for
# the 3 split header verification circuits.
#
# The split reduces RAM usage by running 3 smaller circuits sequentially:
#   Part1: HashToField + Aggregation + Checks + MapToG2 + bitSum + Poseidon
#   Part2: MillerLoop
#   Part3: FinalExponentiate + Verification
#
# Usage: 
#   ./run_split.sh [--mini] [--compile-only] [--witness-only] [--full]
#
# Options:
#   --mini          Use mini version (8 validators) for testing on low-RAM machines
#   --compile-only  Only compile the circuits
#   --witness-only  Only generate witnesses (requires compiled circuits)
#   --full          Full pipeline: compile + witness + zkey + proof (default)
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_BASE="$SCRIPT_DIR/build_split"

# Check for mode
MINI_MODE=false
ONE_MODE=false
for arg in "$@"; do
    if [ "$arg" == "--mini" ]; then
        MINI_MODE=true
    fi
    if [ "$arg" == "--one" ]; then
        ONE_MODE=true
    fi
done

if [ "$ONE_MODE" = true ]; then
    echo ">>> ONE MODE: Using 1 validator for minimal testing <<<"
    BUILD_BASE="$SCRIPT_DIR/build_split_one"
    CIRCUIT_PREFIX="verify_header_one"
    NUM_VALIDATORS=1
elif [ "$MINI_MODE" = true ]; then
    echo ">>> MINI MODE: Using 8 validators for testing <<<"
    BUILD_BASE="$SCRIPT_DIR/build_split_mini"
    CIRCUIT_PREFIX="verify_header_mini"
    NUM_VALIDATORS=8
else
    echo ">>> PRODUCTION MODE: Using 512 validators <<<"
    CIRCUIT_PREFIX="verify_header"
    NUM_VALIDATORS=512
fi

# Powers of Tau file - adjust path as needed
PHASE1="$SCRIPT_DIR/../../powers_of_tau/powersOfTau28_hez_final_27.ptau"
PHASE1_ALT="/home_data/mvillagra/tusima-jose/powers_of_tau/powersOfTau28_hez_final_27.ptau"

# Node path (use system node by default, or patched node if available)
PATCHED_NODE_PATH="/home_data/mvillagra/tusima-jose/node/out/Release/node"

is_runnable_node() {
    local p="$1"
    [ -f "$p" ] && [ -x "$p" ] && "$p" --version >/dev/null 2>&1
}

if is_runnable_node "$PATCHED_NODE_PATH"; then
    NODE_PATH="$PATCHED_NODE_PATH"
    NODE_OPTS="--trace-gc --trace-gc-ignore-scavenger --max-old-space-size=2048000 --initial-old-space-size=2048000 --no-global-gc-scheduling --no-incremental-marking --max-semi-space-size=1024 --initial-heap-size=2048000 --expose-gc"
elif is_runnable_node "$SCRIPT_DIR/../../node/out/Release/node"; then
    NODE_PATH="$SCRIPT_DIR/../../node/out/Release/node"
    NODE_OPTS="--trace-gc --trace-gc-ignore-scavenger --max-old-space-size=2048000 --initial-old-space-size=2048000 --no-global-gc-scheduling --no-incremental-marking --max-semi-space-size=1024 --initial-heap-size=2048000 --expose-gc"
else
    NODE_PATH="node"
    NODE_OPTS="--max-old-space-size=8192"
fi

# Rapidsnark prover (optional)
PROVER_PATH="$SCRIPT_DIR/../../rapidsnark/build/prover"

# Input file
INPUT_DIR="$SCRIPT_DIR/input"
SLOT="${SLOT:-6154570}"

# Verifier output directory
VERIFIER_DIR="$SCRIPT_DIR/contract_split"

# =============================================================================
# Helper Functions
# =============================================================================

log_step() {
    echo ""
    echo "========================================"
    echo "$1"
    echo "========================================"
}

log_substep() {
    echo "---- $1"
}

check_phase1() {
    if [ -f "$PHASE1" ]; then
        echo "Found Phase 1 ptau file: $PHASE1"
    elif [ -f "$PHASE1_ALT" ]; then
        PHASE1="$PHASE1_ALT"
        echo "Found Phase 1 ptau file: $PHASE1"
    else
        echo "ERROR: No Phase 1 ptau file found."
        echo "Please download from: https://github.com/iden3/snarkjs#7-prepare-phase-2"
        echo "Expected locations:"
        echo "  - $PHASE1"
        echo "  - $PHASE1_ALT"
        exit 1
    fi
}

ensure_dirs() {
    mkdir -p "$BUILD_BASE/part1"
    mkdir -p "$BUILD_BASE/part2"
    mkdir -p "$BUILD_BASE/part3"
    mkdir -p "$VERIFIER_DIR"
    mkdir -p "$SCRIPT_DIR/logs"
}

# =============================================================================
# Compilation
# =============================================================================

compile_circuit() {
    local part_num=$1
    local circuit_name="${CIRCUIT_PREFIX}_part${part_num}"
    local build_dir="$BUILD_BASE/part${part_num}"
    
    if [ -f "$build_dir/${circuit_name}.r1cs" ]; then
        log_substep "Circuit $circuit_name already compiled, skipping..."
        return 0
    fi
    
    log_substep "Compiling $circuit_name.circom..."
    echo "This may take a while for large circuits..."
    local start=$(date +%s)
    
    circom "$SCRIPT_DIR/${circuit_name}.circom" \
        --O1 \
        --r1cs \
        --wasm \
        --sym \
        --output "$build_dir"
    
    local end=$(date +%s)
    echo "Compiled in $((end - start))s"
    
    # Show constraint count
    if command -v snarkjs &> /dev/null; then
        echo "Constraint info:"
        snarkjs r1cs info "$build_dir/${circuit_name}.r1cs" 2>/dev/null || true
    fi
}

compile_all() {
    log_step "PHASE: Compiling all circuits ($CIRCUIT_PREFIX)"
    for i in 1 2 3; do
        compile_circuit $i
    done
}

# =============================================================================
# Input Preparation
# =============================================================================

prepare_test_input() {
    local num_validators=$1
    local input_file=$2
    
    log_substep "Preparing test input ($num_validators validator(s))..."
    
    if [ -f "$input_file" ]; then
        echo "Using pre-generated valid input: $input_file"
        return 0
    fi
    
    # Try to generate with JavaScript (faster)
    local gen_script_js="$SCRIPT_DIR/generate_test_input.js"
    if [ -f "$gen_script_js" ]; then
        echo "Pre-generated input not found. Generating with Node.js..."
        $NODE_PATH "$gen_script_js" "$num_validators" "$input_file"
        
        if [ -f "$input_file" ]; then
            echo "Generated valid input with $num_validators validator(s)"
            return 0
        fi
    fi
    
    echo "ERROR: Input file not found: $input_file"
    echo "Please generate it first by running:"
    echo "  node generate_test_input.js $num_validators $input_file"
    exit 1
}

get_input_file() {
    if [ "$ONE_MODE" = true ]; then
        echo "$INPUT_DIR/your_key_1_validator.json"
    elif [ "$MINI_MODE" = true ]; then
        echo "$INPUT_DIR/your_key_8_validators.json"
    else
        echo "$INPUT_DIR/${SLOT}_input.json"
    fi
}

# =============================================================================
# Witness Generation with Chaining
# =============================================================================

generate_witness_part1() {
    local build_dir="$BUILD_BASE/part1"
    local circuit_name="${CIRCUIT_PREFIX}_part1"
    local input_file=$(get_input_file)
    
    log_substep "Generating witness for Part1..."
    echo "  Input file: $input_file"
    
    if [ ! -f "$input_file" ]; then
        echo "ERROR: Input file not found: $input_file"
        exit 1
    fi
    
    local start=$(date +%s)
    local step_start=$(date +%s)
    
    # Copy input file
    cp "$input_file" "$build_dir/input.json"
    
    echo "  [Part1] Running witness generation (WASM)..."
    # Generate witness using WASM
    $NODE_PATH "$build_dir/${circuit_name}_js/generate_witness.js" \
        "$build_dir/${circuit_name}_js/${circuit_name}.wasm" \
        "$build_dir/input.json" \
        "$build_dir/witness.wtns"
    
    local witness_end=$(date +%s)
    echo "  [Part1] Witness WASM completed in $((witness_end - step_start))s"
    
    echo "  [Part1] Exporting witness to JSON..."
    step_start=$(date +%s)
    # Export to JSON to extract public signals
    snarkjs wtns export json "$build_dir/witness.wtns" "$build_dir/witness.json"
    
    local end=$(date +%s)
    echo "  [Part1] JSON export completed in $((end - step_start))s"
    echo ""
    echo ">>> Part1 TOTAL: $((end - start))s <<<"
    PART1_TIME=$((end - start))
}

generate_witness_part2() {
    local build_dir_1="$BUILD_BASE/part1"
    local build_dir_2="$BUILD_BASE/part2"
    local circuit_name="${CIRCUIT_PREFIX}_part2"
    local input_file=$(get_input_file)
    
    log_substep "Generating witness for Part2..."
    local start=$(date +%s)
    local step_start=$(date +%s)
    
    echo "  [Part2] Extracting Hm_G2 and aggregated_pubkey from Part1..."
    # Extract Hm_G2 and aggregated_pubkey from Part1 witness and create Part2 input
    $NODE_PATH -e "
    const fs = require('fs');
    
    // Read Part1 witness
    const witness1 = JSON.parse(fs.readFileSync('$build_dir_1/witness.json', 'utf8'));
    
    // Read original input for signature
    const originalInput = JSON.parse(fs.readFileSync('$input_file', 'utf8'));
    
    // Part1 outputs order in witness (after index 0 which is always 1):
    // Hm_G2[2][2][7] = 28 values (indices 1-28)
    // aggregated_pubkey[2][7] = 14 values (indices 29-42)
    // bitSum = 1 value (index 43)
    // syncCommitteePoseidon = 1 value (index 44)
    
    const k = 7;
    
    // Extract Hm_G2 [2][2][7]
    const Hm_G2_flat = witness1.slice(1, 29);
    const Hm_G2 = [];
    let idx = 0;
    for (let i = 0; i < 2; i++) {
        Hm_G2[i] = [];
        for (let j = 0; j < 2; j++) {
            Hm_G2[i][j] = Hm_G2_flat.slice(idx, idx + k);
            idx += k;
        }
    }
    
    // Extract aggregated_pubkey [2][7]
    const agg_pubkey_flat = witness1.slice(29, 43);
    const aggregated_pubkey = [];
    idx = 0;
    for (let i = 0; i < 2; i++) {
        aggregated_pubkey[i] = agg_pubkey_flat.slice(idx, idx + k);
        idx += k;
    }
    
    // Create Part2 input
    const inputPart2 = {
        aggregated_pubkey: aggregated_pubkey,
        signature: originalInput.signature,
        Hm_G2: Hm_G2
    };
    
    fs.writeFileSync('$build_dir_2/input.json', JSON.stringify(inputPart2, null, 2));
    console.log('  [Part2] Input created from Part1 outputs');
    "
    
    local extract_end=$(date +%s)
    echo "  [Part2] Extraction completed in $((extract_end - step_start))s"
    
    echo "  [Part2] Running witness generation (WASM)..."
    step_start=$(date +%s)
    # Generate witness using WASM
    $NODE_PATH "$build_dir_2/${circuit_name}_js/generate_witness.js" \
        "$build_dir_2/${circuit_name}_js/${circuit_name}.wasm" \
        "$build_dir_2/input.json" \
        "$build_dir_2/witness.wtns"
    
    local witness_end=$(date +%s)
    echo "  [Part2] Witness WASM completed in $((witness_end - step_start))s"
    
    echo "  [Part2] Exporting witness to JSON..."
    step_start=$(date +%s)
    # Export to JSON
    snarkjs wtns export json "$build_dir_2/witness.wtns" "$build_dir_2/witness.json"
    
    local end=$(date +%s)
    echo "  [Part2] JSON export completed in $((end - step_start))s"
    echo ""
    echo ">>> Part2 TOTAL: $((end - start))s <<<"
    PART2_TIME=$((end - start))
}

generate_witness_part3() {
    local build_dir_2="$BUILD_BASE/part2"
    local build_dir_3="$BUILD_BASE/part3"
    local circuit_name="${CIRCUIT_PREFIX}_part3"
    
    log_substep "Generating witness for Part3 (FinalExponentiate)..."
    local start=$(date +%s)
    local step_start=$(date +%s)
    
    echo "  [Part3] Extracting miller_out from Part2..."
    # Extract miller_out from Part2 witness
    $NODE_PATH -e "
    const fs = require('fs');
    
    // Read Part2 witness
    const witness2 = JSON.parse(fs.readFileSync('$build_dir_2/witness.json', 'utf8'));
    
    const k = 7;
    
    // Part2 outputs miller_out[6][2][7] = 84 values at indices 1-84
    const miller_flat = witness2.slice(1, 85);
    
    // Reshape miller_out to [6][2][7]
    const miller_out = [];
    let idx = 0;
    for (let i = 0; i < 6; i++) {
        miller_out[i] = [];
        for (let j = 0; j < 2; j++) {
            miller_out[i][j] = miller_flat.slice(idx, idx + k);
            idx += k;
        }
    }
    
    // Create Part3 input
    const inputPart3 = {
        miller_out: miller_out
    };
    
    fs.writeFileSync('$build_dir_3/input.json', JSON.stringify(inputPart3, null, 2));
    console.log('  [Part3] Input created from Part2 outputs');
    "
    
    local extract_end=$(date +%s)
    echo "  [Part3] Extraction completed in $((extract_end - step_start))s"
    
    if [ "$MINI_MODE" = true ] && [ "$ONE_MODE" = false ]; then
        echo "  [Part3] Running witness generation (WASM) - TEST MODE (no signature verification)..."
    else
        echo "  [Part3] Running witness generation (WASM) - This verifies FinalExp == 1..."
    fi
    step_start=$(date +%s)
    # Generate witness using WASM
    $NODE_PATH "$build_dir_3/${circuit_name}_js/generate_witness.js" \
        "$build_dir_3/${circuit_name}_js/${circuit_name}.wasm" \
        "$build_dir_3/input.json" \
        "$build_dir_3/witness.wtns"
    
    local witness_end=$(date +%s)
    echo "  [Part3] Witness WASM completed in $((witness_end - step_start))s"
    if [ "$MINI_MODE" = true ] && [ "$ONE_MODE" = false ]; then
        echo "  [Part3] ✓ FinalExponentiate computed (TEST MODE - not verified)"
    else
        echo "  [Part3] ✓ FinalExponentiate verification PASSED!"
    fi
    
    echo "  [Part3] Exporting witness to JSON..."
    step_start=$(date +%s)
    # Export to JSON
    snarkjs wtns export json "$build_dir_3/witness.wtns" "$build_dir_3/witness.json"
    
    local end=$(date +%s)
    echo "  [Part3] JSON export completed in $((end - step_start))s"
    echo ""
    echo ">>> Part3 TOTAL: $((end - start))s <<<"
    PART3_TIME=$((end - start))
}

generate_all_witnesses() {
    log_step "PHASE: Generating witnesses (with chaining)"
    
    # Initialize timing variables
    PART1_TIME=0
    PART2_TIME=0
    PART3_TIME=0
    local total_start=$(date +%s)
    
    if [ "$ONE_MODE" = true ]; then
        prepare_test_input 1 "$INPUT_DIR/your_key_1_validator.json"
    elif [ "$MINI_MODE" = true ]; then
        prepare_test_input 8 "$INPUT_DIR/your_key_8_validators.json"
    fi
    
    generate_witness_part1
    generate_witness_part2
    generate_witness_part3
    
    local total_end=$(date +%s)
    local total_time=$((total_end - total_start))
    
    echo ""
    echo "========================================"
    echo "         WITNESS GENERATION SUMMARY"
    echo "========================================"
    echo "  Part1 (HashToField+Aggregation+MapToG2): ${PART1_TIME}s"
    echo "  Part2 (MillerLoop):                      ${PART2_TIME}s"
    echo "  Part3 (FinalExponentiate):               ${PART3_TIME}s"
    echo "  ----------------------------------------"
    echo "  TOTAL:                                   ${total_time}s"
    echo "========================================"
    echo ""
    echo "✓ All witnesses generated successfully!"
    if [ "$ONE_MODE" = true ]; then
        echo "✓ BLS signature verification PASSED! (1 validator)"
    elif [ "$MINI_MODE" = true ]; then
        echo ""
        echo "⚠️  NOTE: Mini mode uses TEST-ONLY Part3 (no signature verification)."
        echo "    For real BLS verification, use --one or production mode."
    else
        echo "✓ BLS signature verification PASSED! (512 validators)"
    fi
}

# =============================================================================
# Trusted Setup (zkey generation)
# =============================================================================

generate_zkey() {
    local part_num=$1
    local circuit_name="${CIRCUIT_PREFIX}_part${part_num}"
    local build_dir="$BUILD_BASE/part${part_num}"
    
    if [ -f "$build_dir/${circuit_name}.zkey" ]; then
        log_substep "zkey for $circuit_name already exists, skipping..."
        return 0
    fi
    
    log_substep "Generating zkey for $circuit_name..."
    echo "WARNING: This requires significant RAM and may take hours..."
    local start=$(date +%s)
    
    # Phase 2 setup
    $NODE_PATH $NODE_OPTS \
        $(which snarkjs) zkey new \
        "$build_dir/${circuit_name}.r1cs" \
        "$PHASE1" \
        "$build_dir/${circuit_name}_0.zkey"
    
    # Contribute to ceremony
    $NODE_PATH $(which snarkjs) zkey contribute \
        "$build_dir/${circuit_name}_0.zkey" \
        "$build_dir/${circuit_name}.zkey" \
        -n="First contribution" \
        -e="random entropy $(date +%s)"
    
    # Remove intermediate zkey
    rm -f "$build_dir/${circuit_name}_0.zkey"
    
    # Export verification key
    $NODE_PATH $(which snarkjs) zkey export verificationkey \
        "$build_dir/${circuit_name}.zkey" \
        "$build_dir/vkey.json"
    
    local end=$(date +%s)
    echo "zkey generated in $((end - start))s"
}

generate_all_zkeys() {
    log_step "PHASE: Generating trusted setup (zkeys)"
    check_phase1
    for i in 1 2 3; do
        generate_zkey $i
    done
}

# =============================================================================
# Proof Generation
# =============================================================================

generate_proof() {
    local part_num=$1
    local circuit_name="${CIRCUIT_PREFIX}_part${part_num}"
    local build_dir="$BUILD_BASE/part${part_num}"
    
    log_substep "Generating proof for $circuit_name..."
    local start=$(date +%s)
    
    if [ -f "$PROVER_PATH" ]; then
        $PROVER_PATH \
            "$build_dir/${circuit_name}.zkey" \
            "$build_dir/witness.wtns" \
            "$build_dir/proof.json" \
            "$build_dir/public.json"
    else
        $NODE_PATH $NODE_OPTS \
            $(which snarkjs) groth16 prove \
            "$build_dir/${circuit_name}.zkey" \
            "$build_dir/witness.wtns" \
            "$build_dir/proof.json" \
            "$build_dir/public.json"
    fi
    
    local end=$(date +%s)
    echo "Proof generated in $((end - start))s"
}

verify_proof() {
    local part_num=$1
    local circuit_name="${CIRCUIT_PREFIX}_part${part_num}"
    local build_dir="$BUILD_BASE/part${part_num}"
    
    log_substep "Verifying proof for $circuit_name..."
    
    $NODE_PATH $(which snarkjs) groth16 verify \
        "$build_dir/vkey.json" \
        "$build_dir/public.json" \
        "$build_dir/proof.json"
}

generate_all_proofs() {
    log_step "PHASE: Generating proofs"
    for i in 1 2 3; do
        generate_proof $i
    done
    
    log_step "PHASE: Verifying proofs"
    for i in 1 2 3; do
        verify_proof $i
    done
}

# =============================================================================
# Export Solidity Verifiers
# =============================================================================

export_verifiers() {
    log_step "PHASE: Exporting Solidity verifiers"
    
    for i in 1 2 3; do
        local circuit_name="${CIRCUIT_PREFIX}_part${i}"
        local build_dir="$BUILD_BASE/part${i}"
        local verifier_name="VerifierHeaderPart${i}.sol"
        
        if [ -f "$build_dir/${circuit_name}.zkey" ]; then
            log_substep "Exporting verifier for Part${i}..."
            $NODE_PATH $(which snarkjs) zkey export solidityverifier \
                "$build_dir/${circuit_name}.zkey" \
                "$VERIFIER_DIR/$verifier_name"
            echo "Created $VERIFIER_DIR/$verifier_name"
        else
            echo "WARNING: zkey for Part${i} not found, skipping verifier export"
        fi
    done
    
    # Generate calldata for each proof
    log_substep "Generating calldata..."
    for i in 1 2 3; do
        local build_dir="$BUILD_BASE/part${i}"
        if [ -f "$build_dir/proof.json" ] && [ -f "$build_dir/public.json" ]; then
            $NODE_PATH $(which snarkjs) zkey export soliditycalldata \
                "$build_dir/public.json" \
                "$build_dir/proof.json" \
                > "$build_dir/calldata.txt"
            echo "Created $build_dir/calldata.txt"
        fi
    done
}

# =============================================================================
# Summary
# =============================================================================

print_summary() {
    log_step "SUMMARY"
    
    echo "Mode: $([ "$MINI_MODE" = true ] && echo 'MINI (8 validators)' || echo 'PRODUCTION (512 validators)')"
    echo "Build directory: $BUILD_BASE"
    echo ""
    
    echo "Part 1 outputs (for on-chain verification):"
    if [ -f "$BUILD_BASE/part1/witness.json" ]; then
        $NODE_PATH -e "
        const fs = require('fs');
        const w = JSON.parse(fs.readFileSync('$BUILD_BASE/part1/witness.json', 'utf8'));
        console.log('  bitSum:', w[43]);
        console.log('  syncCommitteePoseidon:', w[44]);
        "
    else
        echo "  (not yet generated)"
    fi
    
    echo ""
    echo "Files generated:"
    for i in 1 2 3; do
        local build_dir="$BUILD_BASE/part${i}"
        echo "  Part${i}:"
        [ -f "$build_dir/${CIRCUIT_PREFIX}_part${i}.r1cs" ] && echo "    ✓ r1cs" || echo "    ✗ r1cs"
        [ -f "$build_dir/witness.wtns" ] && echo "    ✓ witness" || echo "    ✗ witness"
        [ -f "$build_dir/${CIRCUIT_PREFIX}_part${i}.zkey" ] && echo "    ✓ zkey" || echo "    ✗ zkey"
        [ -f "$build_dir/proof.json" ] && echo "    ✓ proof" || echo "    ✗ proof"
    done
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo "=============================================="
    echo "Verify Header Split Circuit - Build & Prove"
    echo "=============================================="
    echo "Script directory: $SCRIPT_DIR"
    echo "Build directory: $BUILD_BASE"
    echo "Node: $NODE_PATH"
    echo "Validators: $NUM_VALIDATORS"
    echo ""
    
    # Parse mode (skip --mini as it's already handled)
    local mode="full"
    for arg in "$@"; do
        case "$arg" in
            --compile-only) mode="compile" ;;
            --witness-only) mode="witness" ;;
            --zkey-only) mode="zkey" ;;
            --proof-only) mode="proof" ;;
            --export-verifiers) mode="export" ;;
            --summary) mode="summary" ;;
            --full) mode="full" ;;
        esac
    done
    
    ensure_dirs
    
    case "$mode" in
        compile)
            compile_all
            ;;
        witness)
            generate_all_witnesses
            ;;
        zkey)
            generate_all_zkeys
            ;;
        proof)
            generate_all_proofs
            ;;
        export)
            export_verifiers
            ;;
        summary)
            print_summary
            ;;
        full)
            compile_all
            generate_all_witnesses
            generate_all_zkeys
            generate_all_proofs
            export_verifiers
            print_summary
            ;;
    esac
    
    echo ""
    echo "=============================================="
    echo "Done!"
    echo "=============================================="
}

# Run with logging
mkdir -p "$SCRIPT_DIR/logs"
main "$@" 2>&1 | tee "$SCRIPT_DIR/logs/run_split_$(date '+%Y-%m-%d-%H-%M').log"
