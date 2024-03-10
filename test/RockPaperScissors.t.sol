// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";
import {RockPaperScissors, Bet } from "../contracts/RockPaperScissors.sol";

contract RockPaperScissorsTest is Test {
    address constant PLAYER_1 = address(0x1234);
    address constant PLAYER_2 = address(0x5678);

    uint256 constant BETTING_AMOUNT = 10 ether;
    uint256 constant ROUND_TIMEOUT = 1 days;

    // see a setUp() how results are initialized 
    mapping(Bet => mapping(Bet => uint256)) private outcomes;

    // we don't care if a `salt` is not random and the same for both users,
    // while it is not secure and thus disclose an actual bet,
    // this is acceptable for testing purposes
    bytes32 constant SALT = bytes32(keccak256("0x010203040506070809"));

    // without events redefined here I get a compilation error:
    // Internal exception in StandardCompiler::compile: C:\Users\circleci\project\libsolidity\interface\Natspec.cpp(89):
    //   Throw in function class Json::Value __cdecl solidity::frontend::Natspec::userDocumentation(const class solidity::frontend::ContractDefinition &)
    event BetPlaced(address indexed player, bytes32 betHash);
    event BetRevealed(address indexed player, Bet indexed bet, bytes32 salt);
    event RoundCompleted(address indexed winner, Bet indexed player1Bet, Bet indexed player2Bet);
    event RoundCancelled(address indexed player1, address indexed player2);

    ERC20Mock token;
    RockPaperScissors public rps;

    function setUp() public {
        // all possible outcomes
        outcomes[Bet.Rock][Bet.Rock] = 0;
        outcomes[Bet.Rock][Bet.Paper] = 2;
        outcomes[Bet.Rock][Bet.Scissors] = 1;
        outcomes[Bet.Paper][Bet.Rock] = 1;
        outcomes[Bet.Paper][Bet.Paper] = 0;
        outcomes[Bet.Paper][Bet.Scissors] = 2;
        outcomes[Bet.Scissors][Bet.Rock] = 2;
        outcomes[Bet.Scissors][Bet.Paper] = 1;
        outcomes[Bet.Scissors][Bet.Scissors] = 0;

        token = new ERC20Mock();
        rps = new RockPaperScissors(token, BETTING_AMOUNT, ROUND_TIMEOUT);

        token.mint(PLAYER_1, 1000 ether);
        token.mint(PLAYER_2, 2000 ether);

        // pre-approve tokens to simplify tests
        vm.prank(PLAYER_1);
        token.approve(address(rps), 1000 ether);
        vm.prank(PLAYER_2);
        token.approve(address(rps), 1000 ether);
    }

    function test_initializedProperly() public {
        assertEq(address(rps.bettingToken()), address(token), "token not set");
        assertEq(rps.bettingAmount(), BETTING_AMOUNT, "bettingAmount not set");
        assertEq(rps.roundTimeout(), ROUND_TIMEOUT, "roundTimeout not set");
    }

    /// note: Foundry can't deal with enums so we have to use uint256 as an input type for fuzzer 
    function test_winnerDeterminationLogic(uint256 ubet1, uint256 ubet2) public {
        vm.assume(uint256(ubet1) < 3 && uint256(ubet2) < 3);

        (uint256 idx, ) = _runRound(Bet(ubet1), Bet(ubet2));
        assertEq(idx, outcomes[Bet(ubet1)][Bet(ubet2)], "outcome fail");
    }

    function test_placeBettingAndReveal(uint256 ubet1, uint256 ubet2, bool invertRevealOrder) public {
        vm.assume(uint256(ubet1) < 3 && uint256(ubet2) < 3);

        Bet bet1 = Bet(ubet1);
        Bet bet2 = Bet(ubet2);

        // initial balances
        uint256 balance1 = token.balanceOf(PLAYER_1);
        uint256 balance2 = token.balanceOf(PLAYER_2);

        /** placing bets */

        vm.expectEmit();
        emit BetPlaced(PLAYER_1, _hash(bet1, SALT));

        // player 1 can place a bet
        vm.prank(PLAYER_1);
        rps.placeBet(_hash(bet1, SALT));
        (address addr, bytes32 hash) = rps.players(0);
        assertEq(addr, PLAYER_1, "Player address not set");
        assertEq(hash, _hash(bet1, SALT), "Player bet hash not set");

        // tokens transferred from player 1 (player's balance updated correctly)
        assertEq(token.balanceOf(PLAYER_1), balance1 - BETTING_AMOUNT, "player balance is incorrect");

        // must be only one element in players array
        vm.expectRevert();
        rps.players(1);

        // player 1 cannot place duplicate bet
        vm.prank(PLAYER_1);
        vm.expectRevert(RockPaperScissors.Duplicate.selector);
        rps.placeBet(_hash(Bet.Rock, SALT));     

        // cannot reveal bet if a second player did not place the bet yet
        vm.expectRevert(RockPaperScissors.AwaitingBets.selector);
        rps.revealBet(bet1, SALT);

        // player 2 can place a bet
        vm.prank(PLAYER_2);
        vm.expectEmit();
        emit BetPlaced(PLAYER_2, _hash(bet2, SALT));
        rps.placeBet(_hash(bet2, SALT));
        (addr, hash) = rps.players(1);
        assertEq(addr, PLAYER_2, "Player address not set");
        assertEq(hash, _hash(bet2, SALT), "Player bet hash not set");

        // tokens transferred from player 2 (player's balance updated correctly)
        assertEq(token.balanceOf(PLAYER_2), balance2 - BETTING_AMOUNT, "player balance is incorrect");

        // must be only two elements in players array
        vm.expectRevert();
        rps.players(2);

        // player 2 cannot place duplicate bet (BettingDone error is expected)
        vm.prank(PLAYER_2);
        vm.expectRevert(RockPaperScissors.BettingDone.selector);
        rps.placeBet(_hash(Bet.Rock, SALT));

        // player 3 cannot place bet (BettingDone error is expected)
        vm.prank(address(0x0101));
        vm.expectRevert(RockPaperScissors.BettingDone.selector);
        rps.placeBet(_hash(Bet.Rock, SALT));  

        // last action timestamp needs to be recorded
        assertEq(rps.lastTimestamp(), block.timestamp, "lastTimestamp is not set");

        // contract's token balance must be correct
        assertEq(token.balanceOf(address(rps)), BETTING_AMOUNT * 2, "contract balance is incorrect");

        /** revealing bets */

        // move timestamp for testing purposes
        vm.warp(10);

        // cannot reveal if didn't place a bet
        vm.prank(address(0x0101));
        vm.expectRevert(RockPaperScissors.NotAPlayer.selector);
        rps.revealBet(bet1, SALT);

        // cannot cheat and put not matching bet during reveal 
        vm.prank(PLAYER_1);
        vm.expectRevert(RockPaperScissors.CheatingDetected.selector);
        rps.revealBet(bet1 == Bet.Rock ? Bet.Paper : Bet.Rock, SALT);

        address player1 = PLAYER_1;
        address player2 = PLAYER_2;
        Bet bet1r = bet1;
        Bet bet2r = bet2;

        if (invertRevealOrder) {
            player1 = PLAYER_2;
            player2 = PLAYER_1;
            bet1r = bet2;
            bet2r = bet1;
        }

        // player1 reveals his bet
        vm.startPrank(player1);
        vm.expectEmit();
        emit BetRevealed(player1, bet1r, SALT);
        rps.revealBet(bet1r, SALT);

        Bet bet = bet2r;
        (addr, bet) = rps.revealedBet();
        assertEq(addr, player1, "revealedBet.addr is not set");
        assertEq(uint256(bet), uint256(bet1r), "revealedBet.bet is not set");
        assertEq(rps.lastTimestamp(), 10, "lastTimestamp is not set");

        vm.expectRevert(RockPaperScissors.Duplicate.selector);
        rps.revealBet(bet1r, SALT);
        vm.stopPrank();

        // player2 reveals his bet
        vm.startPrank(player2);

        vm.expectEmit();
        emit BetRevealed(player2, bet2r, SALT);

        vm.expectEmit(false, true, true, true);
        emit RoundCompleted(player2, bet1, bet2);

        rps.revealBet(bet2r, SALT);
        vm.stopPrank();

        /** after both players revealed, the round is done */

        // state must be cleaned up
        (addr, bet) = rps.revealedBet();
        assertEq(addr, address(0), "lastTimestamp is not cleaned up");
        assertEq(uint256(bet), uint256(0), "revealedBet.bet is not cleaned up");
        assertEq(rps.lastTimestamp(), 0, "lastTimestamp is not cleaned up");
        vm.expectRevert(); // empty players array
        rps.players(0);

        uint256 bal1final = balance1;
        uint256 bal2final = balance2;

        // get winnder and his expected balance
        if (_getOutcome(bet1, bet2) != 0) {
            if (_getOutcome(bet1, bet2) == 1) {
                bal1final = balance1 + BETTING_AMOUNT;
                bal2final = balance2 - BETTING_AMOUNT;
            } else {
                bal1final = balance1 - BETTING_AMOUNT;
                bal2final = balance2 + BETTING_AMOUNT;
            }
        }

        assertEq(token.balanceOf(PLAYER_1), bal1final, "incorrect final balance of player 1");
        assertEq(token.balanceOf(PLAYER_2), bal2final, "incorrect final balance of player 2");
        assertEq(token.balanceOf(address(rps)), 0, "incorrect final balance of the contract");
    }

    function test_withdrawal_BettingPhase(uint256 ubet1) public {
        vm.assume(uint256(ubet1) < 3);

        Bet bet1 = Bet(ubet1);

        // initial balance
        uint256 balance1 = token.balanceOf(PLAYER_1);

        // no one placed a bet
        vm.expectRevert(RockPaperScissors.TooEarly.selector);
        rps.withdraw();

        vm.prank(PLAYER_1);
        rps.placeBet(_hash(bet1, SALT));

        // time hasn't passed yet
        vm.prank(PLAYER_1);
        vm.expectRevert(RockPaperScissors.TooEarly.selector);
        rps.withdraw();

        vm.warp(ROUND_TIMEOUT + 1); // moving timestamp so withdrawal is possible now

        // only players can withdraw
        vm.prank(PLAYER_2);
        vm.expectRevert(RockPaperScissors.NotAPlayer.selector);
        rps.withdraw();

        // withdrawn successfully
        vm.prank(PLAYER_1);
        vm.expectEmit(true, true, true, true);
        emit RoundCancelled(PLAYER_1, address(0));
        rps.withdraw();

        assertEq(token.balanceOf(PLAYER_1), balance1, "Incorrect player balance after withdraw");
        assertEq(token.balanceOf(address(rps)), 0, "Incorrect contract balance after withdraw");

        // clean up was run
        assertEq(rps.lastTimestamp(), 0, "lastTimestamp is not cleaned up");
        vm.expectRevert(); // empty players array
        rps.players(0);
    }

    function test_withdrawal_RevealingPhase(uint256 ubet1, uint256 ubet2) public {
        vm.assume(uint256(ubet1) < 3 && uint256(ubet2) < 3);

        Bet bet1 = Bet(ubet1);
        Bet bet2 = Bet(ubet2);

        // initial balances
        uint256 balance1 = token.balanceOf(PLAYER_1);
        uint256 balance2 = token.balanceOf(PLAYER_2);

        vm.prank(PLAYER_1);
        rps.placeBet(_hash(bet1, SALT));

        vm.prank(PLAYER_2);
        rps.placeBet(_hash(bet2, SALT));

        vm.prank(PLAYER_2);
        vm.expectRevert(RockPaperScissors.TooEarly.selector);
        rps.withdraw();

        vm.warp(ROUND_TIMEOUT + 1); // moving timestamp over round timeout

        // no one revealed hence it is not possible to withdraw
        vm.prank(PLAYER_1);
        vm.expectRevert(RockPaperScissors.CheatingDetected.selector);
        rps.withdraw();

        vm.prank(PLAYER_2);
        vm.expectRevert(RockPaperScissors.CheatingDetected.selector);
        rps.withdraw();

        // one player reveals
        vm.prank(PLAYER_1);
        rps.revealBet(bet1, SALT);

        // time not passed after reveal hence it is not possible to withdraw
        vm.prank(PLAYER_1);
        vm.expectRevert(RockPaperScissors.TooEarly.selector);
        rps.withdraw();

        vm.prank(PLAYER_2);
        vm.expectRevert(RockPaperScissors.TooEarly.selector);
        rps.withdraw();       

        vm.warp(ROUND_TIMEOUT * 2 + 1); // moving timestamp over round timeout more

        // player 1 revealed hence player 2 cannot  withdraw
        vm.prank(PLAYER_2);
        vm.expectRevert(RockPaperScissors.CheatingDetected.selector);
        rps.withdraw();

        // finally, can withdraw
        vm.prank(PLAYER_1);
        vm.expectEmit(true, true, true, true);
        emit RoundCancelled(PLAYER_1, PLAYER_2);
        rps.withdraw();

        assertEq(token.balanceOf(PLAYER_1), balance1 + BETTING_AMOUNT, "Incorrect player 1 balance after withdraw");
        assertEq(token.balanceOf(PLAYER_2), balance2 - BETTING_AMOUNT, "Incorrect player 2 balance after withdraw");
        assertEq(token.balanceOf(address(rps)), 0, "Incorrect contract balance after withdraw");

        // clean up was run
        assertEq(rps.lastTimestamp(), 0, "lastTimestamp is not cleaned up");
        vm.expectRevert(); // empty players array
        rps.players(0);
    }

    /// @dev Utility function for testing the logic of complete round.
    function _runRound(Bet player1Bet, Bet player2Bet) private returns (uint256, address) {
        uint256 balance1 = token.balanceOf(PLAYER_1);
        uint256 balance2 = token.balanceOf(PLAYER_2);

        bytes32 salt1 = bytes32(keccak256(abi.encodePacked(block.timestamp)));
        bytes32 salt2 = bytes32(keccak256(abi.encodePacked(block.timestamp + 1)));
        
        vm.prank(PLAYER_1);
        rps.placeBet(_hash(player1Bet, salt1));

        vm.prank(PLAYER_2);
        rps.placeBet(_hash(player2Bet, salt2));

        vm.prank(PLAYER_1);
        rps.revealBet(player1Bet, salt1);

        vm.prank(PLAYER_2);
        rps.revealBet(player2Bet, salt2);       

        // determine winner based on the balance increase
        if (token.balanceOf(PLAYER_1) > balance1) {
            return (1, PLAYER_1);
        } else if (token.balanceOf(PLAYER_2) > balance2) {
            return (2, PLAYER_2);
        } else {
            return (0, address(0)); // a draw
        }
    }

    /// @dev Calculates hash of the bet.
    function _hash(Bet bet, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(bet, salt));
    }

    /// @dev Only reason to wrap this in a function is 'Stack too deep' error.
    function _getOutcome(Bet bet1, Bet bet2) private view returns (uint256) {
        return outcomes[bet1][bet2];
    }
}
