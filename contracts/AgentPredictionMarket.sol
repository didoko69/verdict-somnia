// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    IAgentRequester,
    IAgentRequesterHandler,
    Response,
    Request,
    ResponseStatus
} from "./interfaces/IAgentRequester.sol";

/// @notice Callable interface of Somnia's JSON API Request base agent.
/// We only need it to derive the function selector for the agent payload.
interface IJsonApiAgent {
    function fetchUint(string calldata url, string calldata selector, uint8 decimals)
        external
        returns (uint256);
}

/// @title Verdict — agent-resolved prediction markets on Somnia
/// @notice Binary parimutuel markets that settle themselves. A market asks
///         "will <metric> be >= <target> at close?". After close, anyone can
///         trigger resolution: a Somnia Agent fetches the metric from a public
///         JSON endpoint, validators reach consensus on the value, and the
///         contract decides YES/NO and pays out — no human resolver, no
///         trusted oracle, an auditable receipt for every settlement.
contract AgentPredictionMarket is IAgentRequesterHandler {
    // --- Somnia Agents platform wiring -------------------------------------

    IAgentRequester public immutable platform;

    /// @dev JSON API Request base agent ID (from the Somnia developer guide).
    ///      Confirm the live ID for your network at https://agents.somnia.network
    uint256 public constant JSON_API_AGENT_ID = 13174292974160097713;

    /// @dev Platform default subcommittee size.
    uint256 public constant SUBCOMMITTEE_SIZE = 3;

    /// @dev Per-validator price of a JSON API call (STT). See docs → Gas Fees.
    uint256 public constant JSON_FETCH_COST_PER_AGENT = 0.03 ether;

    // --- Market data -------------------------------------------------------

    enum Outcome {
        Unresolved,
        Yes,
        No
    }

    struct Market {
        string question; // "Will BTC be >= $50k at close?"
        string url; // JSON endpoint the agent fetches
        string selector; // JSON-path selector, e.g. "bitcoin.usd"
        uint8 decimals; // fixed-point scaling the agent applies
        uint256 target; // YES if fetched value >= target (same decimals)
        uint64 closeTime; // betting ends / resolution allowed after this
        address creator;
        uint256 yesPool; // total STT staked YES
        uint256 noPool; // total STT staked NO
        Outcome outcome;
        uint256 resolvedValue; // value the agent returned
        bool resolving; // a resolve request is in flight
        bool resolved; // settled
    }

    uint256 public marketCount;
    mapping(uint256 => Market) public markets;
    mapping(uint256 => mapping(address => uint256)) public yesStake;
    mapping(uint256 => mapping(address => uint256)) public noStake;
    mapping(uint256 => mapping(address => bool)) public claimed;

    /// @dev agent requestId => marketId + 1 (so 0 means "no such request")
    mapping(uint256 => uint256) private requestToMarket;

    // --- Events ------------------------------------------------------------

    event MarketCreated(uint256 indexed marketId, string question, uint64 closeTime);
    event BetPlaced(uint256 indexed marketId, address indexed user, bool predictYes, uint256 amount);
    event ResolutionRequested(uint256 indexed marketId, uint256 indexed requestId);
    event MarketResolved(uint256 indexed marketId, Outcome outcome, uint256 resolvedValue);
    event ResolutionFailed(uint256 indexed marketId, uint256 indexed requestId, ResponseStatus status);
    event Claimed(uint256 indexed marketId, address indexed user, uint256 payout);

    constructor(address platform_) {
        platform = IAgentRequester(platform_);
    }

    // --- 1. Create a market ------------------------------------------------

    function createMarket(
        string calldata question,
        string calldata url,
        string calldata selector,
        uint8 decimals,
        uint256 target,
        uint64 closeTime
    ) external returns (uint256 marketId) {
        require(closeTime > block.timestamp, "close in past");
        marketId = ++marketCount;
        Market storage m = markets[marketId];
        m.question = question;
        m.url = url;
        m.selector = selector;
        m.decimals = decimals;
        m.target = target;
        m.closeTime = closeTime;
        m.creator = msg.sender;
        emit MarketCreated(marketId, question, closeTime);
    }

    // --- 2. Place a bet ----------------------------------------------------

    function bet(uint256 marketId, bool predictYes) external payable {
        Market storage m = markets[marketId];
        require(m.closeTime != 0, "no market");
        require(block.timestamp < m.closeTime, "betting closed");
        require(msg.value > 0, "no stake");

        if (predictYes) {
            m.yesPool += msg.value;
            yesStake[marketId][msg.sender] += msg.value;
        } else {
            m.noPool += msg.value;
            noStake[marketId][msg.sender] += msg.value;
        }
        emit BetPlaced(marketId, msg.sender, predictYes, msg.value);
    }

    // --- 3. Trigger agent resolution --------------------------------------
    // Payable: msg.value funds the agent call. Surplus above the required
    // deposit is refunded to the caller; unused budget is later rebated by
    // the platform to this contract via receive().

    function resolve(uint256 marketId) external payable returns (uint256 requestId) {
        Market storage m = markets[marketId];
        require(m.closeTime != 0, "no market");
        require(block.timestamp >= m.closeTime, "not closed yet");
        require(!m.resolved, "already resolved");
        require(!m.resolving, "resolution in flight");

        bytes memory payload =
            abi.encodeWithSelector(IJsonApiAgent.fetchUint.selector, m.url, m.selector, m.decimals);

        uint256 reserve = platform.getRequestDeposit(); // operations-reserve floor
        uint256 reward = JSON_FETCH_COST_PER_AGENT * SUBCOMMITTEE_SIZE; // agent reward pot
        uint256 deposit = reserve + reward;
        require(msg.value >= deposit, "underfunded resolve");

        m.resolving = true;

        requestId = platform.createRequest{value: deposit}(
            JSON_API_AGENT_ID, address(this), this.handleResponse.selector, payload
        );
        requestToMarket[requestId] = marketId + 1;

        if (msg.value > deposit) {
            (bool ok,) = msg.sender.call{value: msg.value - deposit}("");
            require(ok, "refund failed");
        }
        emit ResolutionRequested(marketId, requestId);
    }

    // --- 4. Agent callback -------------------------------------------------

    function handleResponse(
        uint256 requestId,
        Response[] memory responses,
        ResponseStatus status,
        Request memory /* details */
    ) external override {
        require(msg.sender == address(platform), "only platform");
        uint256 stored = requestToMarket[requestId];
        require(stored != 0, "unknown request");
        uint256 marketId = stored - 1;
        delete requestToMarket[requestId];

        Market storage m = markets[marketId];

        // On failure/timeout, clear the in-flight flag so resolve() can retry.
        if (status != ResponseStatus.Success || responses.length == 0) {
            m.resolving = false;
            emit ResolutionFailed(marketId, requestId, status);
            return;
        }

        uint256 value = abi.decode(responses[0].result, (uint256));
        m.resolvedValue = value;
        m.outcome = value >= m.target ? Outcome.Yes : Outcome.No;
        m.resolving = false;
        m.resolved = true;
        emit MarketResolved(marketId, m.outcome, value);
    }

    // --- 5. Claim winnings -------------------------------------------------
    // Parimutuel: winners get their own stake back plus a proportional share
    // of the losing pool. If nobody backed the winning side, every participant
    // can reclaim their own stake (void market).

    function claim(uint256 marketId) external {
        Market storage m = markets[marketId];
        require(m.resolved, "not resolved");
        require(!claimed[marketId][msg.sender], "already claimed");

        uint256 winningStake;
        uint256 winningPool;
        uint256 losingPool;

        if (m.outcome == Outcome.Yes) {
            winningStake = yesStake[marketId][msg.sender];
            winningPool = m.yesPool;
            losingPool = m.noPool;
        } else {
            winningStake = noStake[marketId][msg.sender];
            winningPool = m.noPool;
            losingPool = m.yesPool;
        }

        // Effects before interaction (reentrancy-safe).
        claimed[marketId][msg.sender] = true;

        uint256 payout;
        if (winningPool == 0) {
            // No winners: refund this caller's own stake on both sides.
            payout = yesStake[marketId][msg.sender] + noStake[marketId][msg.sender];
        } else {
            require(winningStake > 0, "not a winner");
            payout = winningStake + (winningStake * losingPool) / winningPool;
        }

        require(payout > 0, "nothing to claim");
        (bool ok,) = msg.sender.call{value: payout}("");
        require(ok, "payout failed");
        emit Claimed(marketId, msg.sender, payout);
    }

    // --- Views -------------------------------------------------------------

    function getMarket(uint256 marketId) external view returns (Market memory) {
        return markets[marketId];
    }

    /// @notice Convenience helper: the minimum msg.value to pass to resolve().
    function resolveDeposit() external view returns (uint256) {
        return platform.getRequestDeposit() + JSON_FETCH_COST_PER_AGENT * SUBCOMMITTEE_SIZE;
    }

    // Accept platform rebates of unused agent budget.
    receive() external payable {}
}
