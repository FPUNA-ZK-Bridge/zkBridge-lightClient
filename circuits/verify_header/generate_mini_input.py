#!/usr/bin/env python3
"""
Generate valid BLS signature input for 8 validators (mini mode).

This script:
1. Generates 8 BLS12-381 key pairs
2. Signs a message (signing_root) with each key
3. Aggregates the signatures
4. Outputs JSON in the format expected by verify_header circuits

Requirements:
    pip install py_ecc

Usage:
    python generate_mini_input.py [--output input/test_8_validators.json]
"""

import json
import sys
import os
from typing import List, Tuple
import secrets

try:
    from py_ecc.bls import G2ProofOfPossession as bls
    from py_ecc.bls.g2_primitives import (
        pubkey_to_G1,
        signature_to_G2,
        G1_to_pubkey,
        G2_to_signature,
    )
    from py_ecc.fields import optimized_bls12_381_FQ as FQ
    from py_ecc.fields import optimized_bls12_381_FQ2 as FQ2
    from py_ecc.optimized_bls12_381 import (
        G1,
        G2,
        multiply,
        add,
        curve_order,
        field_modulus,
        normalize,
    )
except ImportError:
    print("ERROR: py_ecc not installed. Run: pip install py_ecc")
    sys.exit(1)


# Circuit parameters
N_BITS = 55  # Bits per limb
K_LIMBS = 7  # Number of limbs (55 * 7 = 385 > 381 bits)
NUM_VALIDATORS = 8


def bigint_to_limbs(x: int, n: int = N_BITS, k: int = K_LIMBS) -> List[str]:
    """Convert a big integer to k limbs of n bits each."""
    mod = 1 << n  # 2^n
    limbs = []
    x_temp = x
    for _ in range(k):
        limbs.append(str(x_temp % mod))
        x_temp //= mod
    return limbs


def g1_point_to_circuit(point) -> List[List[str]]:
    """Convert a G1 point to circuit format [x_limbs, y_limbs]."""
    # Normalize the point (convert from projective to affine)
    normalized = normalize(point)
    x, y = normalized[0], normalized[1]
    
    # Extract the integer values from FQ elements
    x_int = x.n if hasattr(x, 'n') else int(x)
    y_int = y.n if hasattr(y, 'n') else int(y)
    
    return [bigint_to_limbs(x_int), bigint_to_limbs(y_int)]


def g2_point_to_circuit(point) -> List[List[List[str]]]:
    """Convert a G2 point to circuit format [[x0_limbs, x1_limbs], [y0_limbs, y1_limbs]]."""
    # Normalize the point (convert from projective to affine)
    normalized = normalize(point)
    x, y = normalized[0], normalized[1]
    
    # x and y are FQ2 elements with coeffs[0] and coeffs[1]
    # FQ2 = c0 + c1 * u where u^2 = -1
    x0 = x.coeffs[0].n if hasattr(x.coeffs[0], 'n') else int(x.coeffs[0])
    x1 = x.coeffs[1].n if hasattr(x.coeffs[1], 'n') else int(x.coeffs[1])
    y0 = y.coeffs[0].n if hasattr(y.coeffs[0], 'n') else int(y.coeffs[0])
    y1 = y.coeffs[1].n if hasattr(y.coeffs[1], 'n') else int(y.coeffs[1])
    
    return [
        [bigint_to_limbs(x0), bigint_to_limbs(x1)],
        [bigint_to_limbs(y0), bigint_to_limbs(y1)]
    ]


def generate_keypair() -> Tuple[bytes, bytes]:
    """Generate a BLS key pair."""
    # Generate a valid secret key (must be < curve_order and > 0)
    while True:
        secret_key_int = secrets.randbelow(curve_order - 1) + 1  # 1 to curve_order-1
        secret_key = secret_key_int.to_bytes(32, byteorder='big')
        try:
            public_key = bls.SkToPk(secret_key)
            return secret_key, public_key
        except Exception:
            continue  # Retry if invalid


