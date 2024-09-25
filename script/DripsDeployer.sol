// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {AddressDriver} from "src/AddressDriver.sol";
import {
    AxelarBridgedGovernor,
    Call,
    Governor,
    GovernorProxy,
    IAxelarGMPGateway,
    LZBridgedGovernor
} from "src/BridgedGovernor.sol";
import {Caller} from "src/Caller.sol";
import {Drips} from "src/Drips.sol";
import {GiversRegistry} from "src/Giver.sol";
import {ImmutableSplitsDriver} from "src/ImmutableSplitsDriver.sol";
import {IWrappedNativeToken} from "src/IWrappedNativeToken.sol";
import {Managed, ManagedProxy} from "src/Managed.sol";
import {NativeTokenUnwrapper} from "src/NativeTokenUnwrapper.sol";
import {NFTDriver} from "src/NFTDriver.sol";
import {IAutomate, RepoDriver} from "src/RepoDriver.sol";
import {Ownable2Step} from "openzeppelin-contracts/access/Ownable2Step.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";

struct ModuleData {
    bytes32 salt;
    bytes initCode;
    uint256 value;
}

function dripsDeployerCreationCode(ICreate3Factory create3Factory, address owner)
    pure
    returns (bytes memory creationCode)
{
    bytes memory args = abi.encode(create3Factory, owner);
    return abi.encodePacked(type(DripsDeployer).creationCode, args);
}

contract DripsDeployer is Ownable2Step {
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

function create3ManagedProxy(
    DripsDeployer dripsDeployer,
    bytes32 salt,
    Managed logic,
    address admin,
    bytes memory data
) returns (address proxy) {
    bytes memory args = abi.encode(logic, admin, data);
    // slither-disable-next-line too-many-digits
    return create3(dripsDeployer, salt, type(ManagedProxy).creationCode, args);
}

function create3GovernorProxy(DripsDeployer dripsDeployer, bytes32 salt, Governor logic)
    returns (address proxy)
{
    bytes memory args = abi.encode(logic, new Call[](0));
    // slither-disable-next-line too-many-digits
    return create3(dripsDeployer, salt, type(GovernorProxy).creationCode, args);
}

function create3(
    DripsDeployer dripsDeployer,
    bytes32 salt,
    bytes memory creationCode,
    bytes memory args
) returns (address deployment) {
    return dripsDeployer.create3Factory().deploy(salt, abi.encodePacked(creationCode, args));
}

function findModule(DripsDeployer dripsDeployer, bytes32 salt) view returns (address module) {
    module = dripsDeployer.module(salt);
    if (!Address.isContract(module)) {
        // Cast the salt to a string
        uint256 length = 0;
        while (length < 32 && salt[length] != 0) length++;
        bytes memory name = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            name[i] = salt[i];
        }
        revert(string.concat(string(name), " not deployed"));
    }
}

abstract contract Module {
    DripsDeployer internal immutable _dripsDeployer;

    constructor(DripsDeployer dripsDeployer, bytes32 moduleSalt) {
        _dripsDeployer = dripsDeployer;
        require(address(this) == dripsDeployer.module(moduleSalt), "Invalid module salt");
    }

    modifier onlyModule(bytes32 senderSalt) {
        require(msg.sender == _dripsDeployer.module(senderSalt), "Callable only by a module");
        _;
    }
}

bytes32 constant LZ_BRIDGED_GOVERNOR_MODULE_SALT = "LZBridgedGovernorModule";

function lzBridgedGovernorModule(DripsDeployer dripsDeployer)
    view
    returns (LZBridgedGovernorModule)
{
    return LZBridgedGovernorModule(findModule(dripsDeployer, LZ_BRIDGED_GOVERNOR_MODULE_SALT));
}

function lzBridgedGovernorModuleData(
    DripsDeployer dripsDeployer,
    address endpoint,
    uint32 ownerEid,
    bytes32 owner
) pure returns (ModuleData memory) {
    bytes memory args = abi.encode(dripsDeployer, endpoint, ownerEid, owner);
    return ModuleData({
        salt: LZ_BRIDGED_GOVERNOR_MODULE_SALT,
        initCode: abi.encodePacked(type(LZBridgedGovernorModule).creationCode, args),
        value: 0
    });
}

contract LZBridgedGovernorModule is Module {
    LZBridgedGovernor public immutable lzBridgedGovernor;

    constructor(DripsDeployer dripsDeployer, address endpoint, uint32 ownerEid, bytes32 owner)
        Module(dripsDeployer, LZ_BRIDGED_GOVERNOR_MODULE_SALT)
    {
        LZBridgedGovernor logic = new LZBridgedGovernor(endpoint, ownerEid, owner);
        address proxy = create3GovernorProxy(dripsDeployer, "LZBridgedGovernor", logic);
        lzBridgedGovernor = LZBridgedGovernor(payable(proxy));
    }
}

