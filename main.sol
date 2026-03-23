// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Atunga — Nenek Boomer Claw Arena (commit/reveal ETH game)
/// @notice Klakson boomer bunyi: siapa yang paling jago baca takdir, dia yang ngambil hadiah. Indonesian-friendly, mainnet-safe patterns, no surprise upgrades.
/// @dev Tokenless: ETH only. Uses commit/reveal to reduce timing games. Winner pays via pull-like single transfer and guarded against reentrancy.
contract Atunga {
    // -------------------------------------------------------------------------
    // Unique constants (names + values are local to this contract)
    // -------------------------------------------------------------------------
    uint256 private constant ATG_BPS = 10_000;
    uint256 private constant ATG_MAX_FEE_BPS = 750; // 7.50%
    uint256 private constant ATG_MIN_WIN_ODDS_BPS = 25; // 0.25%
    uint256 private constant ATG_MAX_WIN_ODDS_BPS = 9_750; // 97.50%
    uint256 private constant ATG_MIN_DEPOSIT_WEI = 5e14; // 0.0005 ETH
    uint32 private constant ATG_HARD_ENTRY_CAP = 2048;
    uint64 private constant ATG_MIN_COMMIT_SECS = 7 minutes;
    uint64 private constant ATG_MAX_COMMIT_SECS = 70 minutes;
    uint64 private constant ATG_MIN_REVEAL_SECS = 6 minutes;
    uint64 private constant ATG_MAX_REVEAL_SECS = 65 minutes;
    uint32 private constant ATG_ROUND_ID_START = 1;

    bytes32 private immutable ATG_DOMAIN;

    // -------------------------------------------------------------------------
    // “Constructor addresses” (roles) — computed at deployment time
    // -------------------------------------------------------------------------
    address public immutable ATG_BOSS;
    address public immutable ATG_NENEK;
    address public immutable ATG_TREASURY;

    // -------------------------------------------------------------------------
    // Reentrancy guard
    // -------------------------------------------------------------------------
    uint256 private constant ATG_NOT_ENTERED = 1;
    uint256 private _reentrancyState = ATG_NOT_ENTERED;

    modifier nonReentrant() {
        if (_reentrancyState != ATG_NOT_ENTERED) revert ATG_ReentrancyLocked();
        _reentrancyState = 2;
        _;
        _reentrancyState = ATG_NOT_ENTERED;
    }

    // -------------------------------------------------------------------------
    // Custom errors (unique)
    // -------------------------------------------------------------------------
    error ATG_NotBoss();
    error ATG_NotNenek();
    error ATG_NotTreasury();
    error ATG_Paused();
    error ATG_ReentrancyLocked();
