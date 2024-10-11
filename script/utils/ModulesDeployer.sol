// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {ICreate3Factory} from "script/utils/Create3Factory.sol";
import {Ownable2Step} from "openzeppelin-contracts/access/Ownable2Step.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";

struct ModuleData {
    bytes32 salt;
    bytes initCode;
    uint256 value;
}

function deployModulesDeployer(ICreate3Factory create3Factory, bytes32 salt, address owner)
    returns (ModulesDeployer deployment)
{
    bytes memory args = abi.encode(create3Factory, owner);
    bytes memory creationCode = abi.encodePacked(type(ModulesDeployer).creationCode, args);
    address modulesDeployer = create3Factory.deploy(salt, creationCode);
    return ModulesDeployer(payable(modulesDeployer));
}

contract ModulesDeployer is Ownable2Step {
    ICreate3Factory public immutable create3Factory;

    constructor(ICreate3Factory create3Factory_, address owner) {
        create3Factory = create3Factory_;
        _transferOwnership(owner);
    }

    receive() external payable {}

    function deployModules(ModuleData[] calldata modules) public payable onlyOwner {
        for (uint256 i = 0; i < modules.length; i++) {
            ModuleData calldata module_ = modules[i];
            // slither-disable-next-line reentrancy-eth,reentrancy-no-eth
            create3Factory.deploy{value: module_.value}(module_.salt, module_.initCode);
        }
    }

    function module(bytes32 salt) public view returns (address addr) {
        return create3Factory.getDeployed(address(this), salt);
    }
}

function isModuleDeployed(ModulesDeployer modulesDeployer, bytes32 salt) view returns (bool yes) {
    address module = modulesDeployer.module(salt);
    return Address.isContract(module);
}

function getModule(ModulesDeployer modulesDeployer, bytes32 salt) view returns (address module) {
    module = modulesDeployer.module(salt);
    require(Address.isContract(module), string.concat(string(bytes.concat(salt)), " not deployed"));
}

abstract contract Module {
    ModulesDeployer internal immutable _modulesDeployer;

    constructor(ModulesDeployer modulesDeployer, bytes32 moduleSalt) {
        _modulesDeployer = modulesDeployer;
        require(address(this) == modulesDeployer.module(moduleSalt), "Invalid module salt");
    }

    modifier onlyModule(bytes32 senderSalt) {
        require(msg.sender == _modulesDeployer.module(senderSalt), "Callable only by a module");
        _;
    }
}
