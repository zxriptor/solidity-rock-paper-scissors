# Rock-Paper-Scissors Game

**This is (yet another one) implementation of Rock-Paper-Scissors game in Solidity language.**

### Features:

- Two players, anyone can participate.
- Unlimited number of rounds (one round at a time).
- Bidding with ERC20 tokens.
- Time-locked funds withdrawal option (in case another player is unwilling to participate).
- Emitting events and throwing errors on reverts.

### Non-Functional Features:

- Well-documented and well-formatted code.
- Foundry tests (almost 100% test coverage).
- This awesome readme file.

### Usage

#### Build

```shell
$ forge build
```

#### Test

```shell
$ forge test
```

#### Deploy

```shell
$ forge script script/RockPaperScissors.s.sol:RockPaperScissorsScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

#### Credits
https://github.com/zxriptor
