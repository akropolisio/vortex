// SPDX-License-Identifier: AGPL V3.0
pragma solidity 0.8.4;

import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IStrategy.sol";

contract KeeperManager is Ownable, Pausable {
    address public strategy;
    uint256 public cooldown;
    uint256 public lastTimestamp;


    event CooldownSet(uint256 cooldown);
    event StrategySet(address indexed strategy);

    constructor(address _strategy, uint256 _cooldown) {
        strategy = _strategy;
        cooldown = _cooldown;
    }

    function setStrategy(address _strategy) public onlyOwner {
        strategy = _strategy;
        emit StrategySet(_strategy);
    }

    function setCoolDown(uint256 _cooldown) public onlyOwner {
        cooldown = _cooldown;
        emit CooldownSet(_cooldown);
    }

    function checkUpkeep(bytes calldata /* checkData */) external returns (bool upkeepNeeded, bytes memory /* performData */) {
        upkeepNeeded = (block.timestamp - lastTimestamp) > cooldown;
    }

    function performUpkeep(bytes calldata /* performData */) external  {
        require((block.timestamp - lastTimestamp) > cooldown, "harvest not needed");
        lastTimestamp = block.timestamp;
        IStrategy(strategy).harvest();
    }

}
