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
            currentRoundId += 1;
        }
        _startRoundInternal();
    }

    function _startRoundInternal() private {
        Round storage r = _rounds[currentRoundId];

        // “Random” but deterministic-per-deploy: derived from block values at call time.
        // No reliance on external oracles.
        bytes32 salt = keccak256(abi.encodePacked(ATG_DOMAIN, currentRoundId, blockhash(block.number - 1), block.timestamp));

        uint64 commitLen = _boundU64(uint64(uint256(keccak256(abi.encodePacked(salt, "COMMIT_LEN")))), ATG_MIN_COMMIT_SECS, ATG_MAX_COMMIT_SECS);
        uint64 revealLen = _boundU64(uint64(uint256(keccak256(abi.encodePacked(salt, "REVEAL_LEN")))), ATG_MIN_REVEAL_SECS, ATG_MAX_REVEAL_SECS);

        uint256 minDepositWei = _boundU256(
            uint256(keccak256(abi.encodePacked(salt, "MIN_DEPOSIT"))),
            ATG_MIN_DEPOSIT_WEI,
            5 ether
        );

        uint16 feeBps = _boundU16(uint16(uint256(keccak256(abi.encodePacked(salt, "FEE_BPS")) % ATG_MAX_FEE_BPS)));
        uint16 winOddsBps = _boundU16(uint16(uint256(keccak256(abi.encodePacked(salt, "WIN_ODDS")) % ATG_MAX_WIN_ODDS_BPS)));
        if (winOddsBps < ATG_MIN_WIN_ODDS_BPS) winOddsBps = uint16(ATG_MIN_WIN_ODDS_BPS);

        uint32 maxEntries = _boundU32(uint32(uint256(keccak256(abi.encodePacked(salt, "MAX_ENTRIES")) % 400)) + 16, 16, ATG_HARD_ENTRY_CAP);

        uint64 commitEndsAt = uint64(block.timestamp + commitLen);
        uint64 revealEndsAt = uint64(commitEndsAt + revealLen);

        // Sanity: ensure bps are in range.
        if (feeBps == 0 || feeBps > ATG_MAX_FEE_BPS) revert ATG_InvalidBps();
        if (winOddsBps == 0 || winOddsBps > ATG_BPS) revert ATG_InvalidBps();
        if (minDepositWei < ATG_MIN_DEPOSIT_WEI) revert ATG_InvalidDeposit();

        r.commitEndsAt = commitEndsAt;
        r.revealEndsAt = revealEndsAt;
        r.minDepositWei = minDepositWei;
        r.winOddsBps = winOddsBps;
        r.feeBps = feeBps;
        r.maxEntries = maxEntries;
        r.roundSalt = salt;

        r.started = true;
        r.finalized = false;
        r.entryCount = 0;
        r.totalPotWei = 0;
        r.bestWinner = address(0);
        r.bestRollBps = uint16(ATG_BPS);

        r.winner = address(0);
        r.prizeWei = 0;
        r.feeWei = 0;
        r.winnerClaimed = false;

        emit ATG_RoundStarted(
            currentRoundId,
            commitEndsAt,
            revealEndsAt,
            minDepositWei,
            winOddsBps,
            feeBps,
            maxEntries,
            salt
        );
    }

    function _boundU64(uint64 v, uint64 minV, uint64 maxV) private pure returns (uint64) {
        if (v < minV) return minV;
        if (v > maxV) return maxV;
        return v;
    }

    function _boundU32(uint32 v, uint32 minV, uint32 maxV) private pure returns (uint32) {
        if (v < minV) return minV;
        if (v > maxV) return maxV;
        return v;
    }

    function _boundU16(uint16 v) private pure returns (uint16) {
        // v already reduced, but keep it safe-ish.
        if (v == 0) return 1;
        if (v > ATG_BPS) return uint16(ATG_BPS);
        return v;
    }

    function _boundU256(uint256 v, uint256 minV, uint256 maxV) private pure returns (uint256) {
        if (v < minV) return minV;
        if (v > maxV) return maxV;
        return v;
    }

    // -------------------------------------------------------------------------
    // Commit / reveal
    // -------------------------------------------------------------------------
    function enterClaw(bytes32 seedHash) external payable whenNotPaused {
        Round storage r = _rounds[currentRoundId];
        if (!r.started) revert ATG_AlreadyStarted();
        if (block.timestamp >= r.commitEndsAt) revert ATG_CommitWindowClosed();
        if (seedHash == bytes32(0)) revert ATG_InvalidSeedHash();
        if (r.entryCount >= r.maxEntries) revert ATG_HardCapReached();

        Ticket storage t = _tickets[currentRoundId][msg.sender];
        if (t.seedHash != bytes32(0)) revert ATG_AlreadyCommitted();
        if (msg.value < r.minDepositWei) revert ATG_InvalidDeposit();

        if (!_roundPlayerActive[currentRoundId][msg.sender]) {
            _roundPlayerActive[currentRoundId][msg.sender] = true;
            _roundPlayers[currentRoundId].push(msg.sender);
        }

        r.entryCount += 1;
        r.totalPotWei += msg.value;

        t.seedHash = seedHash;
        t.amountWei = msg.value;
        t.revealed = false;
        t.claimed = false;

        emit ATG_Entered(msg.sender, currentRoundId, msg.value, seedHash);
    }

    /// @notice Cancel entry and refund during commit window (before reveal starts).
    /// @dev Keeps fairness by only allowing cancellation while `block.timestamp < commitEndsAt`.
    function cancelEntry(uint256 roundId) external nonReentrant whenNotPaused {
        Round storage r = _rounds[roundId];
        if (!r.started) revert ATG_InvalidRoundId();
        if (block.timestamp >= r.commitEndsAt) revert ATG_CommitWindowClosed();
        if (r.finalized) revert ATG_RoundFinalized();

        Ticket storage t = _tickets[roundId][msg.sender];
        if (t.seedHash == bytes32(0)) revert ATG_CommitNotFound();
        if (t.revealed) revert ATG_AlreadyRevealed();
        if (t.claimed) revert ATG_PrizeAlreadyClaimed();

        uint256 refundWei = t.amountWei;
        if (refundWei == 0) revert ATG_InvalidDeposit();

        // Effects
        t.seedHash = bytes32(0);
        t.amountWei = 0;
        t.revealed = false;
        t.claimed = false;
        _roundPlayerActive[roundId][msg.sender] = false;

        // Accounting updates
        r.entryCount -= 1;
        r.totalPotWei -= refundWei;

        // Interactions
        (bool ok, ) = msg.sender.call{value: refundWei}("");
        if (!ok) revert ATG_TransferFailed();

        emit ATG_Cancelled(msg.sender, roundId, refundWei);
    }

    // NOTE: seed is user secret. Reveal must match the commit seedHash.
    function revealClaw(uint256 roundId, bytes32 seed) external whenNotPaused {
        Round storage r = _rounds[roundId];
        if (!r.started) revert ATG_InvalidRoundId();
        if (block.timestamp < r.commitEndsAt) revert ATG_CommitWindowClosed();
        if (block.timestamp >= r.revealEndsAt) revert ATG_RevealWindowClosed();
        if (r.finalized) revert ATG_RoundFinalized();

        Ticket storage t = _tickets[roundId][msg.sender];
        if (t.seedHash == bytes32(0)) revert ATG_CommitNotFound();
        if (t.revealed) revert ATG_AlreadyRevealed();
        if (t.claimed) revert ATG_RoundFinalized();

        if (t.seedHash != keccak256(abi.encodePacked(seed))) revert ATG_InvalidSeed();

        bytes32 entropy = keccak256(
            abi.encodePacked(
                seed,
                msg.sender,
                roundId,
                t.seedHash,
                r.roundSalt
            )
        );

        uint16 rollBps = uint16(uint256(entropy) % ATG_BPS);
        bool candidate = rollBps < r.winOddsBps;

        if (candidate && rollBps < r.bestRollBps) {
            r.bestRollBps = rollBps;
            r.bestWinner = msg.sender;
        }

        t.revealed = true;

        emit ATG_Revealed(msg.sender, roundId, rollBps, candidate);
    }

    // -------------------------------------------------------------------------
    // Finalize + claim
    // -------------------------------------------------------------------------
    function finalizeRound(uint256 roundId) external whenNotPaused {
        Round storage r = _rounds[roundId];
        if (!r.started) revert ATG_InvalidRoundId();
        if (r.finalized) revert ATG_RoundFinalized();
        if (block.timestamp < r.revealEndsAt) revert ATG_FinalizationNotReady();

        r.finalized = true;

        uint256 feeWei = (r.totalPotWei * uint256(r.feeBps)) / ATG_BPS;
        uint256 prizeWei = r.totalPotWei - feeWei;
        r.feeWei = feeWei;
        r.prizeWei = prizeWei;

        address winner = r.bestWinner;
        uint16 winningRoll = r.bestRollBps;
        if (winner == address(0)) {
            winner = ATG_TREASURY;
            winningRoll = 0;
        }
        r.winner = winner;

        if (feeWei != 0) {
            _treasuryFeesWei += feeWei;
        }

        emit ATG_RoundFinalized(roundId, winner, prizeWei, feeWei, winningRoll);
    }

    function claimPrize(uint256 roundId) external nonReentrant whenNotPaused {
        Round storage r = _rounds[roundId];
        if (!r.finalized) revert ATG_RoundFinalized();
        if (r.winner == address(0)) revert ATG_NoPrizeToClaim();
        if (msg.sender != r.winner) revert ATG_NotWinner();
        if (r.winnerClaimed) revert ATG_PrizeAlreadyClaimed();

        uint256 amt = r.prizeWei;
        if (amt == 0) revert ATG_NoPrizeToClaim();

        r.winnerClaimed = true;
        Ticket storage t = _tickets[roundId][msg.sender];
        if (t.seedHash != bytes32(0)) {
            t.claimed = true;
        }

        (bool ok, ) = msg.sender.call{value: amt}("");
        if (!ok) revert ATG_TransferFailed();

        emit ATG_PrizeClaimed(msg.sender, roundId, amt);
    }

    function withdrawTreasuryFees() external nonReentrant onlyTreasury whenNotPaused {
        uint256 amt = _treasuryFeesWei;
        if (amt == 0) revert ATG_NoPrizeToClaim();
        _treasuryFeesWei = 0;

        (bool ok, ) = ATG_TREASURY.call{value: amt}("");
        if (!ok) revert ATG_TransferFailed();

        emit ATG_TreasuryFeesWithdrawn(msg.sender, amt);
    }

    // -------------------------------------------------------------------------
    // Boss / Nenek controls (pause & emergency sweep of rounds)
    // -------------------------------------------------------------------------
    function setPaused(bool p) external onlyBoss {
        paused = p;
        emit ATG_PauseToggled(p, msg.sender);
    }

    /// @notice Extend commit window for a round (boss-only).
    /// @dev Keeps reveal length the same by shifting reveal end together.
    function extendCommitWindow(uint256 roundId, uint64 extraSeconds) external onlyBoss whenNotPaused {
        Round storage r = _rounds[roundId];
        if (!r.started) revert ATG_InvalidRoundId();
        if (r.finalized) revert ATG_RoundFinalized();
        if (block.timestamp >= r.commitEndsAt) revert ATG_CommitAlreadyClosed();

        if (extraSeconds == 0 || extraSeconds > 2 hours) revert ATG_InvalidExtension();

        uint64 oldCommit = r.commitEndsAt;
        uint64 oldReveal = r.revealEndsAt;

        uint64 newCommit = r.commitEndsAt + extraSeconds;
        uint64 newReveal = r.revealEndsAt + extraSeconds;

        // Rough overflow guard: uint64 wrap would reduce the end times.
        if (newCommit <= oldCommit || newReveal <= oldReveal) revert ATG_OverflowedConfig();

        r.commitEndsAt = newCommit;
        r.revealEndsAt = newReveal;

        emit ATG_CommitExtended(roundId, oldCommit, newCommit, extraSeconds, msg.sender);
    }

    /// @notice Extend reveal window for a round (boss-only).
    function extendRevealWindow(uint256 roundId, uint64 extraSeconds) external onlyBoss whenNotPaused {
        Round storage r = _rounds[roundId];
        if (!r.started) revert ATG_InvalidRoundId();
        if (r.finalized) revert ATG_RoundFinalized();
        if (block.timestamp >= r.revealEndsAt) revert ATG_RevealWindowClosed();

        if (extraSeconds == 0 || extraSeconds > 2 hours) revert ATG_InvalidExtension();

        uint64 oldReveal = r.revealEndsAt;
        uint64 newReveal = r.revealEndsAt + extraSeconds;

        if (newReveal <= oldReveal) revert ATG_OverflowedConfig();

        r.revealEndsAt = newReveal;

        emit ATG_RevealExtended(roundId, oldReveal, newReveal, extraSeconds, msg.sender);
    }

    // Nenek can force finalize once reveal ends (permissionless is still allowed via finalizeRound).
    function nenekFinalize(uint256 roundId) external onlyNenek {
        // This funnels into finalizeRound to keep accounting identical.
        // Reentrancy not required since finalizeRound makes no external calls.
        if (_rounds[roundId].started && !_rounds[roundId].finalized && block.timestamp >= _rounds[roundId].revealEndsAt) {
            // no-op, call the internal logic by using external finalizeRound
            // solhint-disable-next-line avoid-low-level-calls
            this.finalizeRound(roundId);
        } else {
            // revert with a generic error to avoid leaking timing logic
            revert ATG_FinalizationNotReady();
        }
    }

    // -------------------------------------------------------------------------
    // Views — handy for web UI + AchanAX simulator
    // -------------------------------------------------------------------------
    function getRoundView(uint256 roundId)
        external
        view
        returns (
            bool started,
            bool finalized,
            uint64 commitEndsAt,
            uint64 revealEndsAt,
            uint256 minDepositWei,
            uint16 winOddsBps,
            uint16 feeBps,
            uint32 maxEntries,
            bytes32 roundSalt,
            uint32 entryCount,
            uint256 totalPotWei,
            address bestWinner,
            uint16 bestRollBps,
            address winner,
            uint256 prizeWei,
            uint256 feeWei
        )
    {
        Round storage r = _rounds[roundId];
        return (
            r.started,
            r.finalized,
            r.commitEndsAt,
            r.revealEndsAt,
            r.minDepositWei,
            r.winOddsBps,
            r.feeBps,
            r.maxEntries,
            r.roundSalt,
            r.entryCount,
            r.totalPotWei,
            r.bestWinner,
            r.bestRollBps,
