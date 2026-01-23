#!/usr/bin/env node
/**
 * Generate circuit input from REAL Beacon Chain data.
 * 
 * This script takes sync committee data directly from the Beacon Chain
 * and converts it to the format expected by the verify_header circuit.
 * 
 * Usage:
 *   node generate_from_beacon_data.js <beacon_data.json> [output_file] [num_validators] [network]
 * 
 * Arguments:
 *   beacon_data.json  - JSON file with Beacon Chain sync committee data
 *   output_file       - Output path (default: input/beacon_input.json)
 *   num_validators    - Number of validators to use: 1, 8, or 512 (default: 512)
 *   network           - Network name: mainnet, goerli, sepolia, holesky (default: holesky)
 * 
 * The beacon_data.json should contain:
 *   - blockRoot: hex string of the block root
 *   - blockHeader.sync_aggregate.sync_committee_signature: hex string of aggregated signature
 *   - syncCommittee.pubkeys: array of 512 pubkey hex strings
 *   - participation.bitsArray: array of 512 bits (0 or 1)
 */

const fs = require('fs');
const path = require('path');

// Network configurations
const NETWORKS = {
    mainnet: {
        genesisValidatorsRoot: '0x4b363db94e286120d76eb905340fdd4e54bfe9f06bf33ff6cf5ad27f511bfe95',
        // Fork versions for different epochs
        forkVersions: {
            phase0: '0x00000000',
            altair: '0x01000000',      // epoch 74240
            bellatrix: '0x02000000',   // epoch 144896
            capella: '0x03000000',     // epoch 194048
            deneb: '0x04000000',       // epoch 269568
        },
        altairEpoch: 74240,
        bellatrixEpoch: 144896,
        capellaEpoch: 194048,
        denebEpoch: 269568,
    },
    goerli: {
        genesisValidatorsRoot: '0x043db0d9a83813551ee2f33450d23797757d430911a9320530ad8a0eabc43efb',
        forkVersions: {
            phase0: '0x00001020',
            altair: '0x01001020',
            bellatrix: '0x02001020',
            capella: '0x03001020',
            deneb: '0x04001020',
        },
        altairEpoch: 36660,
        bellatrixEpoch: 112260,
        capellaEpoch: 162304,
        denebEpoch: 231680,
    },
    sepolia: {
        genesisValidatorsRoot: '0xd8ea171f3c94aea21ebc42a1ed61052acf3f9209c00e4efbaaddac09ed9b8078',
        forkVersions: {
            phase0: '0x90000069',
            altair: '0x90000070',
            bellatrix: '0x90000071',
            capella: '0x90000072',
            deneb: '0x90000073',
        },
        altairEpoch: 50,
        bellatrixEpoch: 100,
        capellaEpoch: 56832,
        denebEpoch: 132608,
    },
    holesky: {
        genesisValidatorsRoot: '0x9143aa7c615a7f7115e2b6aac319c03529df8242ae705fba9df39b79c59fa8b1',
        forkVersions: {
            phase0: '0x01017000',
            altair: '0x02017000',
            bellatrix: '0x03017000',
            capella: '0x04017000',
            deneb: '0x05017000',
        },
        altairEpoch: 0,
        bellatrixEpoch: 0,
        capellaEpoch: 256,
        denebEpoch: 29696,
    }
};

// DOMAIN_SYNC_COMMITTEE as per Ethereum spec
const DOMAIN_SYNC_COMMITTEE = [0x07, 0x00, 0x00, 0x00];

// Constants for circuit format
const N_BITS = 55n;
const K_LIMBS = 7;

/**
 * Convert hex string to Uint8Array
 */
function hexToBytes(hex) {
    const cleanHex = hex.replace(/^0x/, '');
    const bytes = new Uint8Array(cleanHex.length / 2);
    for (let i = 0; i < bytes.length; i++) {
        bytes[i] = parseInt(cleanHex.substr(i * 2, 2), 16);
    }
    return bytes;
}

/**
 * Convert Uint8Array to hex string
 */
function bytesToHex(bytes) {
    return '0x' + Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
}

/**
 * Compute the domain for sync committee using SSZ
 */
function computeDomain(ssz, domainType, forkVersion, genesisValidatorsRoot) {
    // Use SSZ to compute fork_data_root properly
    const ForkData = ssz.phase0.ForkData;
    let fork_data = ForkData.defaultValue();
    fork_data.currentVersion = forkVersion;
    fork_data.genesisValidatorsRoot = genesisValidatorsRoot;
    const fork_data_root = ForkData.hashTreeRoot(fork_data);
    
    // Build domain: domain_type (4 bytes) || fork_data_root[:28] (28 bytes)
    const domain = new Uint8Array(32);
    for (let i = 0; i < 4; i++) {
        domain[i] = domainType[i];
    }
    for (let i = 0; i < 28; i++) {
        domain[i + 4] = fork_data_root[i];
    }
    return domain;
}

