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

    event VenueCataloged(bytes32 indexed venueId, uint32 indexed chainId, bytes32 indexed venueTag, uint64 atBlock);
    event VenueEnabled(bytes32 indexed venueId, bool enabled, uint64 atBlock);

    event RouteAuthored(
        uint256 indexed routeId,
        bytes32 indexed routeKey,
        uint32 srcChain,
        uint32 dstChain,
        bytes32 srcAsset,
        bytes32 dstAsset,
        uint16 maxSlippageBps,
        uint64 atBlock
    );

    event RouteRetired(uint256 indexed routeId, uint64 atBlock);

    event QuoteStamped(
        bytes32 indexed quoteId,
        bytes32 indexed routeKey,
        uint256 indexed routeId,
        uint128 srcAmount,
        uint128 expectedDstAmount,
        uint64 validUntilBlock,
        bytes32 quoteDigest
    );

    event DispatchSignaled(
        bytes32 indexed dispatchId,
        bytes32 indexed quoteId,
        address indexed requester,
        bytes32 intentHash,
        uint64 atBlock
    );

    event TreasuryWithdrawn(address indexed to, uint256 amountWei, uint64 atBlock);

    // ------------------------------------------------------------------------
    // Constants (unique)
    // ------------------------------------------------------------------------

    uint256 public constant DT_REVISION = 2;
    uint16 public constant DT_BPS = 10_000;
    uint16 public constant DT_MAX_SLIPPAGE_BPS = 1_500;
    uint256 public constant DT_MAX_ROUTES = 55_555;
    uint256 public constant DT_MAX_VENUES = 8_192;
    uint256 public constant DT_MAX_BATCH = 80;
    uint256 public constant DT_WITHDRAW_CAP_WEI = 5 ether;
    bytes32 public constant DT_DOMAIN = keccak256("DiazTrade.Domain.RouteDesk.v2");
    bytes32 public constant DT_SALT = 0x7734cf7f23fc4c289e05d267850efb932bd05b68a8294f669c90fddcec114541;

    uint32 public constant DT_CHAIN_EVM = 1;
    uint32 public constant DT_CHAIN_SOLANA = 501;
    uint32 public constant DT_CHAIN_SUI = 784;

    // ------------------------------------------------------------------------
    // Roles (immutable)
    // ------------------------------------------------------------------------

    address public immutable bootOwner;
    address public immutable bootOperator;
    address public immutable bootTreasury;
    uint256 public immutable genesisBlock;

    // ------------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------------

    address public owner;
    address public pendingOwner;
    address public operator;
    address public treasury;

    bool public paused;
    bool public sealed;
    uint256 private _lock;

    uint256 private _nextVenueIndex;
    uint256 private _nextRouteId;
    uint256 private _totalWithdrawnWei;

    struct Venue {
        uint32 chainId;
        bytes32 venueTag;
        bool enabled;
        uint64 catalogedAt;
        bool exists;
    }

    struct Route {
        bytes32 routeKey;
        uint32 srcChain;
        uint32 dstChain;
        bytes32 srcAsset;
        bytes32 dstAsset;
        uint16 maxSlippageBps;
        bytes32[] venuePath;
        bool retired;
        uint64 authoredAt;
    }

    mapping(bytes32 => Venue) private _venues; // venueId => venue
    bytes32[] private _venueIds;

    mapping(uint256 => Route) private _routes; // routeId => route
    mapping(bytes32 => uint256) private _routeKeyToLatestId;

    mapping(bytes32 => bool) private _quoteSeen;
    mapping(bytes32 => uint256) private _quoteToRouteId;
    mapping(address => uint256) private _dispatchCount;

    // ------------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------------

    modifier nonReentrant() {
        if (_lock != 0) revert DT__Reentrancy();
        _lock = 1;
        _;
        _lock = 0;
    }

    modifier whenNotPaused() {
        if (paused) revert DT__Paused();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert DT__NotOwner();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert DT__NotOperator();
        _;
    }

    modifier onlyTreasury() {
