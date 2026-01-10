// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.14;

import "./VerifierPart1.sol";
import "./VerifierPart2.sol";
import "./VerifierPart3.sol";

/**
 * @title BlsSignatureSplitVerifier
 * @notice Wrapper contract that verifies 3 split Groth16 proofs and chains them together
 * @dev Uses keccak256 for efficient comparison of public signal segments (~16x gas savings)
 * 
 * Public Signals Layout:
 * Part1 (98 elements): Hm[0:28], pubkey[28:42], signature[42:70], hash[70:98]
 * Part2 (154 elements): miller_out[0:84], pubkey[84:98], signature[98:126], Hm[126:154]
 * Part3 (84 elements): miller_out[0:84]
 */
contract BlsSignatureSplitVerifier {
    VerifierPart1 public immutable verifierPart1;
    VerifierPart2 public immutable verifierPart2;
    VerifierPart3 public immutable verifierPart3;

    constructor(
        address _verifierPart1,
        address _verifierPart2,
        address _verifierPart3
    ) {
        verifierPart1 = VerifierPart1(_verifierPart1);
        verifierPart2 = VerifierPart2(_verifierPart2);
        verifierPart3 = VerifierPart3(_verifierPart3);
    }

    /**
     * @notice Verifies all 3 proofs and chains them together
     * @param a1 Part1 proof A (G1 point)
     * @param b1 Part1 proof B (G2 point)
     * @param c1 Part1 proof C (G1 point)
     * @param signals1 Part1 public signals (98 elements)
     * @param a2 Part2 proof A (G1 point)
     * @param b2 Part2 proof B (G2 point)
     * @param c2 Part2 proof C (G1 point)
     * @param signals2 Part2 public signals (154 elements)
     * @param a3 Part3 proof A (G1 point)
     * @param b3 Part3 proof B (G2 point)
     * @param c3 Part3 proof C (G1 point)
     * @param signals3 Part3 public signals (84 elements)
     * @return true if all proofs are valid and properly chained
     */
    function verifyAll(
        uint[2] memory a1,
        uint[2][2] memory b1,
        uint[2] memory c1,
        uint[] memory signals1,
        uint[2] memory a2,
        uint[2][2] memory b2,
        uint[2] memory c2,
        uint[] memory signals2,
        uint[2] memory a3,
        uint[2][2] memory b3,
        uint[2] memory c3,
        uint[] memory signals3
    ) external view returns (bool) {
        require(signals1.length == 98, "BlsSignatureSplitVerifier: Part1 signals length mismatch");
        require(signals2.length == 154, "BlsSignatureSplitVerifier: Part2 signals length mismatch");
        require(signals3.length == 84, "BlsSignatureSplitVerifier: Part3 signals length mismatch");

        // Verify all 3 Groth16 proofs
        require(
            verifierPart1.verifyProof(a1, b1, c1, signals1),
            "BlsSignatureSplitVerifier: Part1 proof verification failed"
        );
        require(
            verifierPart2.verifyProof(a2, b2, c2, signals2),
            "BlsSignatureSplitVerifier: Part2 proof verification failed"
        );
        require(
            verifierPart3.verifyProof(a3, b3, c3, signals3),
            "BlsSignatureSplitVerifier: Part3 proof verification failed"
        );

        // Chain Hm: Part1[0:28] == Part2[126:154]
        require(
            keccak256HashSlice(signals1, 0, 28) ==
            keccak256HashSlice(signals2, 126, 28),
            "BlsSignatureSplitVerifier: Hm chain mismatch"
        );

        // Chain miller_out: Part2[0:84] == Part3[0:84]
        require(
            keccak256HashSlice(signals2, 0, 84) ==
            keccak256HashSlice(signals3, 0, 84),
            "BlsSignatureSplitVerifier: miller_out chain mismatch"
        );

        // Consistency check: pubkey+signature Part1[28:70] == Part2[84:126]
        require(
            keccak256HashSlice(signals1, 28, 42) ==
            keccak256HashSlice(signals2, 84, 42),
            "BlsSignatureSplitVerifier: pubkey/signature mismatch"
        );

        return true;
    }

    /**
     * @notice Efficiently hash a slice of an array using keccak256
     * @param arr The array to slice
     * @param start Starting index
     * @param length Number of elements to hash
     * @return keccak256 hash of the encoded slice
     */
    function keccak256HashSlice(
        uint[] memory arr,
        uint start,
        uint length
    ) internal pure returns (bytes32) {
        require(start + length <= arr.length, "BlsSignatureSplitVerifier: slice out of bounds");
        bytes memory encoded = new bytes(length * 32);
        assembly {
            let src := add(add(arr, 0x20), mul(start, 0x20))
            let dest := add(encoded, 0x20)
            for { let i := 0 } lt(i, length) { i := add(i, 1) } {
                mstore(add(dest, mul(i, 0x20)), mload(add(src, mul(i, 0x20))))
            }
        }
        return keccak256(encoded);
    }
}