/**
 * Compute signing_root from block_root and domain using SSZ
 */
function computeSigningRoot(ssz, objectRoot, domain) {
    // Use SSZ to compute signing_root properly
    const SigningData = ssz.phase0.SigningData;
    let signing_data = SigningData.defaultValue();
    signing_data.objectRoot = objectRoot;
    signing_data.domain = domain;
    return SigningData.hashTreeRoot(signing_data);
}

/**
 * Get fork version for a given slot and network
 */
function getForkVersion(slot, network) {
    const epoch = Math.floor(slot / 32);
    const config = NETWORKS[network];
    
    if (epoch >= config.denebEpoch) {
        return hexToBytes(config.forkVersions.deneb);
    } else if (epoch >= config.capellaEpoch) {
        return hexToBytes(config.forkVersions.capella);
    } else if (epoch >= config.bellatrixEpoch) {
        return hexToBytes(config.forkVersions.bellatrix);
    } else if (epoch >= config.altairEpoch) {
        return hexToBytes(config.forkVersions.altair);
    } else {
        return hexToBytes(config.forkVersions.phase0);
    }
}

/**
 * Convert bigint to array of k limbs of n bits each
 */
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

/**
 * Convert bytes to bigint (big endian)
 */
function bytesToBigInt(bytes) {
    let result = 0n;
    for (const byte of bytes) {
        result = (result << 8n) + BigInt(byte);
    }
    return result;
}

