// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title MockLendingPool
/// @notice DEMO CONTRACT ONLY -- NOT A PRODUCTION LENDING PROTOCOL.
///         This exists solely to make one narrative concrete and operable: that a
///         downstream protocol can depend on GapwatchRegistry's verification data
///         and change its own behavior in response. It does not move real funds
///         (`openPosition` just records numbers, no ERC20 transfer), does not
///         implement interest, liquidation thresholds, price oracles, or anything
///         else a real lending pool would need. The only thing worth auditing
///         here is the one real piece of logic: `pauseLiquidation` must be gated
///         by what the registry says, not by who calls it.
/// @dev Reads GapwatchRegistry through a minimal interface rather than importing
///      the whole contract, since this only ever needs two view calls.
interface IGapwatchRegistry {
    function latestVerificationForToken(address token) external view returns (bytes32);
    function hasDiscrepancy(bytes32 eventHash) external view returns (bool);
}

contract MockLendingPool {
    struct Position {
        address token;
        uint256 collateralAmount;
    }

    mapping(address => Position) public positions;

    /// @notice Per-token liquidation pause, set by `pauseLiquidation`. Deliberately
    ///         keyed by token rather than duplicated into every `Position` --
    ///         one flag per token is the actual state; a per-position copy would
    ///         just be a second place for it to go stale.
    mapping(address => bool) public tokenLiquidationPaused;

    IGapwatchRegistry public immutable registry;

    event PositionOpened(address indexed user, address indexed token, uint256 amount);
    event LiquidationPaused(address indexed token, bytes32 indexed eventHash);

    error NoVerificationForToken(address token);
    error NoDiscrepancyFlagged(bytes32 eventHash);

    constructor(address registryAddress) {
        registry = IGapwatchRegistry(registryAddress);
    }

    /// @notice Record a simulated collateral deposit. No token transfer happens --
    ///         this is a demo, not a working vault.
    function openPosition(address token, uint256 amount) external {
        positions[msg.sender] = Position({token: token, collateralAmount: amount});
        emit PositionOpened(msg.sender, token, amount);
    }

    /// @notice Simplified liquidation check: if the registry says this user's
    ///         collateral token currently has a flagged discrepancy, liquidation
    ///         is refused outright regardless of anything else. Otherwise, falls
    ///         back to a placeholder condition -- real liquidation math is not the
    ///         point of this demo.
    function checkLiquidatable(address user) external view returns (bool) {
        Position memory p = positions[user];
        if (tokenLiquidationPaused[p.token]) return false;
        return p.collateralAmount > 0;
    }

    /// @notice Pause liquidations for `token`. Open to anyone to call, but that is
    ///         safe: the only thing that actually flips the flag is the registry
    ///         already having a discrepancy on record for this token's latest
    ///         verification -- the check is on the data, not on msg.sender.
    ///         Shouting "pause" with no corroborating registry record does nothing.
    function pauseLiquidation(address token) external {
        bytes32 eventHash = registry.latestVerificationForToken(token);
        if (eventHash == bytes32(0)) revert NoVerificationForToken(token);
        if (!registry.hasDiscrepancy(eventHash)) revert NoDiscrepancyFlagged(eventHash);

        tokenLiquidationPaused[token] = true;
        emit LiquidationPaused(token, eventHash);
    }
}
