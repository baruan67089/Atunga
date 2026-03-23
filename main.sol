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
    error ATG_AlreadyStarted();
    error ATG_InvalidSeedHash();
    error ATG_InvalidDeposit();
    error ATG_CommitWindowClosed();
    error ATG_RevealWindowClosed();
    error ATG_CommitAlreadyClosed();
    error ATG_CancelNotAllowed();
    error ATG_AlreadyCommitted();
    error ATG_CommitNotFound();
    error ATG_AlreadyRevealed();
    error ATG_InvalidSeed();
    error ATG_RoundFinalized();
    error ATG_InvalidRoundId();
    error ATG_InvalidBps();
    error ATG_FinalizationNotReady();
    error ATG_NoPrizeToClaim();
    error ATG_NotWinner();
    error ATG_PrizeAlreadyClaimed();
    error ATG_TransferFailed();
    error ATG_PriorRoundNotFinalized();
    error ATG_HardCapReached();
    error ATG_OverflowedConfig();
    error ATG_InvalidExtension();

    // -------------------------------------------------------------------------
    // Events (unique)
    // -------------------------------------------------------------------------
    event ATG_RolesInstated(
        bytes32 indexed salt,
        address indexed boss,
        address indexed nenek,
        address indexed treasury
    );
    event ATG_PauseToggled(bool paused, address indexed by);

    event ATG_RoundStarted(
        uint256 indexed roundId,
        uint64 commitEndsAt,
        uint64 revealEndsAt,
        uint256 minDepositWei,
        uint16 winOddsBps,
        uint16 feeBps,
        uint32 maxEntries,
        bytes32 roundSalt
    );
    event ATG_Entered(
        address indexed player,
        uint256 indexed roundId,
        uint256 amountWei,
        bytes32 seedHash
    );
    event ATG_Cancelled(address indexed player, uint256 indexed roundId, uint256 refundWei);
    event ATG_Revealed(
        address indexed player,
        uint256 indexed roundId,
        uint16 rollBps,
        bool candidate
    );
    event ATG_RoundFinalized(
        uint256 indexed roundId,
        address winner,
        uint256 prizeWei,
        uint256 feeWei,
        uint16 winningRollBps
    );
    event ATG_PrizeClaimed(
        address indexed winner,
        uint256 indexed roundId,
        uint256 amountWei
    );
    event ATG_TreasuryFeesWithdrawn(address indexed by, uint256 amountWei);

    event ATG_CommitExtended(
        uint256 indexed roundId,
        uint64 oldCommitEndsAt,
        uint64 newCommitEndsAt,
        uint64 bySeconds,
        address indexed by
    );
    event ATG_RevealExtended(
        uint256 indexed roundId,
        uint64 oldRevealEndsAt,
        uint64 newRevealEndsAt,
        uint64 bySeconds,
        address indexed by
    );

    // -------------------------------------------------------------------------
    // Global pause flag
    // -------------------------------------------------------------------------
    bool public paused;

    // -------------------------------------------------------------------------
    // Round storage
    // -------------------------------------------------------------------------
    struct Ticket {
        bytes32 seedHash;
        uint256 amountWei;
        bool revealed;
        bool claimed;
    }

    struct Round {
        uint64 commitEndsAt;
        uint64 revealEndsAt;
        uint256 minDepositWei;
        uint16 winOddsBps;
        uint16 feeBps;
        uint32 maxEntries;
        bytes32 roundSalt;

        bool started;
        bool finalized;

        uint32 entryCount;
        uint256 totalPotWei;

        // Winner is the best candidate (lowest roll) discovered during reveal.
        address bestWinner;
        uint16 bestRollBps;

        address winner;
        uint256 prizeWei;
        uint256 feeWei;
        bool winnerClaimed;
    }

    mapping(uint256 => Round) private _rounds;
    uint256 public currentRoundId;

    mapping(uint256 => mapping(address => Ticket)) private _tickets;

    // Round player lists (useful for UI paging; cancelled entries are filtered out).
    mapping(uint256 => address[]) private _roundPlayers;
    mapping(uint256 => mapping(address => bool)) private _roundPlayerActive;

    // Accumulated treasury fees across finalized rounds.
    uint256 private _treasuryFeesWei;

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------
    modifier onlyBoss() {
        if (msg.sender != ATG_BOSS) revert ATG_NotBoss();
        _;
    }

    modifier onlyNenek() {
        if (msg.sender != ATG_NENEK) revert ATG_NotNenek();
        _;
    }

    modifier onlyTreasury() {
        if (msg.sender != ATG_TREASURY) revert ATG_NotTreasury();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert ATG_Paused();
        _;
    }

    // -------------------------------------------------------------------------
    // Constructor — no user parameters needed
    // -------------------------------------------------------------------------
    constructor() {
        bytes32 base = keccak256(
            abi.encodePacked(
                "ATUNGA.v1",
                block.chainid,
                block.timestamp,
                msg.sender,
                address(this)
            )
        );
        ATG_DOMAIN = keccak256(abi.encodePacked(base, "ATUNGA.DOMAIN"));

        address boss = address(uint160(uint256(keccak256(abi.encodePacked(base, "ATG_BOSS")))));
        address nenek = address(uint160(uint256(keccak256(abi.encodePacked(base, "ATG_NENEK")))));
        address treasury = address(uint160(uint256(keccak256(abi.encodePacked(base, "ATG_TREASURY")))));

        if (nenek == boss) {
            nenek = address(uint160(uint256(keccak256(abi.encodePacked(base, "ATG_NENEK2")))));
        }
        if (treasury == boss || treasury == nenek) {
            treasury = address(uint160(uint256(keccak256(abi.encodePacked(base, "ATG_TREASURY2")))));
        }

        ATG_BOSS = boss;
        ATG_NENEK = nenek;
        ATG_TREASURY = treasury;

        emit ATG_RolesInstated(base, boss, nenek, treasury);

        paused = false;
        currentRoundId = ATG_ROUND_ID_START;

        _startRoundInternal();
    }

    // -------------------------------------------------------------------------
    // Round lifecycle (no external input required)
    // -------------------------------------------------------------------------
    function startNextRound() external whenNotPaused onlyBoss {
        Round storage prev = _rounds[currentRoundId];
        if (!prev.finalized) revert ATG_PriorRoundNotFinalized();

        unchecked {