bytes32 constant AXELAR_BRIDGED_GOVERNOR_MODULE_SALT = "AxelarBridgedGovernorModule";

function axelarBridgedGovernorModule(DripsDeployer dripsDeployer)
    view
    returns (AxelarBridgedGovernorModule)
{
    return
        AxelarBridgedGovernorModule(findModule(dripsDeployer, AXELAR_BRIDGED_GOVERNOR_MODULE_SALT));
}

function axelarBridgedGovernorModuleData(
    DripsDeployer dripsDeployer,
    IAxelarGMPGateway gateway,
    string memory ownerChain,
    address owner
) pure returns (ModuleData memory) {
    bytes memory args = abi.encode(dripsDeployer, gateway, ownerChain, owner);
    return ModuleData({
        salt: AXELAR_BRIDGED_GOVERNOR_MODULE_SALT,
        initCode: abi.encodePacked(type(AxelarBridgedGovernorModule).creationCode, args),
        value: 0
    });
}

contract AxelarBridgedGovernorModule is Module {
    AxelarBridgedGovernor public immutable axelarBridgedGovernor;

    constructor(
        DripsDeployer dripsDeployer,
        IAxelarGMPGateway gateway,
        string memory ownerChain,
        address owner
    ) Module(dripsDeployer, AXELAR_BRIDGED_GOVERNOR_MODULE_SALT) {
        AxelarBridgedGovernor logic = new AxelarBridgedGovernor(gateway, ownerChain, owner);
        address proxy = create3GovernorProxy(dripsDeployer, "AxelarBridgedGovernor", logic);
        axelarBridgedGovernor = AxelarBridgedGovernor(payable(proxy));
    }
}

bytes32 constant DRIPS_MODULE_SALT = "DripsModule";

function dripsModule(DripsDeployer dripsDeployer) view returns (DripsModule) {
    return DripsModule(findModule(dripsDeployer, DRIPS_MODULE_SALT));
}

function dripsModuleData(DripsDeployer dripsDeployer, uint32 dripsCycleSecs, address admin)
    pure
    returns (ModuleData memory)
{
    bytes memory args = abi.encode(dripsDeployer, dripsCycleSecs, admin);
    return ModuleData({
        salt: DRIPS_MODULE_SALT,
        initCode: abi.encodePacked(type(DripsModule).creationCode, args),
        value: 0
    });
}

contract DripsModule is Module {
    Drips public immutable drips;

    constructor(DripsDeployer dripsDeployer, uint32 dripsCycleSecs, address admin)
        Module(dripsDeployer, DRIPS_MODULE_SALT)
    {
        Drips logic = new Drips(dripsCycleSecs);
        address proxy = create3ManagedProxy(dripsDeployer, "Drips", logic, admin, "");
        drips = Drips(proxy);
        for (uint256 i = 0; i < 100; i++) {
            // slither-disable-next-line calls-loop,unused-return
            drips.registerDriver(address(this));
        }
    }

    function claimDriverId(bytes32 senderSalt, uint32 driverId, address driver) public {
        require(msg.sender == _dripsDeployer.module(senderSalt));
        drips.updateDriverAddress(driverId, driver);
    }
}

bytes32 constant CALLER_MODULE_SALT = "CallerModule";

function callerModule(DripsDeployer dripsDeployer) view returns (CallerModule) {
    return CallerModule(findModule(dripsDeployer, CALLER_MODULE_SALT));
}

function callerModuleData(DripsDeployer dripsDeployer) pure returns (ModuleData memory) {
    bytes memory args = abi.encode(dripsDeployer);
    return ModuleData({
        salt: CALLER_MODULE_SALT,
        initCode: abi.encodePacked(type(CallerModule).creationCode, args),
        value: 0
    });
}

contract CallerModule is Module {
    Caller public immutable caller;

    constructor(DripsDeployer dripsDeployer) Module(dripsDeployer, CALLER_MODULE_SALT) {
        // slither-disable-next-line too-many-digits
        caller = Caller(create3(dripsDeployer, "Caller", type(Caller).creationCode, ""));
    }
}

bytes32 constant NATIVE_TOKEN_UNWRAPPER_MODULE_SALT = "NativeTokenUnwrapperModule";

function nativeTokenUnwrapperModule(DripsDeployer dripsDeployer)
    view
    returns (NativeTokenUnwrapperModule)
{
    return NativeTokenUnwrapperModule(findModule(dripsDeployer, NATIVE_TOKEN_UNWRAPPER_MODULE_SALT));
}

