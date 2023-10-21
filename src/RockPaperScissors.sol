// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/utils/Address.sol";

/// @notice These are all options a player can bet on.
enum Bet {
    Rock,
    Paper,
    Scissors
}

/// @notice Rock-Paper-Scissors game smart contract.
contract RockPaperScissors {
    using SafeERC20 for IERC20;

    event BetPlaced(address indexed player, bytes32 betHash);
    event BetRevealed(address indexed player, Bet indexed bet, bytes32 salt);
    event RoundCompleted(address indexed winner, Bet indexed player1Bet, Bet indexed player2Bet);
    event RoundCancelled(address indexed player1, address indexed player2);

    error AwaitingBets();
    error BettingDone();
    error Duplicate();
    error NotAPlayer();
    error CheatingDetected();
    error TooEarly();

    /// @notice A data struct to track the player address and their bet (hash). 
    struct Player {
        address addr; // Player's address
        bytes32 betHash; // Hash of player's bet
    }

    /// @notice Once the first player (who comes first to reveal) reveals their bet,
    /// we need to record it and wait for another player to determine a winner.
    struct RevealedBet {
        address addr; // Player's address
        Bet bet; // Player's revealed bet
    }

    IERC20 public immutable bettingToken;
    uint256 public immutable bettingAmount;
    uint256 public immutable roundTimeout;

    Player[] public players;

    RevealedBet public revealedBet;

    uint256 public lastTimestamp;

    /// @notice Please note that constructor does not contain any sanity checks.
    /// It is up to the contract users to ensure it was initialized with proper values.
    /// @param token IERC20 token used for betting
    /// @param amount Amount of tokens required for betting. A user must set enough allowance for this contract in advance.
    /// @param timeout Minimum amount of time (seconds) to be passed to consider a round as a stale one. Only then withrawals become possible.
    constructor(IERC20 token, uint256 amount, uint256 timeout) {
        bettingToken = token;
        bettingAmount = amount;
        roundTimeout = timeout;
    }

    /// @notice A user enters a game round by submitting hash of his bet.
    /// A user will be recorded as a player and `bettingAmount` of tokens will be transferred to this contract.
    /// It is important to give this contract enough allowance to enter the round.
    /// @param betHash a keccak256(bet, salt) hash of the bet.
    function placeBet(bytes32 betHash) external {
        if (players.length == 2) revert BettingDone();
        if (players.length == 1 && players[0].addr == msg.sender) revert Duplicate();

        Player memory player;
        player.addr = msg.sender;
        player.betHash = betHash;
        players.push(player);

        lastTimestamp = block.timestamp;

        bettingToken.safeTransferFrom(msg.sender, address(this), bettingAmount);

        emit BetPlaced(msg.sender, betHash);
    }

    /// @notice Once both players entered the round, they can reveal their bets.
    /// When first player reveals their bet, it will be recorded on the contract.
    /// When second player reveals their bet, the contract will detemine a winner and transfer a prize to them.
    /// If players try to cheat (supply bets that do not match previously stored hashes) this function reverts.
    /// @param bet A revealed bet.
    /// @param salt A salt used to create original hash. It is important to pass the same salt value as during betting phase!
    function revealBet(Bet bet, bytes32 salt) external {
        Player[] memory _players = players;

        if (_players.length < 2) revert AwaitingBets();
        if (revealedBet.addr == msg.sender) revert Duplicate();

        (Player memory player, uint256 index) = _findPlayer(msg.sender, _players);
        if (player.addr != msg.sender) revert NotAPlayer();

        if (!_checkHash(bet, salt, player.betHash)) revert CheatingDetected();

        emit BetRevealed(msg.sender, bet, salt);

        if (revealedBet.addr != address(0)) {
            // sort bets according to the players order
            Bet bet1;
            Bet bet2;
            if (index == 0) {
                // if a sender is the 1st player (#0)
                // then previously revealed bet is of 2nd player
                bet1 = bet;
                bet2 = revealedBet.bet;
            } else {
                bet1 = revealedBet.bet;
                bet2 = bet;
            }

            // we can safely cleanup the state now, as storage variables are not used anymore
            _cleanup();

            (bool isDraw, uint256 winnerIdx) = _determineWinner(bet1, bet2);
            if (isDraw) {
                // no winner - everyone gets his betting amount
                bettingToken.safeTransfer(_players[0].addr, bettingAmount);
                bettingToken.safeTransfer(_players[1].addr, bettingAmount);
                emit RoundCompleted(address(0), bet1, bet2);
            } else {
                // winner gets both shares
                bettingToken.safeTransfer(_players[winnerIdx - 1].addr, bettingAmount * 2);
                emit RoundCompleted(_players[winnerIdx - 1].addr, bet1, bet2);
            }
        } else {
            revealedBet.addr = msg.sender;
            revealedBet.bet = bet;
            lastTimestamp = block.timestamp;
        }
    }

    /// @notice If a second player didn't come for the `roundTimeout` period, then first player can withdraw own funds.
    /// Alternatively, if both players placed bets but one of them didn't reveal, then another one can withdraw all
    /// funds after `roundTimeout` seconds passed.
    function withdraw() external {
        if (lastTimestamp == 0 || block.timestamp < lastTimestamp + roundTimeout) revert TooEarly();

        Player[] memory _players = players;
        (Player memory player, ) = _findPlayer(msg.sender, _players);
        if (player.addr != msg.sender) revert NotAPlayer();

        // use case #1: only one player entered the round
        if (_players.length == 1) {
            bettingToken.safeTransfer(_players[0].addr, bettingAmount);
            emit RoundCancelled(_players[0].addr, address(0));
        } else {
            // use case #2: both entered the round, only one player revealed their bet
            // that player must already reveal their bet in order to withdraw
            if (revealedBet.addr != player.addr) revert CheatingDetected();
            bettingToken.safeTransfer(player.addr, bettingAmount * 2);
            
            emit RoundCancelled(_players[0].addr, _players[1].addr);
        }
 
        _cleanup();
    }

    /// @dev Wipes out players' info, their bets and resets timestamp.
    /// Must be called once game round is over. 
    function _cleanup() private {
        delete players;
        delete revealedBet;
        lastTimestamp = 0;
    }

    /// @dev Scans players array to find a match for a specified address.
    /// @param addr An address to find in the players array.
    /// @param players_ A players array to search within.
    /// @return player Player struct, if found. It is important to check if player.addr == addr before use.
    /// @return index zero-based index of player in players array. May be out of bounds if match not found.
    function _findPlayer(
        address addr,
        Player[] memory players_
    )
        private
        pure 
        returns (
            Player memory player,
            uint256 index
        )
    {
        while (index < players_.length) {
            if (players_[index].addr == addr) {
                player = players_[index];
                break;
            }

            index++;
        }
    }

    /// @dev A helper function to calculate hash. 
    function _checkHash(Bet bet, bytes32 salt, bytes32 hash) private pure returns (bool) {
        return keccak256(abi.encode(bet, salt)) == hash;
    }

    /// @notice Determines a winner by comparing players' bets.
    /// @param bet1 1st player's bet.
    /// @param bet2 2nd player's bet.
    /// @return isDraw `True` if both bets are the same.
    /// @return winner Ordinal (1-based) number of the winner, or zero if a draw. 
    function _determineWinner(Bet bet1, Bet bet2) private pure returns (bool isDraw, uint256 winner) {
        isDraw = bet1 == bet2;
       
        if (!isDraw) {
            if (bet1 == Bet.Rock) winner = bet2 == Bet.Paper ? 2 : 1;
            if (bet1 == Bet.Paper) winner = bet2 == Bet.Scissors ? 2 : 1;
            if (bet1 == Bet.Scissors) winner = bet2 == Bet.Rock ? 2 : 1;
        } else {
            winner = 0;
        }
    }
}
