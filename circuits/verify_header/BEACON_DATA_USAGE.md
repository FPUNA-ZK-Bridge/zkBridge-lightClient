# Using Real Beacon Chain Data with verify_header Circuit

This guide explains how to generate circuit inputs from **real Beacon Chain data** instead of randomly generated test data.

## Why Use Real Beacon Chain Data?

- The signature is cryptographically valid (signed by real validators)
- Uses the correct `hash_to_curve` algorithm that matches the circuit
- Tests the full verification flow end-to-end

## Prerequisites

1. Install dependencies in `circuits/utils/circom-pairing`:
   ```bash
   cd circuits/utils/circom-pairing
   npm install
   ```

2. Obtain Beacon Chain sync committee data (JSON format)

## Beacon Data JSON Format

Your beacon data file should contain:

```json
{
  "blockRoot": "0x...",
  "blockHeader": {
    "slot": "195392",
    "sync_aggregate": {
      "sync_committee_signature": "0x..."
    }
  },
  "participation": {
    "bitsArray": [1, 1, 1, 0, 1, ...],  // 512 values
    "totalParticipants": 502
  },
  "syncCommittee": {
    "pubkeys": [
      "0x8d68345d8bcc61755ee62b91922072738e666a08b6426bcc23afa76f940a9c32565611c7fd138e711656304d61fb3bb8",
      // ... 512 pubkeys total
    ]
  }
}
```

## Usage

### Option 1: Using run_split.sh (Recommended)

```bash
# Generate input and run witness for 8 validators (mini mode)
./run_split.sh --mini --beacon input/your_beacon_data.json --witness-only

# Generate input and run witness for 1 validator (one mode)
./run_split.sh --one --beacon input/your_beacon_data.json --witness-only

# Full 512 validators (production)
./run_split.sh --beacon input/your_beacon_data.json --witness-only
```

Specify the network if not Holesky:
```bash
./run_split.sh --mini --beacon input/data.json --network mainnet --witness-only
```

### Option 2: Manual Generation

1. **Generate the circuit input:**
   ```bash
   cd circuits/utils/circom-pairing
   node ../verify_header/generate_from_beacon_data.js \
       ../verify_header/input/your_beacon_data.json \
       ../verify_header/input/beacon_output.json \
       8 \
       holesky
   ```

   Arguments:
   - `input_file` - Path to your beacon data JSON
   - `output_file` - Where to save the circuit input
   - `num_validators` - 1, 8, or 512
   - `network` - mainnet, goerli, sepolia, or holesky

2. **Run the circuit:**
   ```bash
   cd circuits/verify_header
   # Copy or link the generated input
   cp input/beacon_output.json input/your_key_8_validators.json
   ./run_split.sh --mini --witness-only
   ```

## Supported Networks

| Network  | Genesis Validators Root | Default Fork Version |
|----------|------------------------|---------------------|
| mainnet  | 0x4b363db94e...        | Depends on epoch    |
| goerli   | 0x043db0d9a8...        | Depends on epoch    |
| sepolia  | 0xd8ea171f3c...        | Depends on epoch    |
| holesky  | 0x9143aa7c61...        | Depends on epoch    |

The script automatically determines the correct fork version based on the slot number.

## How signing_root is Computed

The signing root for sync committee signatures follows the Ethereum specification:

```
1. domain = compute_domain(DOMAIN_SYNC_COMMITTEE, fork_version, genesis_validators_root)
2. signing_root = hash_tree_root(SigningData(object_root=block_root, domain=domain))
```

Where:
- `DOMAIN_SYNC_COMMITTEE = 0x07000000`
- `fork_version` depends on the network and epoch
- `genesis_validators_root` is specific to each network

## Troubleshooting

### "Signature verification: INVALID"

This usually means:
1. **Wrong network** - Try specifying a different network
2. **Wrong epoch/fork** - The fork version may be incorrect for that slot
3. **Truncated data** - Make sure all 512 pubkeys are included

### "Not enough participating validators"

The bitsArray must have at least `num_validators` bits set to 1.

### Circuit assertion fails

The circuit's `hash_to_curve` implementation must match what the validators used.
If using test-only mode, the final signature verification is skipped.

## Example: Getting Beacon Data

You can fetch sync committee data from a Beacon Chain node API:

```bash
# Get current sync committee
curl -s "http://localhost:5052/eth/v1/beacon/states/head/sync_committees" | jq

# Get specific block
curl -s "http://localhost:5052/eth/v2/beacon/blocks/195392" | jq
```

Or use public APIs like:
- https://beaconcha.in/api/v1/docs
- https://api.quicknode.com/