function nativeTokenUnwrapperModuleData(
    DripsDeployer dripsDeployer,
    IWrappedNativeToken wrappedNativeToken
) pure returns (ModuleData memory) {
    bytes memory args = abi.encode(dripsDeployer, wrappedNativeToken);
    return ModuleData({
        salt: NATIVE_TOKEN_UNWRAPPER_MODULE_SALT,
        initCode: abi.encodePacked(type(NativeTokenUnwrapperModule).creationCode, args),
        value: 0
    });
}

contract NativeTokenUnwrapperModule is Module {
    NativeTokenUnwrapper public immutable nativeTokenUnwrapper;

    constructor(DripsDeployer dripsDeployer, IWrappedNativeToken wrappedNativeToken)
        Module(dripsDeployer, NATIVE_TOKEN_UNWRAPPER_MODULE_SALT)
    {
        bytes memory args = abi.encode(wrappedNativeToken);
        // slither-disable-next-line too-many-digits
        address deployment = create3(
            dripsDeployer, "NativeTokenUnwrapper", type(NativeTokenUnwrapper).creationCode, args
        );
        nativeTokenUnwrapper = NativeTokenUnwrapper(payable(deployment));
    }
}

bytes32 constant ADDRESS_DRIVER_MODULE_SALT = "AddressDriverModule";

function addressDriverModule(DripsDeployer dripsDeployer) view returns (AddressDriverModule) {
    return AddressDriverModule(findModule(dripsDeployer, ADDRESS_DRIVER_MODULE_SALT));
}

function addressDriverModuleData(DripsDeployer dripsDeployer, address admin)
    pure
    returns (ModuleData memory)
{
    bytes memory args = abi.encode(dripsDeployer, admin);
    return ModuleData({
        salt: ADDRESS_DRIVER_MODULE_SALT,
        initCode: abi.encodePacked(type(AddressDriverModule).creationCode, args),
        value: 0
    });
}

contract AddressDriverModule is Module {
    AddressDriver public immutable addressDriver;

    constructor(DripsDeployer dripsDeployer, address admin)
        Module(dripsDeployer, ADDRESS_DRIVER_MODULE_SALT)
    {
        DripsModule dripsModule_ = dripsModule(dripsDeployer);
        Drips drips = dripsModule_.drips();
        address forwarder = address(callerModule(dripsDeployer).caller());
        uint32 driverId = 0;
        AddressDriver logic = new AddressDriver(drips, forwarder, driverId);
        address proxy = create3ManagedProxy(dripsDeployer, "AddressDriver", logic, admin, "");
        addressDriver = AddressDriver(proxy);
        dripsModule_.claimDriverId(ADDRESS_DRIVER_MODULE_SALT, driverId, proxy);
    }
}

bytes32 constant GIVERS_REGISTRY_MODULE_SALT = "GiversRegistryModule";

function giversRegistryModule(DripsDeployer dripsDeployer) view returns (GiversRegistryModule) {
    return GiversRegistryModule(findModule(dripsDeployer, GIVERS_REGISTRY_MODULE_SALT));
}

function giversRegistryModuleData(
    DripsDeployer dripsDeployer,
    IWrappedNativeToken wrappedNativeToken,
    address admin
) pure returns (ModuleData memory) {
    bytes memory args = abi.encode(dripsDeployer, wrappedNativeToken, admin);
    return ModuleData({
        salt: GIVERS_REGISTRY_MODULE_SALT,
        initCode: abi.encodePacked(type(GiversRegistryModule).creationCode, args),
        value: 0
    });
}

contract GiversRegistryModule is Module {
    GiversRegistry public immutable giversRegistry;

    constructor(DripsDeployer dripsDeployer, IWrappedNativeToken wrappedNativeToken, address admin)
        Module(dripsDeployer, GIVERS_REGISTRY_MODULE_SALT)
    {
        AddressDriver addressDriver = addressDriverModule(dripsDeployer).addressDriver();
        GiversRegistry logic = new GiversRegistry(addressDriver, wrappedNativeToken);
        address proxy = create3ManagedProxy(dripsDeployer, "GiversRegistry", logic, admin, "");
        giversRegistry = GiversRegistry(proxy);
    }
}

bytes32 constant NFT_DRIVER_MODULE_SALT = "NFTDriverModule";

function nftDriverModule(DripsDeployer dripsDeployer) view returns (NFTDriverModule) {
    return NFTDriverModule(findModule(dripsDeployer, NFT_DRIVER_MODULE_SALT));
}

function nftDriverModuleData(DripsDeployer dripsDeployer, address admin)
    pure
    returns (ModuleData memory)
{
    bytes memory args = abi.encode(dripsDeployer, admin);
    return ModuleData({
        salt: NFT_DRIVER_MODULE_SALT,
        initCode: abi.encodePacked(type(NFTDriverModule).creationCode, args),
        value: 0
    });
}