async function main() {
    // Dynamic import for ESM modules
    const bls = await import('@noble/bls12-381');
    
    // Import SSZ from lodestar-types for proper hash_tree_root calculation
    // We need to load it from the circom-pairing node_modules
    let ssz;
    try {
        // Find circom-pairing directory (where node_modules is)
        const scriptDir = __dirname;
        const circomPairingPath = path.resolve(scriptDir, '../utils/circom-pairing');
        const lodestarTypesPath = path.join(circomPairingPath, 'node_modules/@chainsafe/lodestar-types');
        
        // Load module directly from path
        const lodestarTypes = require(lodestarTypesPath);
        ssz = lodestarTypes.ssz;
        if (!ssz) {
            throw new Error('ssz not found in lodestar-types');
        }
    } catch (e) {
        console.error('ERROR: Could not load @chainsafe/lodestar-types');
        console.error('Error:', e.message);
        console.error('Make sure @chainsafe/lodestar-types is installed in circuits/utils/circom-pairing');
        process.exit(1);
    }
    
    // Parse command line arguments
    const beaconDataFile = process.argv[2];
    const outputFile = process.argv[3] || 'input/beacon_input.json';
    const numValidators = parseInt(process.argv[4] || '512', 10);
    const network = process.argv[5] || 'holesky';
    
    if (!beaconDataFile) {
        console.error('Usage: node generate_from_beacon_data.js <beacon_data.json> [output_file] [num_validators] [network]');
        console.error('');
        console.error('Arguments:');
        console.error('  beacon_data.json  - JSON file with Beacon Chain sync committee data');
        console.error('  output_file       - Output path (default: input/beacon_input.json)');
        console.error('  num_validators    - Number of validators: 1, 8, or 512 (default: 512)');
        console.error('  network           - Network: mainnet, goerli, sepolia, holesky (default: holesky)');
        process.exit(1);
    }
    
    if (!NETWORKS[network]) {
        console.error(`Unknown network: ${network}`);
        console.error(`Available networks: ${Object.keys(NETWORKS).join(', ')}`);
        process.exit(1);
    }
    
    console.log('='.repeat(70));
    console.log('Generating circuit input from REAL Beacon Chain data');
    console.log('='.repeat(70));
    console.log(`Network: ${network}`);
    console.log(`Validators: ${numValidators}`);
    console.log(`Input file: ${beaconDataFile}`);
    console.log(`Output file: ${outputFile}`);
    
    // Load beacon data
    console.log('\n[1/6] Loading Beacon Chain data...');
    const beaconData = JSON.parse(fs.readFileSync(beaconDataFile, 'utf8'));
    
    // Extract data
    const slot = parseInt(beaconData.blockHeader.slot);
    const signatureHex = beaconData.blockHeader.sync_aggregate.sync_committee_signature;
    const pubkeysHex = beaconData.syncCommittee.pubkeys;
    const bitsArray = beaconData.participation.bitsArray;
    
    console.log(`  Slot: ${slot} (epoch ${Math.floor(slot / 32)})`);
    console.log(`  Total pubkeys: ${pubkeysHex.length}`);
    console.log(`  Participation: ${beaconData.participation.participation}%`);
    
    // Calculate beacon_block_root from header using SSZ
    console.log('\n[2/6] Computing beacon_block_root and signing_root...');
    
    // Try to compute beacon_block_root from header if we have all fields
    let beaconBlockRoot;
    if (beaconData.blockRoot) {
        // Use provided blockRoot (might be correct, or might be block root not header root)
        beaconBlockRoot = hexToBytes(beaconData.blockRoot);
        console.log(`  Using provided blockRoot: ${beaconData.blockRoot}`);
        console.log(`  (If verification fails, we may need to compute from header)`);
    } else {
        // Calculate from header using SSZ
        const BeaconBlockHeader = ssz.phase0.BeaconBlockHeader;
        let header = BeaconBlockHeader.defaultValue();
        header.slot = slot;
        header.proposerIndex = parseInt(beaconData.blockHeader.proposer_index);
        header.parentRoot = hexToBytes(beaconData.blockHeader.parent_root);
        header.stateRoot = hexToBytes(beaconData.blockHeader.state_root);
        header.bodyRoot = hexToBytes(beaconData.blockHeader.body_root || '0x0000000000000000000000000000000000000000000000000000000000000000');
        beaconBlockRoot = BeaconBlockHeader.hashTreeRoot(header);
        console.log(`  Computed beacon_block_root from header: ${bytesToHex(beaconBlockRoot)}`);
    }
    
    const networkConfig = NETWORKS[network];
    const genesisValidatorsRoot = hexToBytes(networkConfig.genesisValidatorsRoot);
    const forkVersion = getForkVersion(slot, network);
    
    console.log(`  Genesis validators root: ${networkConfig.genesisValidatorsRoot}`);
    console.log(`  Fork version: ${bytesToHex(forkVersion)}`);
    
    const domain = computeDomain(ssz, DOMAIN_SYNC_COMMITTEE, forkVersion, genesisValidatorsRoot);
    const signingRoot = computeSigningRoot(ssz, beaconBlockRoot, domain);
    
    console.log(`  Domain: ${bytesToHex(domain)}`);
    console.log(`  Signing root: ${bytesToHex(signingRoot)}`);
    
    // Select validators based on participation bits
    console.log('\n[3/6] Selecting validators...');
    
    let selectedIndices;
    
    if (numValidators === 512) {
        // For full 512-validator mode, use ALL pubkeys from sync committee
        // The bitsArray will determine which ones are included in aggregation
        selectedIndices = Array.from({ length: 512 }, (_, i) => i);
        const participatingCount = bitsArray.filter(b => b === 1).length;
        console.log(`  Using all 512 sync committee pubkeys`);
        console.log(`  ${participatingCount} validators participated (will be aggregated)`);
    } else {
        // For 1 or 8 validators, select only participating ones
        const participatingIndices = [];
        for (let i = 0; i < bitsArray.length; i++) {
            if (bitsArray[i] === 1) {
                participatingIndices.push(i);
            }
        }
        
        if (participatingIndices.length < numValidators) {
            console.error(`ERROR: Not enough participating validators. Found ${participatingIndices.length}, need ${numValidators}`);
            process.exit(1);
        }
        
        // Take first N participating validators
        selectedIndices = participatingIndices.slice(0, numValidators);
        console.log(`  Selected ${selectedIndices.length} participating validators`);
        console.log(`  Indices: ${selectedIndices.slice(0, 5).join(', ')}${selectedIndices.length > 5 ? '...' : ''}`);
    }
    
    // For the circuit, we need to set pubkeybits for selected validators to 1
    // and non-selected to 0, but we only include the pubkeys for num_validators
    // In the full 512-validator circuit, we'd use all pubkeys with their original bits
    
    // Convert pubkeys to circuit format
    console.log('\n[4/6] Converting pubkeys to circuit format...');
    const pubkeysCircuit = [];
    
    // For 1 validator mode, use pubkey from known private key (Hardhat #0)
    // This matches the individual signature we'll generate
    let useTestKeypair = false;
    if (numValidators === 1) {
        useTestKeypair = true;
        console.log(`  Mode: 1 validator - using pubkey from Hardhat account #0`);
    }
    
    for (let i = 0; i < numValidators; i++) {
        let g1Point;
        
        if (useTestKeypair && i === 0) {
            // Use Hardhat account #0 private key to derive pubkey
            const testPrivateKey = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';
            const privateKeyBytes = hexToBytes(testPrivateKey);
            const testPubkey = bls.getPublicKey(privateKeyBytes);
            g1Point = bls.PointG1.fromHex(testPubkey);
            console.log(`  Pubkey 0 (Hardhat #0): ${bls.utils.bytesToHex(testPubkey).slice(0, 20)}...`);
        } else {
            // Use pubkey from Beacon Chain
            const idx = numValidators === 512 ? i : selectedIndices[i];
            const pubkeyHex = pubkeysHex[idx];
            const pubkeyBytes = hexToBytes(pubkeyHex);
            g1Point = bls.PointG1.fromHex(pubkeyBytes);
            if (i < 3) {
                console.log(`  Pubkey ${i}: ${pubkeyHex.slice(0, 20)}...`);
            }
        }
        
        try {
            const affine = g1Point.toAffine();
            
            // Get x and y coordinates
            const x = affine[0].value !== undefined ? affine[0].value : BigInt(affine[0].toString());
            const y = affine[1].value !== undefined ? affine[1].value : BigInt(affine[1].toString());
            
            pubkeysCircuit.push([
                bigintToLimbs(x),
                bigintToLimbs(y)
            ]);
        } catch (err) {
            console.error(`  ERROR parsing pubkey ${i}: ${err.message}`);
            process.exit(1);
        }
    }
    console.log(`  Converted ${pubkeysCircuit.length} pubkeys`);
    
    // Convert signature to circuit format
    console.log('\n[5/6] Converting signature to circuit format...');
    
    let signatureCircuit;
    let sigBytes;
    
    if (numValidators === 1) {
        // For 1 validator mode: Generate individual signature using known private key
        // This allows testing with real signing_root from Beacon Chain
        console.log(`  Mode: 1 validator - generating individual signature`);
        console.log(`  Using Hardhat account #0 private key to sign the real signing_root`);
        
        // Use Hardhat account #0 private key (same as before)
        const testPrivateKey = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';
        const privateKeyBytes = hexToBytes(testPrivateKey);
        
        // Sign the REAL signing_root from Beacon Chain
        const individualSignature = await bls.sign(signingRoot, privateKeyBytes);
        sigBytes = individualSignature;
        
        // Verify the signature is valid
        const testPubkey = bls.getPublicKey(privateKeyBytes);
        const isValid = await bls.verify(individualSignature, signingRoot, testPubkey);
        console.log(`  Individual signature generated: ${isValid ? '✓ VALID' : '✗ INVALID'}`);
        
        if (!isValid) {
            console.error('ERROR: Generated individual signature is not valid!');
            process.exit(1);
        }
        
        // Convert to circuit format
        const sigG2 = bls.PointG2.fromSignature(individualSignature);
        const affine = sigG2.toAffine();
        
        const x_c0 = affine[0].c0.value !== undefined ? affine[0].c0.value : BigInt(affine[0].c0.toString());
        const x_c1 = affine[0].c1.value !== undefined ? affine[0].c1.value : BigInt(affine[0].c1.toString());
        const y_c0 = affine[1].c0.value !== undefined ? affine[1].c0.value : BigInt(affine[1].c0.toString());
        const y_c1 = affine[1].c1.value !== undefined ? affine[1].c1.value : BigInt(affine[1].c1.toString());
        
        signatureCircuit = [
            [bigintToLimbs(x_c0), bigintToLimbs(x_c1)],
            [bigintToLimbs(y_c0), bigintToLimbs(y_c1)]
        ];
        
        console.log(`  ✓ Individual signature converted to circuit format`);
        console.log(`  NOTE: Using individual signature (not aggregated) for 1-validator testing`);
    } else {
        // For 8 or 512 validators: Use the aggregated signature from Beacon Chain
        sigBytes = hexToBytes(signatureHex);
        console.log(`  Mode: ${numValidators} validators - using aggregated signature from Beacon Chain`);
        console.log(`  Signature hex: ${signatureHex.slice(0, 40)}...`);
        
        const sigG2 = bls.PointG2.fromSignature(sigBytes);
        const affine = sigG2.toAffine();
        
        // G2 point has x and y, each in Fp2 (c0, c1)
        const x_c0 = affine[0].c0.value !== undefined ? affine[0].c0.value : BigInt(affine[0].c0.toString());
        const x_c1 = affine[0].c1.value !== undefined ? affine[0].c1.value : BigInt(affine[0].c1.toString());
        const y_c0 = affine[1].c0.value !== undefined ? affine[1].c0.value : BigInt(affine[1].c0.toString());
        const y_c1 = affine[1].c1.value !== undefined ? affine[1].c1.value : BigInt(affine[1].c1.toString());
        
        signatureCircuit = [
            [bigintToLimbs(x_c0), bigintToLimbs(x_c1)],
            [bigintToLimbs(y_c0), bigintToLimbs(y_c1)]
        ];
        
        console.log(`  ✓ Aggregated signature converted successfully`);
    }
    
    try {
        
        // Set pubkeybits
        let pubkeybits;
        if (numValidators === 512) {
            // Use original bits
            pubkeybits = bitsArray.map(b => String(b));
        } else {
            // All selected validators are participating
            pubkeybits = Array(numValidators).fill('1');
        }
        
        // Build the input object
        console.log('\n[6/6] Building circuit input...');
        const inputData = {
            signing_root: Array.from(signingRoot).map(String),
            pubkeys: pubkeysCircuit,
            pubkeybits: pubkeybits,
            signature: signatureCircuit
        };
        
        // Save to file
        const outputDir = path.dirname(outputFile);
        if (outputDir && !fs.existsSync(outputDir)) {
            fs.mkdirSync(outputDir, { recursive: true });
        }
        
        fs.writeFileSync(outputFile, JSON.stringify(inputData, null, 2));
        
        console.log('\n' + '='.repeat(70));
        console.log('SUCCESS: Circuit input generated from real Beacon Chain data');
        console.log('='.repeat(70));
        console.log(`Output file: ${outputFile}`);
        console.log(`Validators: ${numValidators}`);
        console.log(`Network: ${network}`);
        console.log(`Signing root: ${bytesToHex(signingRoot)}`);
        console.log('');
        console.log('IMPORTANT: This uses REAL data from the Beacon Chain.');
        console.log('The signature should be valid if the signing_root calculation is correct.');
        console.log('');
        
        // Always verify signature against ALL participating validators to check signing_root
        // Use the ORIGINAL aggregated signature from Beacon Chain (not the individual one)
        console.log('Verifying signing_root calculation...');
        try {
            // Get the original aggregated signature from Beacon Chain
            const originalSigBytes = hexToBytes(signatureHex);
            
            // Aggregate only participating pubkeys (all 502 that signed)
            const participatingPubkeys = [];
            for (let i = 0; i < 512; i++) {
                if (bitsArray[i] === 1) {
                    participatingPubkeys.push(hexToBytes(pubkeysHex[i]));
                }
            }
            
            const aggregatedPubkey = bls.aggregatePublicKeys(participatingPubkeys);
            const isValid = await bls.verify(originalSigBytes, signingRoot, aggregatedPubkey);
            console.log(`Signature verification (all ${participatingPubkeys.length} validators): ${isValid ? '✓ VALID' : '✗ INVALID'}`);
            
            if (!isValid) {
                console.log('\n⚠️  WARNING: Signature verification failed!');
                console.log('This means the signing_root calculation is incorrect.');
                console.log('Possible causes:');
                console.log('  1. Wrong network (try: mainnet, goerli, sepolia, holesky)');
                console.log('  2. Wrong fork version for this slot/epoch');
                console.log('  3. Different signing_root calculation method');
                console.log('');
                console.log('The circuit will FAIL with "Assert Failed" if signing_root is wrong.');
            } else {
                console.log('\n✓ Signing root is CORRECT!');
                if (numValidators < 512) {
                    console.log(`\n⚠️  NOTE: You're using only ${numValidators} validator(s), but the signature`);
                    console.log(`   is aggregated from ${participatingPubkeys.length} validators.`);
                    console.log(`   The aggregated signature is NOT valid for a single pubkey.`);
                    console.log(`   To test with ${numValidators} validator(s), you would need:`);
                    console.log(`   - Individual signatures (not available from Beacon Chain)`);
                    console.log(`   - OR use all ${participatingPubkeys.length} participating validators`);
                    console.log(`   - OR use the full 512 validators with original bitsArray`);
                }
            }
        } catch (verifyErr) {
            console.log(`Verification error: ${verifyErr.message}`);
        }
        
    } catch (sigErr) {
        console.error(`ERROR parsing signature: ${sigErr.message}`);
        process.exit(1);
    }
}

main().catch(err => {
    console.error('Fatal error:', err);
    process.exit(1);
});
