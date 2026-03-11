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
        if (msg.sender != treasury) revert DT__NotTreasury();
        _;
    }

    // ------------------------------------------------------------------------
    // Constructor (random, EIP-55 literals)
    // ------------------------------------------------------------------------

    constructor() {
        bootOwner = 0xB6dE40a19c7F2bA8E53D1c0F9A7b6C5D4E3f2A10;
        bootOperator = 0x1F4aC8e3D0b7A2c5E9F1b3D6c8E0A2b4C6d8F0a1;
        bootTreasury = 0x9cE1b7D3F0a2C6d8E0A2b4C6d8F0A2b4c6D8e0A2;
        owner = bootOwner;
        operator = bootOperator;
        treasury = bootTreasury;
        genesisBlock = block.number;
        _nextRouteId = 1;
    }

    // ------------------------------------------------------------------------
    // Ownership / roles
    // ------------------------------------------------------------------------

    function proposeOwner(address next) external onlyOwner {
        if (next == address(0)) revert DT__BadAddress();
        pendingOwner = next;
        emit OwnerProposed(owner, next, uint64(block.number));
    }

    function acceptOwner() external {
        if (msg.sender != pendingOwner) revert DT__NotPendingOwner();
        address prev = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnerAccepted(prev, owner, uint64(block.number));
    }

    function setOperator(address next) external onlyOwner {
        if (next == address(0)) revert DT__BadAddress();
        address prev = operator;
        operator = next;
        emit OperatorChanged(prev, next, uint64(block.number));
    }

    function setTreasury(address next) external onlyOwner {
        if (next == address(0)) revert DT__BadAddress();
        address prev = treasury;
        treasury = next;
        emit TreasuryChanged(prev, next, uint64(block.number));
    }

    function togglePause() external onlyOwner {
        paused = !paused;
        emit PauseToggled(paused, uint64(block.number));
    }

    function toggleSeal() external onlyOwner {
        sealed = !sealed;
        emit SealToggled(sealed, uint64(block.number));
    }

    // ------------------------------------------------------------------------
    // Venue catalog
    // ------------------------------------------------------------------------

    function catalogVenue(bytes32 venueId, uint32 chainId, bytes32 venueTag) external onlyOperator nonReentrant {
        if (sealed) revert DT__Sealed();
        if (venueId == bytes32(0)) revert DT__BadVenue();
        if (chainId == 0) revert DT__BadChain();
        Venue storage v = _venues[venueId];
        if (!v.exists) {
            if (_venueIds.length >= DT_MAX_VENUES) revert DT__TooLarge();
            _venueIds.push(venueId);
            v.exists = true;
            v.catalogedAt = uint64(block.number);
            unchecked { ++_nextVenueIndex; }
        }
        v.chainId = chainId;
        v.venueTag = venueTag;
        v.enabled = true;
        emit VenueCataloged(venueId, chainId, venueTag, uint64(block.number));
        emit VenueEnabled(venueId, true, uint64(block.number));
    }

    function setVenueEnabled(bytes32 venueId, bool enabled) external onlyOperator {
        Venue storage v = _venues[venueId];
        if (!v.exists) revert DT__Missing();
        v.enabled = enabled;
        emit VenueEnabled(venueId, enabled, uint64(block.number));
    }

    function venueOf(bytes32 venueId) external view returns (uint32 chainId, bytes32 venueTag, bool enabled, uint64 catalogedAt, bool exists) {
        Venue storage v = _venues[venueId];
        return (v.chainId, v.venueTag, v.enabled, v.catalogedAt, v.exists);
    }

    function venueIds() external view returns (bytes32[] memory) {
        return _venueIds;
    }

    // ------------------------------------------------------------------------
    // Routes
    // ------------------------------------------------------------------------

    function computeRouteKey(
        uint32 srcChain,
        uint32 dstChain,
        bytes32 srcAsset,
        bytes32 dstAsset
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked("ROUTE", srcChain, dstChain, srcAsset, dstAsset));
    }

    function authorRoute(
        uint32 srcChain,
        uint32 dstChain,
        bytes32 srcAsset,
        bytes32 dstAsset,
        uint16 maxSlippageBps,
        bytes32[] calldata venuePath
    ) external onlyOperator whenNotPaused nonReentrant returns (uint256 routeId) {
        if (sealed) revert DT__Sealed();
        if (srcChain == 0 || dstChain == 0 || srcChain == dstChain) revert DT__BadChain();
        if (srcAsset == bytes32(0) || dstAsset == bytes32(0)) revert DT__BadBytes();
        if (maxSlippageBps == 0 || maxSlippageBps > DT_MAX_SLIPPAGE_BPS) revert DT__BadAmount();
        uint256 vpLen = venuePath.length;
        if (vpLen == 0 || vpLen > 16) revert DT__BadRoute();
        if (_nextRouteId > DT_MAX_ROUTES) revert DT__TooLarge();

        bytes32 key = computeRouteKey(srcChain, dstChain, srcAsset, dstAsset);
        routeId = _nextRouteId;
        unchecked { ++_nextRouteId; }

        Route storage r = _routes[routeId];
        r.routeKey = key;
        r.srcChain = srcChain;
        r.dstChain = dstChain;
        r.srcAsset = srcAsset;
        r.dstAsset = dstAsset;
        r.maxSlippageBps = maxSlippageBps;
        r.retired = false;
        r.authoredAt = uint64(block.number);

        for (uint256 i; i < vpLen; ) {
            bytes32 vid = venuePath[i];
            Venue storage v = _venues[vid];
            if (!v.exists || !v.enabled) revert DT__BadVenue();
            r.venuePath.push(vid);
            unchecked { ++i; }
        }

        _routeKeyToLatestId[key] = routeId;

        emit RouteAuthored(routeId, key, srcChain, dstChain, srcAsset, dstAsset, maxSlippageBps, uint64(block.number));
    }

    function retireRoute(uint256 routeId) external onlyOperator nonReentrant {
        if (sealed) revert DT__Sealed();
        Route storage r = _routes[routeId];
        if (r.routeKey == bytes32(0)) revert DT__Missing();
        if (r.retired) revert DT__Already();
        r.retired = true;
        emit RouteRetired(routeId, uint64(block.number));
    }

    function routeOf(uint256 routeId) external view returns (
        bytes32 routeKey,
        uint32 srcChain,
        uint32 dstChain,
        bytes32 srcAsset,
        bytes32 dstAsset,
        uint16 maxSlippageBps,
        bool retired,
        uint64 authoredAt
    ) {
        Route storage r = _routes[routeId];
        if (r.routeKey == bytes32(0)) revert DT__Missing();
        return (r.routeKey, r.srcChain, r.dstChain, r.srcAsset, r.dstAsset, r.maxSlippageBps, r.retired, r.authoredAt);
    }

    function routeVenuePath(uint256 routeId) external view returns (bytes32[] memory) {
        Route storage r = _routes[routeId];
        if (r.routeKey == bytes32(0)) revert DT__Missing();
        return r.venuePath;
    }

    function latestRouteId(bytes32 routeKey) external view returns (uint256) {
        return _routeKeyToLatestId[routeKey];
    }

    function nextRouteId() external view returns (uint256) {
        return _nextRouteId;
    }

    // ------------------------------------------------------------------------
    // Quotes and dispatch (signals only)
    // ------------------------------------------------------------------------

    function computeQuoteId(bytes32 routeKey, uint256 routeId, uint128 srcAmount, uint64 validUntilBlock) public pure returns (bytes32) {
        return keccak256(abi.encodePacked("QUOTE", routeKey, routeId, srcAmount, validUntilBlock));
    }

    function stampQuote(
        uint256 routeId,
        uint128 srcAmount,
        uint128 expectedDstAmount,
        uint64 validUntilBlock
    ) external onlyOperator whenNotPaused nonReentrant returns (bytes32 quoteId) {
        Route storage r = _routes[routeId];
        if (r.routeKey == bytes32(0)) revert DT__Missing();
        if (r.retired) revert DT__BadRoute();
        if (srcAmount == 0 || expectedDstAmount == 0) revert DT__BadAmount();
        if (validUntilBlock <= uint64(block.number)) revert DT__BadNonce();

        quoteId = computeQuoteId(r.routeKey, routeId, srcAmount, validUntilBlock);
        if (_quoteSeen[quoteId]) revert DT__Already();
        _quoteSeen[quoteId] = true;
        _quoteToRouteId[quoteId] = routeId;

        bytes32 digest = keccak256(abi.encodePacked(quoteId, expectedDstAmount, validUntilBlock, DT_DOMAIN, DT_SALT));
        emit QuoteStamped(quoteId, r.routeKey, routeId, srcAmount, expectedDstAmount, validUntilBlock, digest);
    }

    function quoteSeen(bytes32 quoteId) external view returns (bool) {
        return _quoteSeen[quoteId];
    }

    function quoteRouteId(bytes32 quoteId) external view returns (uint256) {
        return _quoteToRouteId[quoteId];
    }

    function signalDispatch(bytes32 quoteId, bytes32 intentHash) external whenNotPaused nonReentrant returns (bytes32 dispatchId) {
        if (!_quoteSeen[quoteId]) revert DT__Missing();
        if (intentHash == bytes32(0)) revert DT__BadBytes();
        dispatchId = keccak256(abi.encodePacked("DISPATCH", quoteId, msg.sender, intentHash, block.number, block.chainid));
        unchecked { _dispatchCount[msg.sender] += 1; }
        emit DispatchSignaled(dispatchId, quoteId, msg.sender, intentHash, uint64(block.number));
    }

    function dispatchCount(address account) external view returns (uint256) {
        return _dispatchCount[account];
    }

    // ------------------------------------------------------------------------
    // Treasury (cap)
    // ------------------------------------------------------------------------

    receive() external payable {}

    function totalWithdrawnWei() external view returns (uint256) {
        return _totalWithdrawnWei;
    }

    function remainingWithdrawCap() external view returns (uint256) {
        return _totalWithdrawnWei >= DT_WITHDRAW_CAP_WEI ? 0 : DT_WITHDRAW_CAP_WEI - _totalWithdrawnWei;
    }

    function withdrawTreasury(address to, uint256 amountWei) external onlyTreasury nonReentrant {
        if (to == address(0)) revert DT__BadAddress();
        if (amountWei == 0) revert DT__BadAmount();
        if (_totalWithdrawnWei + amountWei > DT_WITHDRAW_CAP_WEI) revert DT__BadAmount();
        _totalWithdrawnWei += amountWei;
        (bool ok,) = to.call{value: amountWei}("");
        if (!ok) revert DT__TransferFailed();
        emit TreasuryWithdrawn(to, amountWei, uint64(block.number));
    }

    // ------------------------------------------------------------------------
    // Utility / UI helpers
    // ------------------------------------------------------------------------

    function chainName(uint32 chainId) public pure returns (string memory) {
        if (chainId == DT_CHAIN_EVM) return "EVM";
        if (chainId == DT_CHAIN_SOLANA) return "SOLANA";
        if (chainId == DT_CHAIN_SUI) return "SUI";
        return string(abi.encodePacked("CHAIN_", uint256(chainId).toString()));
    }

    function describeRoute(uint256 routeId) external view returns (string memory) {
        Route storage r = _routes[routeId];
        if (r.routeKey == bytes32(0)) return "ROUTE_NONE";
        return string(abi.encodePacked(
            "ROUTE_",
            routeId.toString(),
            "_",
            chainName(r.srcChain),
            "_TO_",
            chainName(r.dstChain)
        ));
    }

    function describeVenue(bytes32 venueId) external view returns (string memory) {
        Venue storage v = _venues[venueId];
        if (!v.exists) return "VENUE_NONE";
        return string(abi.encodePacked("VENUE_", chainName(v.chainId), "_", v.enabled ? "ON" : "OFF"));
    }

    function revision() external pure returns (uint256) { return DT_REVISION; }
    function domain() external pure returns (bytes32) { return DT_DOMAIN; }
    function salt() external pure returns (bytes32) { return DT_SALT; }
    function quote() external pure returns (string memory) { return "Olah, route it."; }

    function roleAddresses() external view returns (address owner_, address operator_, address treasury_) {
        return (owner, operator, treasury);
    }

    function isSealed() external view returns (bool) { return sealed; }
    function isPaused() external view returns (bool) { return paused; }

    function config() external pure returns (uint16 bps, uint16 maxSlippageBps, uint256 maxRoutes, uint256 maxVenues, uint256 maxBatch, uint256 withdrawCapWei) {
        return (DT_BPS, DT_MAX_SLIPPAGE_BPS, DT_MAX_ROUTES, DT_MAX_VENUES, DT_MAX_BATCH, DT_WITHDRAW_CAP_WEI);
    }

    // ------------------------------------------------------------------------
    // Extended read API (routes, venues, quotes)
    // ------------------------------------------------------------------------

    struct VenueView {
        bytes32 venueId;
        uint32 chainId;
        bytes32 venueTag;
        bool enabled;
        uint64 catalogedAt;
        bool exists;
    }

    struct RouteView {
        uint256 routeId;
        bytes32 routeKey;
        uint32 srcChain;
        uint32 dstChain;
        bytes32 srcAsset;
        bytes32 dstAsset;
        uint16 maxSlippageBps;
        bool retired;
        uint64 authoredAt;
        uint256 venuePathLen;
    }

    function venueCount() external view returns (uint256) {
        return _venueIds.length;
    }

    function routeCount() external view returns (uint256) {
        return _nextRouteId <= 1 ? 0 : _nextRouteId - 1;
    }

    function venueExists(bytes32 venueId) public view returns (bool) {
        return _venues[venueId].exists;
    }

    function venueEnabled(bytes32 venueId) public view returns (bool) {
        Venue storage v = _venues[venueId];
        return v.exists && v.enabled;
    }

    function getVenueView(bytes32 venueId) external view returns (VenueView memory v) {
        Venue storage info = _venues[venueId];
        v.venueId = venueId;
        v.chainId = info.chainId;
        v.venueTag = info.venueTag;
        v.enabled = info.enabled;
        v.catalogedAt = info.catalogedAt;
        v.exists = info.exists;
    }

    function getVenueViews(bytes32[] calldata venueIds_) external view returns (VenueView[] memory views) {
        uint256 n = venueIds_.length;
        if (n > DT_MAX_BATCH) revert DT__TooLarge();
        views = new VenueView[](n);
        for (uint256 i; i < n; ) {
            bytes32 id = venueIds_[i];
            Venue storage info = _venues[id];
            views[i] = VenueView({
                venueId: id,
                chainId: info.chainId,
                venueTag: info.venueTag,
                enabled: info.enabled,
                catalogedAt: info.catalogedAt,
                exists: info.exists
            });
            unchecked { ++i; }
        }
    }

    function venueIdsPage(uint256 offset, uint256 limit) external view returns (bytes32[] memory ids) {
        if (limit == 0) revert DT__BadAmount();
        uint256 nAll = _venueIds.length;
        if (offset >= nAll) return new bytes32[](0);
        uint256 end = offset + limit;
        if (end > nAll) end = nAll;
        uint256 n = end - offset;
        ids = new bytes32[](n);
        for (uint256 i; i < n; ) {
            ids[i] = _venueIds[offset + i];
            unchecked { ++i; }
        }
    }

    function getRouteView(uint256 routeId) external view returns (RouteView memory v) {
        Route storage r = _routes[routeId];
        if (r.routeKey == bytes32(0)) revert DT__Missing();
        v.routeId = routeId;
        v.routeKey = r.routeKey;
        v.srcChain = r.srcChain;
        v.dstChain = r.dstChain;
        v.srcAsset = r.srcAsset;
        v.dstAsset = r.dstAsset;
        v.maxSlippageBps = r.maxSlippageBps;
        v.retired = r.retired;
        v.authoredAt = r.authoredAt;
        v.venuePathLen = r.venuePath.length;
    }

    function getRouteViews(uint256[] calldata routeIds) external view returns (RouteView[] memory views) {
        uint256 n = routeIds.length;
        if (n > DT_MAX_BATCH) revert DT__TooLarge();
        views = new RouteView[](n);
        for (uint256 i; i < n; ) {
            uint256 rid = routeIds[i];
            Route storage r = _routes[rid];
            if (r.routeKey != bytes32(0)) {
                views[i] = RouteView({
                    routeId: rid,
                    routeKey: r.routeKey,
                    srcChain: r.srcChain,
                    dstChain: r.dstChain,
                    srcAsset: r.srcAsset,
                    dstAsset: r.dstAsset,
                    maxSlippageBps: r.maxSlippageBps,
                    retired: r.retired,
                    authoredAt: r.authoredAt,
                    venuePathLen: r.venuePath.length
                });
            }
            unchecked { ++i; }
        }
    }

    function routeKeys(uint256[] calldata routeIds) external view returns (bytes32[] memory keys) {
        uint256 n = routeIds.length;
        if (n > DT_MAX_BATCH) revert DT__TooLarge();
        keys = new bytes32[](n);
        for (uint256 i; i < n; ) {
            keys[i] = _routes[routeIds[i]].routeKey;
            unchecked { ++i; }
        }
    }

    function routeVenuePathLen(uint256 routeId) external view returns (uint256) {
        Route storage r = _routes[routeId];
        if (r.routeKey == bytes32(0)) revert DT__Missing();
        return r.venuePath.length;
    }

    function routeVenueAt(uint256 routeId, uint256 index) external view returns (bytes32) {
        Route storage r = _routes[routeId];
        if (r.routeKey == bytes32(0)) revert DT__Missing();
        if (index >= r.venuePath.length) revert DT__BadIndex();
        return r.venuePath[index];
    }

    function routeVenuesSlice(uint256 routeId, uint256 offset, uint256 limit) external view returns (bytes32[] memory ids) {
        Route storage r = _routes[routeId];
        if (r.routeKey == bytes32(0)) revert DT__Missing();
        uint256 nAll = r.venuePath.length;
        if (offset >= nAll) return new bytes32[](0);
        uint256 end = offset + limit;
        if (end > nAll) end = nAll;
        uint256 n = end - offset;
        ids = new bytes32[](n);
        for (uint256 i; i < n; ) {
            ids[i] = r.venuePath[offset + i];
            unchecked { ++i; }
        }
    }

    function routesPage(uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        if (limit == 0) revert DT__BadAmount();
        uint256 nextId = _nextRouteId;
        if (nextId <= 1) return new uint256[](0);
        if (offset == 0) offset = 1;
        if (offset >= nextId) return new uint256[](0);
        uint256 end = offset + limit;
        if (end > nextId) end = nextId;
        uint256 n = end - offset;
        ids = new uint256[](n);
        for (uint256 i; i < n; ) {
            ids[i] = offset + i;
            unchecked { ++i; }
        }
    }

    function routesReverse(uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        if (limit == 0 || limit > DT_MAX_BATCH) revert DT__BadAmount();
        uint256 nextId = _nextRouteId;
        if (nextId <= 1) return new uint256[](0);
        uint256 start = nextId - 1;
        if (offset > start) return new uint256[](0);
        start = start - offset;
        uint256 n = limit;
        if (start + 1 < n) n = start + 1;
        ids = new uint256[](n);
        for (uint256 i; i < n; ) {
            ids[i] = start - i;
            unchecked { ++i; }
        }
    }

    // ------------------------------------------------------------------------
    // Stats (O(n) views)
    // ------------------------------------------------------------------------

    function venueEnabledCount() external view returns (uint256 count) {
        uint256 n = _venueIds.length;
        for (uint256 i; i < n; ) {
            if (_venues[_venueIds[i]].enabled) unchecked { ++count; }
            unchecked { ++i; }
        }
    }

    function venueDisabledCount() external view returns (uint256 count) {
        uint256 n = _venueIds.length;
        for (uint256 i; i < n; ) {
            Venue storage v = _venues[_venueIds[i]];
            if (v.exists && !v.enabled) unchecked { ++count; }
            unchecked { ++i; }
        }
    }

    function routeRetiredCount() external view returns (uint256 count) {
        uint256 nextId = _nextRouteId;
        for (uint256 id = 1; id < nextId; ) {
            if (_routes[id].retired) unchecked { ++count; }
            unchecked { ++id; }
        }
    }

    function routeActiveCount() external view returns (uint256 count) {
        uint256 nextId = _nextRouteId;
        for (uint256 id = 1; id < nextId; ) {
            Route storage r = _routes[id];
            if (r.routeKey != bytes32(0) && !r.retired) unchecked { ++count; }
            unchecked { ++id; }
        }
    }

    function chainHistogram() external view returns (uint256 evm, uint256 sol, uint256 sui, uint256 other) {
        uint256 nextId = _nextRouteId;
        for (uint256 id = 1; id < nextId; ) {
            Route storage r = _routes[id];
            if (r.routeKey != bytes32(0)) {
                if (r.dstChain == DT_CHAIN_EVM) unchecked { ++evm; }
                else if (r.dstChain == DT_CHAIN_SOLANA) unchecked { ++sol; }
                else if (r.dstChain == DT_CHAIN_SUI) unchecked { ++sui; }
                else unchecked { ++other; }
            }
            unchecked { ++id; }
        }
    }

    function dispatchCountBatch(address[] calldata accounts) external view returns (uint256[] memory counts_) {
        uint256 n = accounts.length;
        if (n > DT_MAX_BATCH) revert DT__TooLarge();
        counts_ = new uint256[](n);
        for (uint256 i; i < n; ) {
            counts_[i] = _dispatchCount[accounts[i]];
            unchecked { ++i; }
        }
    }

    // ------------------------------------------------------------------------
    // Hashing helpers (pure)
    // ------------------------------------------------------------------------

    function hashVenue(bytes32 venueTag, uint32 chainId, bytes32 salt_) external pure returns (bytes32) {
        return keccak256(abi.encodePacked("VENUE", venueTag, chainId, salt_));
    }

    function hashAsset(bytes32 symbolTag, uint8 decimals_) external pure returns (bytes32) {
        return keccak256(abi.encodePacked("ASSET", symbolTag, decimals_));
    }

    function hashPair(bytes32 srcAsset, bytes32 dstAsset) external pure returns (bytes32) {
        return keccak256(abi.encodePacked("PAIR", srcAsset, dstAsset));
    }

    function hashRouteKey(bytes32 routeKey, bytes32 salt_) external pure returns (bytes32) {
        return keccak256(abi.encodePacked("ROUTE_KEY", routeKey, salt_));
    }

    function hashQuoteDigest(bytes32 quoteId, uint128 expectedDstAmount, uint64 validUntilBlock) external pure returns (bytes32) {
        return keccak256(abi.encodePacked("Q", quoteId, expectedDstAmount, validUntilBlock));
    }

    function hashDispatch(bytes32 quoteId, address requester, bytes32 intentHash, uint256 chainId, uint256 blockNumber) external pure returns (bytes32) {
        return keccak256(abi.encodePacked("D", quoteId, requester, intentHash, chainId, blockNumber));
    }

    function mix(bytes32 a, bytes32 b) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(a, b));
    }

    function mix3(bytes32 a, bytes32 b, bytes32 c) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(a, b, c));
    }

    function mix4(bytes32 a, bytes32 b, bytes32 c, bytes32 d) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(a, b, c, d));
    }

    // ------------------------------------------------------------------------
    // Validation helpers (views)
    // ------------------------------------------------------------------------

    function validateVenue(bytes32 venueId) external view returns (bool ok, string memory why) {
        Venue storage v = _venues[venueId];
        if (!v.exists) return (false, "missing");
        if (!v.enabled) return (false, "disabled");
        if (v.chainId == 0) return (false, "bad_chain");
        return (true, "ok");
