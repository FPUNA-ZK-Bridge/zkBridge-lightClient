#!/usr/bin/env node
/**
 * Generate valid BLS signature input for 8 validators (mini mode).
 * 
 * This is MUCH faster than the Python version because @noble/bls12-381 is optimized.
 * 
 * Usage:
 *   npm install @noble/bls12-381
 *   node generate_mini_input.js [output_file]
 */

const fs = require('fs');
const path = require('path');

// Dynamic import for ES module
async function main() {
    const bls = await import('@noble/bls12-381');
    
    const NUM_VALIDATORS = 8;
    const N_BITS = 55n;
    const K_LIMBS = 7;
    
    const outputFile = process.argv[2] || 'input/test_8_validators.json';
    
    console.log('='.repeat(60));
    console.log('Generating valid BLS input for 8 validators');
    console.log('='.repeat(60));
    
    // Helper: Convert bigint to array of k limbs of n bits each
    function bigintToLimbs(x, n = N_BITS, k = K_LIMBS) {
        const mod = 1n << n;
        const limbs = [];
        let temp = BigInt(x);
        for (let i = 0; i < k; i++) {
            limbs.push((temp % mod).toString());
            temp = temp / mod;
        }
        return limbs;
    }
    
    // Helper: Get bigint value from Fp element (handles different API versions)
    function getFpValue(fp) {
        if (typeof fp === 'bigint') return fp;
        if (fp.value !== undefined) return fp.value;
        if (fp.valueOf !== undefined) return BigInt(fp.valueOf());
        return BigInt(fp.toString());
    }
    
    // Helper: Convert G1 point to circuit format
    // toAffine() returns [x, y] array where x and y are Fp elements
    function g1ToCircuit(point) {
        const affine = point.toAffine();
        // affine is [x, y] array
        const x = getFpValue(affine[0]);
        const y = getFpValue(affine[1]);
        return [
            bigintToLimbs(x),
            bigintToLimbs(y)
        ];
    }
    
    // Helper: Convert G2 point to circuit format
    // toAffine() returns [x, y] where x and y are Fp2 elements
    function g2ToCircuit(point) {
        const affine = point.toAffine();
        // affine is [x, y] where x and y are Fp2 elements
        const xFp2 = affine[0];
        const yFp2 = affine[1];
        
        // Fp2 elements have c0 and c1 properties
        let x0, x1, y0, y1;
        
        if (xFp2.c0 !== undefined) {
            // API with c0, c1 properties
            x0 = getFpValue(xFp2.c0);
            x1 = getFpValue(xFp2.c1);
            y0 = getFpValue(yFp2.c0);
            y1 = getFpValue(yFp2.c1);
        } else if (Array.isArray(xFp2)) {
            // Array format [c0, c1]
            x0 = getFpValue(xFp2[0]);
            x1 = getFpValue(xFp2[1]);
            y0 = getFpValue(yFp2[0]);
            y1 = getFpValue(yFp2[1]);
        } else {
            throw new Error(`Unknown Fp2 structure: ${typeof xFp2}, keys: ${Object.keys(xFp2 || {})}`);
        }
        
        return [
            [bigintToLimbs(x0), bigintToLimbs(x1)],
            [bigintToLimbs(y0), bigintToLimbs(y1)]
        ];
    }
    
    // Step 1: Generate signing_root (32 random bytes)
    console.log('\n[1/5] Generating signing_root...');
    const signingRootBytes = bls.utils.randomBytes(32);
    const signingRoot = Array.from(signingRootBytes).map(b => b.toString());
    console.log(`  signing_root (hex): ${Buffer.from(signingRootBytes).toString('hex')}`);
    
    // Step 2: Generate 8 key pairs
    console.log(`\n[2/5] Generating ${NUM_VALIDATORS} BLS key pairs...`);
    const keypairs = [];
    for (let i = 0; i < NUM_VALIDATORS; i++) {
        const privateKey = bls.utils.randomPrivateKey();
        const publicKey = bls.getPublicKey(privateKey);
        keypairs.push({ privateKey, publicKey });
        console.log(`  Validator ${i}: pk=${Buffer.from(publicKey).toString('hex').slice(0, 16)}...`);
    }
    
    // Step 3: Each validator signs the message
    console.log(`\n[3/5] Signing message with each validator...`);
    const signatures = [];
    for (let i = 0; i < NUM_VALIDATORS; i++) {
        const sig = await bls.sign(signingRootBytes, keypairs[i].privateKey);
        signatures.push(sig);
        console.log(`  Validator ${i} signed: sig=${Buffer.from(sig).toString('hex').slice(0, 16)}...`);
    }
    
    // Step 4: Aggregate signatures
    console.log(`\n[4/5] Aggregating signatures...`);
    const aggregatedSignature = bls.aggregateSignatures(signatures);
    console.log(`  Aggregated signature: ${Buffer.from(aggregatedSignature).toString('hex').slice(0, 32)}...`);
    
    // Verify the aggregated signature
    const publicKeys = keypairs.map(kp => kp.publicKey);
    const aggregatedPubkey = bls.aggregatePublicKeys(publicKeys);
    const isValid = await bls.verify(aggregatedSignature, signingRootBytes, aggregatedPubkey);
    console.log(`  Signature valid: ${isValid}`);
    
    if (!isValid) {
        console.error('ERROR: Generated signature is not valid!');
        process.exit(1);
    }
    
    // Step 5: Convert to circuit format
    console.log(`\n[5/5] Converting to circuit format...`);
    
    // Debug: inspect point structure
    const samplePoint = bls.PointG1.fromHex(keypairs[0].publicKey);
    const sampleAffine = samplePoint.toAffine();
    console.log(`  Debug - G1 affine is array: ${Array.isArray(sampleAffine)}, length: ${sampleAffine.length}`);
    
    // Convert pubkeys
    const pubkeysCircuit = [];
    for (let i = 0; i < NUM_VALIDATORS; i++) {
        const g1Point = bls.PointG1.fromHex(keypairs[i].publicKey);
        pubkeysCircuit.push(g1ToCircuit(g1Point));
    }
    console.log(`  Converted ${pubkeysCircuit.length} pubkeys`);
    
    // Convert aggregated signature (G2 point)
    const sigG2 = bls.PointG2.fromSignature(aggregatedSignature);
    const sigAffine = sigG2.toAffine();
    console.log(`  Debug - G2 affine is array: ${Array.isArray(sigAffine)}, x has c0: ${sigAffine[0]?.c0 !== undefined}`);
    
    const signatureCircuit = g2ToCircuit(sigG2);
    console.log(`  Converted aggregated signature`);
    
    // All validators participated
    const pubkeybits = Array(NUM_VALIDATORS).fill('1');
    
    // Create the input JSON
    const inputData = {
        signing_root: signingRoot,
        pubkeys: pubkeysCircuit,
        pubkeybits: pubkeybits,
        signature: signatureCircuit
    };
    
    // Write to file
    const outputDir = path.dirname(outputFile);
    if (outputDir && !fs.existsSync(outputDir)) {
        fs.mkdirSync(outputDir, { recursive: true });
    }
    fs.writeFileSync(outputFile, JSON.stringify(inputData, null, 2));
    
    console.log(`\n${'='.repeat(60)}`);
    console.log(`✓ Generated valid input for ${NUM_VALIDATORS} validators`);
    console.log(`✓ Output saved to: ${outputFile}`);
    console.log('='.repeat(60));
}

main().catch(err => {
    console.error('Fatal error:', err);
    process.exit(1);
});
