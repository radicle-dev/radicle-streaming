// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {console} from "forge-std/Script.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";

/// @dev The singleton factory for deterministic deployment.
/// Deployed by Safe, addresses taken from https://github.com/safe-global/safe-singleton-factory.
address constant SINGLETON_FACTORY = 0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7;

function deployCreate3Factory() returns (ICreate3Factory deployment) {
    deployment = ICreate3Factory(0xe9BE461efaB6f9079741da3b180249F81e66A461);
    if (Address.isContract(address(deployment))) {
        console.log("Create3Factory already deployed");
        return deployment;
    }

    /// @notice The creation code of Create3Factory.
    /// It's reused verbatim to keep it byte-for-byte identical across all deployments and chains,
    /// so the Safe singleton factory always deploys it under the same address
    /// regardless of the currently used compiler version and configuration.
    /// Taken from https://github.com/ZeframLou/create3-factory,
    /// originally deployed on Ethereum as `0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf`
    /// in transaction `0xb05de371a18fc4f02753b34a689939cee69b93a043b926732043780959b7c4e3`.
    bytes memory creationCode =
        hex"608060405234801561001057600080fd5b5061063b806100206000396000f3fe6080604052600436106100"
        hex"295760003560e01c806350f1c4641461002e578063cdcb760a14610077575b600080fd5b34801561003a57"
        hex"600080fd5b5061004e610049366004610489565b61008a565b60405173ffffffffffffffffffffffffffff"
        hex"ffffffffffff909116815260200160405180910390f35b61004e6100853660046104fd565b6100ee565b60"
        hex"40517fffffffffffffffffffffffffffffffffffffffff000000000000000000000000606084901b166020"
        hex"820152603481018290526000906054016040516020818303038152906040528051906020012091506100e7"
        hex"8261014c565b9392505050565b6040517fffffffffffffffffffffffffffffffffffffffff000000000000"
        hex"0000000000003360601b166020820152603481018390526000906054016040516020818303038152906040"
        hex"528051906020012092506100e78383346102b2565b604080518082018252601081527f67363d3d37363d34"
        hex"f03d5260086018f30000000000000000000000000000000060209182015290517fff000000000000000000"
        hex"00000000000000000000000000000000000000000000918101919091527fffffffffffffffffffffffffff"
        hex"ffffffffffffff0000000000000000000000003060601b166021820152603581018290527f21c35dbe1b34"
        hex"4a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f6055820152600090819061022890607501"
        hex"5b6040516020818303038152906040528051906020012090565b6040517fd6940000000000000000000000"
        hex"0000000000000000000000000000000000000060208201527fffffffffffffffffffffffffffffffffffff"
        hex"ffff000000000000000000000000606083901b1660228201527f0100000000000000000000000000000000"
        hex"00000000000000000000000000000060368201529091506100e79060370161020f565b6000806040518060"
        hex"400160405280601081526020017f67363d3d37363d34f03d5260086018f300000000000000000000000000"
        hex"00000081525090506000858251602084016000f5905073ffffffffffffffffffffffffffffffffffffffff"
        hex"811661037d576040517f08c379a00000000000000000000000000000000000000000000000000000000081"
        hex"5260206004820152601160248201527f4445504c4f594d454e545f4641494c454400000000000000000000"
        hex"000000000060448201526064015b60405180910390fd5b6103868661014c565b925060008173ffffffffff"
        hex"ffffffffffffffffffffffffffffff1685876040516103b091906105d6565b60006040518083038185875a"
        hex"f1925050503d80600081146103ed576040519150601f19603f3d011682016040523d82523d600060208401"
        hex"3e6103f2565b606091505b50509050808015610419575073ffffffffffffffffffffffffffffffffffffff"
        hex"ff84163b15155b61047f576040517f08c379a0000000000000000000000000000000000000000000000000"
        hex"00000000815260206004820152601560248201527f494e495449414c495a4154494f4e5f4641494c454400"
        hex"000000000000000000006044820152606401610374565b5050509392505050565b60008060408385031215"
        hex"61049c57600080fd5b823573ffffffffffffffffffffffffffffffffffffffff811681146104c057600080"
        hex"fd5b946020939093013593505050565b7f4e487b7100000000000000000000000000000000000000000000"
        hex"000000000000600052604160045260246000fd5b6000806040838503121561051057600080fd5b82359150"
        hex"602083013567ffffffffffffffff8082111561052f57600080fd5b818501915085601f8301126105435760"
        hex"0080fd5b813581811115610555576105556104ce565b604051601f82017fffffffffffffffffffffffffff"
        hex"ffffffffffffffffffffffffffffffffffffe0908116603f0116810190838211818310171561059b576105"
        hex"9b6104ce565b816040528281528860208487010111156105b457600080fd5b826020860160208301376000"
        hex"6020848301015280955050505050509250929050565b6000825160005b818110156105f757602081860181"
        hex"015185830152016105dd565b50600092019182525091905056fea2646970667358221220fd377c185926b3"
        hex"110b7e8a544f897646caf36a0e82b2629de851045e2a5f937764736f6c63430008100033";
    bytes32 salt = 0;
    require(Address.isContract(SINGLETON_FACTORY), "Singleton factory not deployed");
    bytes memory addr = Address.functionCall(
        SINGLETON_FACTORY, bytes.concat(salt, creationCode), "Create3Factory deployment failed"
    );
    require(address(bytes20(addr)) == address(deployment), "Invalid Create3Factory address");
}

/// @title Factory for deploying contracts to deterministic addresses via CREATE3.
/// @author zefram.eth, taken from https://github.com/ZeframLou/create3-factory.
/// @notice Enables deploying contracts using CREATE3.
/// Each deployer (`msg.sender`) has its own namespace for deployed addresses.
interface ICreate3Factory {
    /// @notice Deploys a contract using CREATE3.
    /// @dev The provided salt is hashed together with msg.sender to generate the final salt.
    /// @param salt The deployer-specific salt for determining the deployed contract's address.
    /// @param creationCode The creation code of the contract to deploy.
    /// @return deployed The address of the deployed contract.
    function deploy(bytes32 salt, bytes memory creationCode)
        external
        payable
        returns (address deployed);

    /// @notice Predicts the address of a deployed contract.
    /// @dev The provided salt is hashed together
    /// with the deployer address to generate the final salt.
    /// @param deployer The deployer account that will call `deploy()`.
    /// @param salt The deployer-specific salt for determining the deployed contract's address.
    /// @return deployed The address of the contract that will be deployed.
    function getDeployed(address deployer, bytes32 salt) external view returns (address deployed);
}
