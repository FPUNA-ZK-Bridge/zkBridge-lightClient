#!/usr/bin/env node
/**
 * Generate valid BLS signature input using a provided private key.
 * 
 * The private key is used as a BLS private key to derive the public key
 * and sign a message. This creates a cryptographically valid input.
 * 
 * Usage:
 *   node generate_from_privatekey.js <private_key_hex> [output_file] [num_validators]
 */

const fs = require('fs');
const path = require('path');

async function main() {
    const bls = await import('@noble/bls12-381');
    
    const N_BITS = 55n;
    const K_LIMBS = 7;
    
    // Parse arguments
    const privateKeyHex = process.argv[2] || '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';
    const outputFile = process.argv[3] || 'input/real_key_input.json';
    const NUM_VALIDATORS = parseInt(process.argv[4] || '1', 10);

    console.log('='.repeat(60));
    console.log('Generating BLS input from provided private key');
    console.log('='.repeat(60));
    
    // Clean the private key (remove 0x prefix if present)
    const cleanPrivateKey = privateKeyHex.replace(/^0x/, '');
    console.log(`\nPrivate key: 0x${cleanPrivateKey.slice(0, 8)}...${cleanPrivateKey.slice(-8)}`);
    console.log(`Validators: ${NUM_VALIDATORS}`);
    
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
        return [
            bigintToLimbs(getFpValue(affine[0])),
            bigintToLimbs(getFpValue(affine[1]))
        ];
    }
    
    // Helper: Convert G2 point to circuit format
    function g2ToCircuit(point) {
        const affine = point.toAffine();
        return [
            [bigintToLimbs(getFpValue(affine[0].c0)), bigintToLimbs(getFpValue(affine[0].c1))],
            [bigintToLimbs(getFpValue(affine[1].c0)), bigintToLimbs(getFpValue(affine[1].c1))]
        ];
    }

    // Step 1: Generate signing_root (32 random bytes)
    console.log(`\n[1/5] Generating signing_root...`);
    const signingRootBytes = bls.utils.randomBytes(32);
    const signingRoot = Array.from(signingRootBytes).map(String);
    console.log(`  signing_root (hex): ${bls.utils.bytesToHex(signingRootBytes)}`);

    // Step 2: Generate keypairs - first one from provided key, rest random
    console.log(`\n[2/5] Generating ${NUM_VALIDATORS} BLS key pairs...`);
    const keypairs = [];
    
    for (let i = 0; i < NUM_VALIDATORS; i++) {
        let privateKey;
        if (i === 0) {
            // Use provided private key for first validator
            privateKey = bls.utils.hexToBytes(cleanPrivateKey);
            console.log(`  Validator 0: Using YOUR private key`);
        } else {
            // Generate random keys for others
            privateKey = bls.utils.randomPrivateKey();
            console.log(`  Validator ${i}: Random key`);
        }
        
        const publicKey = bls.getPublicKey(privateKey);
        keypairs.push({ privateKey, publicKey });
        console.log(`    pubkey: ${bls.utils.bytesToHex(publicKey).slice(0, 20)}...`);
    }

    // Step 3: Each validator signs the message
    console.log(`\n[3/5] Signing message with each validator...`);
    const signatures = await Promise.all(
        keypairs.map(async (kp, i) => {
            const sig = await bls.sign(signingRootBytes, kp.privateKey);
            console.log(`  Validator ${i} signed`);
            return sig;
        })
    );

    // Step 4: Aggregate signatures and public keys
    console.log(`\n[4/5] Aggregating signatures...`);
    const aggregatedSignature = bls.aggregateSignatures(signatures);
    const aggregatedPublicKeys = bls.aggregatePublicKeys(keypairs.map(kp => kp.publicKey));
    
    const isSignatureValid = await bls.verify(aggregatedSignature, signingRootBytes, aggregatedPublicKeys);
    console.log(`  Aggregated signature valid: ${isSignatureValid}`);

    if (!isSignatureValid) {
        console.error("ERROR: Generated aggregated signature is not valid!");
        process.exit(1);
    }
    
    // Step 5: Convert to circuit format
    console.log(`\n[5/5] Converting to circuit format...`);
    
    const pubkeysCircuit = [];
    for (let i = 0; i < NUM_VALIDATORS; i++) {
        const g1Point = bls.PointG1.fromHex(keypairs[i].publicKey);
        pubkeysCircuit.push(g1ToCircuit(g1Point));
    }
    console.log(`  Converted ${pubkeysCircuit.length} pubkeys`);
    
    const sigG2 = bls.PointG2.fromSignature(aggregatedSignature);
    const signatureCircuit = g2ToCircuit(sigG2);
    console.log(`  Converted aggregated signature`);
    
    const pubkeybits = Array(NUM_VALIDATORS).fill('1');
    
    const inputData = {
        signing_root: signingRoot,
        pubkeys: pubkeysCircuit,
        pubkeybits: pubkeybits,
        signature: signatureCircuit
    };
    
    fs.mkdirSync(path.dirname(outputFile), { recursive: true });
    fs.writeFileSync(outputFile, JSON.stringify(inputData, null, 2));
    
    console.log(`\n${'='.repeat(60)}`);
    console.log(`✓ Generated valid input using YOUR private key`);
    console.log(`✓ Validator 0 pubkey derived from: 0x${cleanPrivateKey.slice(0, 8)}...`);
    console.log(`✓ Output saved to: ${outputFile}`);
    console.log(`${'='.repeat(60)}`);
    
    // Show the derived public key for reference
    console.log(`\n📍 Your BLS Public Key (validator 0):`);
    console.log(`   ${bls.utils.bytesToHex(keypairs[0].publicKey)}`);
}

main().catch(error => {
    console.error('Fatal error:', error);
    process.exit(1);
});