def main():
    output_file = "input/test_8_validators.json"
    if len(sys.argv) > 2 and sys.argv[1] == "--output":
        output_file = sys.argv[2]
    
    print("=" * 60)
    print("Generating valid BLS input for 8 validators")
    print("=" * 60)
    
    # Step 1: Generate a signing_root (32 bytes)
    print("\n[1/5] Generating signing_root...")
    signing_root_bytes = secrets.token_bytes(32)
    signing_root = [str(b) for b in signing_root_bytes]
    print(f"  signing_root (hex): {signing_root_bytes.hex()}")
    
    # Step 2: Generate 8 key pairs
    print(f"\n[2/5] Generating {NUM_VALIDATORS} BLS key pairs...")
    keypairs = []
    for i in range(NUM_VALIDATORS):
        sk, pk = generate_keypair()
        keypairs.append((sk, pk))
        print(f"  Validator {i}: pk={pk[:8].hex()}...")
    
    # Step 3: Each validator signs the message
    print(f"\n[3/5] Signing message with each validator...")
    signatures = []
    for i, (sk, pk) in enumerate(keypairs):
        sig = bls.Sign(sk, signing_root_bytes)
        signatures.append(sig)
        print(f"  Validator {i} signed: sig={sig[:8].hex()}...")
    
    # Step 4: Aggregate signatures
    print(f"\n[4/5] Aggregating signatures...")
    aggregated_signature = bls.Aggregate(signatures)
    print(f"  Aggregated signature: {aggregated_signature[:16].hex()}...")
    
    # Verify the aggregated signature
    public_keys = [pk for sk, pk in keypairs]
    # Note: py_ecc doesn't have a direct function to verify aggregate with same message
    # We need to aggregate the pubkeys first
    
    # Convert pubkeys to G1 points and aggregate
    g1_pubkeys = [pubkey_to_G1(pk) for pk in public_keys]
    aggregated_pubkey_g1 = g1_pubkeys[0]
    for pk in g1_pubkeys[1:]:
        aggregated_pubkey_g1 = add(aggregated_pubkey_g1, pk)
    aggregated_pubkey_bytes = G1_to_pubkey(aggregated_pubkey_g1)
    
    # Verify
    is_valid = bls.Verify(aggregated_pubkey_bytes, signing_root_bytes, aggregated_signature)
    print(f"  Signature valid: {is_valid}")
    
    if not is_valid:
        print("ERROR: Generated signature is not valid!")
        sys.exit(1)
    
    # Step 5: Convert to circuit format
    print(f"\n[5/5] Converting to circuit format...")
    
    # Convert pubkeys
    pubkeys_circuit = []
    for i, (sk, pk) in enumerate(keypairs):
        g1_point = pubkey_to_G1(pk)
        pubkeys_circuit.append(g1_point_to_circuit(g1_point))
    print(f"  Converted {len(pubkeys_circuit)} pubkeys")
    
    # Convert aggregated signature (G2 point)
    sig_g2 = signature_to_G2(aggregated_signature)
    signature_circuit = g2_point_to_circuit(sig_g2)
    print(f"  Converted aggregated signature")
    
    # All validators participated
    pubkeybits = ["1"] * NUM_VALIDATORS
    
    # Create the input JSON
    input_data = {
        "signing_root": signing_root,
        "pubkeys": pubkeys_circuit,
        "pubkeybits": pubkeybits,
        "signature": signature_circuit
    }
    
    # Write to file
    os.makedirs(os.path.dirname(output_file) if os.path.dirname(output_file) else ".", exist_ok=True)
    with open(output_file, 'w') as f:
        json.dump(input_data, f, indent=2)
    
    print(f"\n{'=' * 60}")
    print(f"✓ Generated valid input for {NUM_VALIDATORS} validators")
    print(f"✓ Output saved to: {output_file}")
    print(f"{'=' * 60}")
    
    # Print verification info
    print("\nTo use this input:")
    print(f"  1. Copy to the expected location:")
    print(f"     cp {output_file} input/6154570_input_mini.json")
    print(f"  2. Run the split circuits:")
    print(f"     ./run_split.sh --mini --witness-only")


if __name__ == "__main__":
    main()