contract NFTDriverModule is Module {
    NFTDriver public immutable nftDriver;

    constructor(DripsDeployer dripsDeployer, address admin)
        Module(dripsDeployer, NFT_DRIVER_MODULE_SALT)
    {
        DripsModule dripsModule_ = dripsModule(dripsDeployer);
        Drips drips = dripsModule_.drips();
        address forwarder = address(callerModule(dripsDeployer).caller());
        uint32 driverId = 1;
        NFTDriver logic = new NFTDriver(drips, forwarder, driverId);
        address proxy = create3ManagedProxy(dripsDeployer, "NFTDriver", logic, admin, "");
        nftDriver = NFTDriver(proxy);
        dripsModule_.claimDriverId(NFT_DRIVER_MODULE_SALT, driverId, proxy);
    }
}

bytes32 constant IMMUTABLE_SPLITS_DRIVER_MODULE_SALT = "ImmutableSplitsDriverModule";

function immutableSplitsDriverModule(DripsDeployer dripsDeployer)
    view
    returns (ImmutableSplitsDriverModule)
{
    return
        ImmutableSplitsDriverModule(findModule(dripsDeployer, IMMUTABLE_SPLITS_DRIVER_MODULE_SALT));
}

function immutableSplitsDriverModuleData(DripsDeployer dripsDeployer, address admin)
    pure
    returns (ModuleData memory)
{
    bytes memory args = abi.encode(dripsDeployer, admin);
    return ModuleData({
        salt: IMMUTABLE_SPLITS_DRIVER_MODULE_SALT,
        initCode: abi.encodePacked(type(ImmutableSplitsDriverModule).creationCode, args),
        value: 0
    });
}

contract ImmutableSplitsDriverModule is Module {
    ImmutableSplitsDriver public immutable immutableSplitsDriver;

    constructor(DripsDeployer dripsDeployer, address admin)
        Module(dripsDeployer, IMMUTABLE_SPLITS_DRIVER_MODULE_SALT)
    {
        DripsModule dripsModule_ = dripsModule(dripsDeployer);
        Drips drips = dripsModule_.drips();
        uint32 driverId = 2;
        ImmutableSplitsDriver logic = new ImmutableSplitsDriver(drips, driverId);
        address proxy =
            create3ManagedProxy(dripsDeployer, "ImmutableSplitsDriver", logic, admin, "");
        immutableSplitsDriver = ImmutableSplitsDriver(proxy);
        dripsModule_.claimDriverId(IMMUTABLE_SPLITS_DRIVER_MODULE_SALT, driverId, proxy);
    }
}

bytes32 constant REPO_DRIVER_MODULE_SALT = "RepoDriverModule";

function repoDriverModule(DripsDeployer dripsDeployer) view returns (RepoDriverModule) {
    return RepoDriverModule(findModule(dripsDeployer, REPO_DRIVER_MODULE_SALT));
}

function repoDriverModuleData(
    DripsDeployer dripsDeployer,
    address admin,
    IAutomate gelatoAutomate,
    string memory ipfsCid,
    uint32 maxRequestsPerBlock,
    uint32 maxRequestsPer31Days
) pure returns (ModuleData memory) {
    bytes memory args = abi.encode(
        dripsDeployer, admin, gelatoAutomate, ipfsCid, maxRequestsPerBlock, maxRequestsPer31Days
    );
    return ModuleData({
        salt: REPO_DRIVER_MODULE_SALT,
        initCode: abi.encodePacked(type(RepoDriverModule).creationCode, args),
        value: 0
    });
}

contract RepoDriverModule is Module {
    RepoDriver public immutable repoDriver;

    constructor(
        DripsDeployer dripsDeployer,
        address admin,
        IAutomate gelatoAutomate,
        string memory ipfsCid,
        uint32 maxRequestsPerBlock,
        uint32 maxRequestsPer31Days
    ) Module(dripsDeployer, REPO_DRIVER_MODULE_SALT) {
        DripsModule dripsModule_ = dripsModule(dripsDeployer);
        Drips drips = dripsModule_.drips();
        address forwarder = address(callerModule(dripsDeployer).caller());
        uint32 driverId = 3;
        RepoDriver logic = new RepoDriver(drips, forwarder, driverId, gelatoAutomate);
        bytes memory data = abi.encodeCall(
            RepoDriver.updateGelatoTask, (ipfsCid, maxRequestsPerBlock, maxRequestsPer31Days)
        );
        address proxy = create3ManagedProxy(dripsDeployer, "RepoDriver", logic, admin, data);
        repoDriver = RepoDriver(payable(proxy));
        dripsModule_.claimDriverId(REPO_DRIVER_MODULE_SALT, driverId, proxy);
    }
}
