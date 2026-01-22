#!/usr/bin/env node
/**
 * Debug script to verify the signature format matches what the circuit expects.
 * Compares with the original 6154570_input.json structure.
 */

const fs = require('fs');

async function main() {
    const bls = await import('@noble/bls12-381');
    
    console.log('='.repeat(70));
    console.log('DEBUG: Signature Format Analysis');
    console.log('='.repeat(70));
    
    // Load the generated input
    const generatedInput = JSON.parse(fs.readFileSync('input/test_8_validators.json', 'utf8'));
    
    // Load the original input for comparison
    let originalInput = null;
    try {
        originalInput = JSON.parse(fs.readFileSync('input/6154570_input.json', 'utf8'));
    } catch (e) {
        console.log('Original input not found, skipping comparison\n');
    }
    
    // Constants
    const N_BITS = 55n;
    const K_LIMBS = 7;
    
    // Helper: Convert limbs back to bigint
    function limbsToBigint(limbs) {
        let result = 0n;
        for (let i = limbs.length - 1; i >= 0; i--) {
            result = result * (1n << N_BITS) + BigInt(limbs[i]);
        }
        return result;
    }
    
    console.log('\n[1] STRUCTURE CHECK');
    console.log('-'.repeat(70));
    console.log(`signing_root: ${generatedInput.signing_root.length} bytes`);
    console.log(`pubkeys: ${generatedInput.pubkeys.length} validators`);
    console.log(`pubkeybits: ${generatedInput.pubkeybits.length} bits`);
    console.log(`signature: [${generatedInput.signature.length}][${generatedInput.signature[0].length}][${generatedInput.signature[0][0].length}]`);
    
    if (originalInput) {
        console.log('\nOriginal structure:');
        console.log(`signature: [${originalInput.signature.length}][${originalInput.signature[0].length}][${originalInput.signature[0][0].length}]`);
    }
    
    console.log('\n[2] SIGNATURE VALUES (first pubkey)');
    console.log('-'.repeat(70));
    
    // Reconstruct signature coordinates
    const sig = generatedInput.signature;
    const x_c0 = limbsToBigint(sig[0][0]);
    const x_c1 = limbsToBigint(sig[0][1]);
    const y_c0 = limbsToBigint(sig[1][0]);
    const y_c1 = limbsToBigint(sig[1][1]);
    
    console.log('Generated signature (G2 point):');
    console.log(`  x.c0 = ${x_c0.toString(16).slice(0, 40)}...`);
    console.log(`  x.c1 = ${x_c1.toString(16).slice(0, 40)}...`);
    console.log(`  y.c0 = ${y_c0.toString(16).slice(0, 40)}...`);
    console.log(`  y.c1 = ${y_c1.toString(16).slice(0, 40)}...`);
    
    if (originalInput) {
        const origSig = originalInput.signature;
        const orig_x_c0 = limbsToBigint(origSig[0][0]);
        const orig_x_c1 = limbsToBigint(origSig[0][1]);
        const orig_y_c0 = limbsToBigint(origSig[1][0]);
        const orig_y_c1 = limbsToBigint(origSig[1][1]);
        
        console.log('\nOriginal signature (G2 point):');
        console.log(`  x.c0 = ${orig_x_c0.toString(16).slice(0, 40)}...`);
        console.log(`  x.c1 = ${orig_x_c1.toString(16).slice(0, 40)}...`);
        console.log(`  y.c0 = ${orig_y_c0.toString(16).slice(0, 40)}...`);
        console.log(`  y.c1 = ${orig_y_c1.toString(16).slice(0, 40)}...`);
    }
    
    console.log('\n[3] PUBKEY VALUES (first validator)');
    console.log('-'.repeat(70));
    
    const pk = generatedInput.pubkeys[0];
    const pk_x = limbsToBigint(pk[0]);
    const pk_y = limbsToBigint(pk[1]);
    
    console.log('Generated pubkey (G1 point):');
    console.log(`  x = ${pk_x.toString(16).slice(0, 40)}...`);
    console.log(`  y = ${pk_y.toString(16).slice(0, 40)}...`);
    
    // Verify the point is on the curve
    const p = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaabn;
    const b = 4n;
    
    // y^2 = x^3 + 4 (mod p)
    const y2 = (pk_y * pk_y) % p;
    const x3_plus_b = (pk_x * pk_x * pk_x + b) % p;
    const isOnCurve = y2 === x3_plus_b;
    
    console.log(`  On curve (y^2 = x^3 + 4): ${isOnCurve ? '✓ YES' : '✗ NO'}`);
    
    if (!isOnCurve) {
        console.log('\n!!! WARNING: Pubkey is NOT on the BLS12-381 curve !!!');
        console.log('This means the point conversion is incorrect.');
    }
    
    console.log('\n[4] NOBLE LIBRARY POINT STRUCTURE');
    console.log('-'.repeat(70));
    
    // Generate a fresh keypair and examine structure
    const privateKey = bls.utils.randomPrivateKey();
    const publicKey = bls.getPublicKey(privateKey);
    const g1Point = bls.PointG1.fromHex(publicKey);
    const affine = g1Point.toAffine();
    
    console.log('Fresh G1 point affine structure:');
    console.log(`  Type: ${typeof affine}`);
    console.log(`  Is array: ${Array.isArray(affine)}`);
    console.log(`  Length: ${affine.length}`);
    console.log(`  affine[0] type: ${typeof affine[0]}`);
    
    if (affine[0].value !== undefined) {
        console.log(`  affine[0].value: ${affine[0].value.toString(16).slice(0, 20)}...`);
    } else {
        console.log(`  affine[0] (direct): ${BigInt(affine[0].toString()).toString(16).slice(0, 20)}...`);
    }
    
    // Check G2 structure
    const message = new Uint8Array(32).fill(0x42);
    const signature = await bls.sign(message, privateKey);
    const g2Point = bls.PointG2.fromSignature(signature);
    const g2Affine = g2Point.toAffine();
    
    console.log('\nFresh G2 point affine structure:');
    console.log(`  Type: ${typeof g2Affine}`);
    console.log(`  Is array: ${Array.isArray(g2Affine)}`);
    console.log(`  Length: ${g2Affine.length}`);
    console.log(`  g2Affine[0] (x) type: ${typeof g2Affine[0]}`);
    console.log(`  g2Affine[0].c0 exists: ${g2Affine[0].c0 !== undefined}`);
    console.log(`  g2Affine[0].c1 exists: ${g2Affine[0].c1 !== undefined}`);
    
    if (g2Affine[0].c0 !== undefined) {
        const xc0 = g2Affine[0].c0.value !== undefined ? g2Affine[0].c0.value : BigInt(g2Affine[0].c0.toString());
        const xc1 = g2Affine[0].c1.value !== undefined ? g2Affine[0].c1.value : BigInt(g2Affine[0].c1.toString());
        console.log(`  x.c0: ${xc0.toString(16).slice(0, 20)}...`);
        console.log(`  x.c1: ${xc1.toString(16).slice(0, 20)}...`);
    }
    
    console.log('\n[5] FIELD MODULUS CHECK');
    console.log('-'.repeat(70));
    console.log(`BLS12-381 field modulus p:`);
    console.log(`  ${p.toString(16)}`);
    console.log(`  Bits: ${p.toString(2).length}`);
    
    // Check if our values are < p
    console.log(`\nValues < p check:`);
    console.log(`  x_c0 < p: ${x_c0 < p}`);
    console.log(`  x_c1 < p: ${x_c1 < p}`);
    console.log(`  y_c0 < p: ${y_c0 < p}`);
    console.log(`  y_c1 < p: ${y_c1 < p}`);
    
    console.log('\n' + '='.repeat(70));
}

main().catch(err => {
    console.error('Error:', err);
    process.exit(1);
});
