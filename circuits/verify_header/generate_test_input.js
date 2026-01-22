#!/usr/bin/env node
/**
 * Generate valid BLS signature input for N validators.
 * 
 * Usage:
 *   node generate_test_input.js <num_validators> <output_file>
 *   node generate_test_input.js 1 input/test_1_validator.json
 *   node generate_test_input.js 8 input/test_8_validators.json
 */

const fs = require('fs');
const path = require('path');

async function main() {
    const bls = await import('@noble/bls12-381');
    
    const NUM_VALIDATORS = parseInt(process.argv[2]) || 1;
    const outputFile = process.argv[3] || `input/test_${NUM_VALIDATORS}_validator${NUM_VALIDATORS > 1 ? 's' : ''}.json`;
    
    const N_BITS = 55n;
    const K_LIMBS = 7;
    
    console.log('='.repeat(60));
    console.log(`Generating valid BLS input for ${NUM_VALIDATORS} validator(s)`);
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
    
    // Helper: Get bigint value from Fp element
    function getFpValue(fp) {
        if (typeof fp === 'bigint') return fp;
        if (fp.value !== undefined) {
            return typeof fp.value === 'bigint' ? fp.value : BigInt(fp.value);
        }
        if (fp._value !== undefined) return fp._value;
        const str = fp.toString();
        if (str.startsWith('0x')) return BigInt(str);
        return BigInt(str);
    }
    
    // Helper: Convert G1 point to circuit format
    function g1ToCircuit(point) {
        const affine = point.toAffine();
        const x = getFpValue(affine[0]);
        const y = getFpValue(affine[1]);
        return [bigintToLimbs(x), bigintToLimbs(y)];
    }
    
    // Helper: Convert G2 point to circuit format
    function g2ToCircuit(point) {
        const affine = point.toAffine();
        const xFp2 = affine[0];
        const yFp2 = affine[1];
        
        let x0, x1, y0, y1;
        
        if (xFp2.c0 !== undefined) {
            x0 = getFpValue(xFp2.c0);
            x1 = getFpValue(xFp2.c1);
            y0 = getFpValue(yFp2.c0);
            y1 = getFpValue(yFp2.c1);
        } else if (Array.isArray(xFp2)) {
            x0 = getFpValue(xFp2[0]);
            x1 = getFpValue(xFp2[1]);
            y0 = getFpValue(yFp2[0]);
            y1 = getFpValue(yFp2[1]);
        } else {
            throw new Error(`Unknown Fp2 structure`);
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
    
    // Step 2: Generate key pairs
    console.log(`\n[2/5] Generating ${NUM_VALIDATORS} BLS key pair(s)...`);
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
    
    // Step 4: Aggregate signatures (even for 1 validator)
    console.log(`\n[4/5] Aggregating signatures...`);
    let aggregatedSignature;
    if (NUM_VALIDATORS === 1) {
        aggregatedSignature = signatures[0];
    } else {
        aggregatedSignature = bls.aggregateSignatures(signatures);
    }
    console.log(`  Aggregated signature: ${Buffer.from(aggregatedSignature).toString('hex').slice(0, 32)}...`);
    
    // Verify the aggregated signature
    const publicKeys = keypairs.map(kp => kp.publicKey);
    let aggregatedPubkey;
    if (NUM_VALIDATORS === 1) {
        aggregatedPubkey = publicKeys[0];
    } else {
        aggregatedPubkey = bls.aggregatePublicKeys(publicKeys);
    }
    const isValid = await bls.verify(aggregatedSignature, signingRootBytes, aggregatedPubkey);
    console.log(`  Signature valid: ${isValid}`);
    
    if (!isValid) {
        console.error('ERROR: Generated signature is not valid!');
        process.exit(1);
    }
    
    // Step 5: Convert to circuit format
    console.log(`\n[5/5] Converting to circuit format...`);
    
    // Convert pubkeys
    const pubkeysCircuit = [];
    for (let i = 0; i < NUM_VALIDATORS; i++) {
        const g1Point = bls.PointG1.fromHex(keypairs[i].publicKey);
        pubkeysCircuit.push(g1ToCircuit(g1Point));
    }
    console.log(`  Converted ${pubkeysCircuit.length} pubkey(s)`);
    
    // Convert aggregated signature (G2 point)
    const sigG2 = bls.PointG2.fromSignature(aggregatedSignature);
    const signatureCircuit = g2ToCircuit(sigG2);
    console.log(`  Converted signature`);
    
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
    if (outputDir && outputDir !== '.' && !fs.existsSync(outputDir)) {
        fs.mkdirSync(outputDir, { recursive: true });
    }
    fs.writeFileSync(outputFile, JSON.stringify(inputData, null, 2));
    
    console.log(`\n${'='.repeat(60)}`);
    console.log(`✓ Generated valid input for ${NUM_VALIDATORS} validator(s)`);
    console.log(`✓ Output saved to: ${outputFile}`);
    console.log('='.repeat(60));
    
    console.log('\n⚠️  NOTE: This uses @noble/bls12-381 hash_to_curve.');
    console.log('   If the circuit fails, it may be due to hash_to_curve differences.');
    console.log('   For guaranteed compatibility, use real Beacon Chain data.');
}

main().catch(err => {
    console.error('Fatal error:', err);
    process.exit(1);
});
