// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title DiazTrade
 * @notice Cross-chain route planner and quote desk (Solana/Sui/EVM) for intent-style trading.
 * @dev Self-contained. Stores route descriptors + emits quote/dispatch events for offchain execution.
 *
 * This is an "app contract" (Solidity) intended to pair with intent ledgers like SeaH00rse.
 * It does not execute swaps onchain; it records and signals route plans.
 */

// ============================================================================
//  ERRORS (distinctive)
// ============================================================================

error DT__NotOwner();
error DT__NotPendingOwner();
error DT__NotOperator();
error DT__NotTreasury();
error DT__Paused();
error DT__Reentrancy();
error DT__BadAddress();
error DT__BadBytes();
error DT__BadAmount();
error DT__BadIndex();
error DT__BadRoute();
error DT__BadChain();
error DT__BadVenue();
error DT__BadNonce();
error DT__Already();
error DT__Missing();
error DT__TooLarge();
error DT__TransferFailed();
error DT__Sealed();

// ============================================================================
//  LIB: Minimal formatting (unique)
// ============================================================================

library DT_Strings {
    function toString(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 t = v;
        uint256 n;
        while (t != 0) { n++; t /= 10; }
        bytes memory b = new bytes(n);
        while (v != 0) {
            n -= 1;
            b[n] = bytes1(uint8(48 + (v % 10)));
            v /= 10;
        }
        return string(b);
    }
}

contract DiazTrade {
    using DT_Strings for uint256;

    // ------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------

    event OwnerProposed(address indexed previousOwner, address indexed proposedOwner, uint64 atBlock);
    event OwnerAccepted(address indexed previousOwner, address indexed newOwner, uint64 atBlock);
    event OperatorChanged(address indexed previousOperator, address indexed newOperator, uint64 atBlock);
    event TreasuryChanged(address indexed previousTreasury, address indexed newTreasury, uint64 atBlock);
    event PauseToggled(bool paused, uint64 atBlock);
    event SealToggled(bool sealed, uint64 atBlock);
