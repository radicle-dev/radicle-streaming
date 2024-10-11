// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {create3} from "script/utils/Create3Helpers.sol";
import {
    isModuleDeployed,
    ModulesDeployer,
    getModule,
    Module,
    ModuleData
} from "script/utils/ModulesDeployer.sol";
import {IWrappedNativeToken} from "src/IWrappedNativeToken.sol";
import {NativeTokenUnwrapper} from "src/NativeTokenUnwrapper.sol";

bytes32 constant NATIVE_TOKEN_UNWRAPPER_MODULE_SALT = "NativeTokenUnwrapperModule";

function isNativeTokenUnwrapperModuleDeployed(ModulesDeployer modulesDeployer)
    view
    returns (bool yes)
{
    return isModuleDeployed(modulesDeployer, NATIVE_TOKEN_UNWRAPPER_MODULE_SALT);
}

function nativeTokenUnwrapperModule(ModulesDeployer modulesDeployer)
    view
    returns (NativeTokenUnwrapperModule)
{
    return
        NativeTokenUnwrapperModule(getModule(modulesDeployer, NATIVE_TOKEN_UNWRAPPER_MODULE_SALT));
}

function nativeTokenUnwrapperModuleData(
    ModulesDeployer modulesDeployer,
    IWrappedNativeToken wrappedNativeToken
) pure returns (ModuleData memory) {
    bytes memory args = abi.encode(modulesDeployer, wrappedNativeToken);
    return ModuleData({
        salt: NATIVE_TOKEN_UNWRAPPER_MODULE_SALT,
        initCode: abi.encodePacked(type(NativeTokenUnwrapperModule).creationCode, args),
        value: 0
    });
}

contract NativeTokenUnwrapperModule is Module {
    NativeTokenUnwrapper public immutable nativeTokenUnwrapper;

    constructor(ModulesDeployer modulesDeployer, IWrappedNativeToken wrappedNativeToken)
        Module(modulesDeployer, NATIVE_TOKEN_UNWRAPPER_MODULE_SALT)
    {
        bytes memory args = abi.encode(wrappedNativeToken);
        // slither-disable-next-line too-many-digits
        address deployment = create3(
            modulesDeployer, "NativeTokenUnwrapper", type(NativeTokenUnwrapper).creationCode, args
        );
        nativeTokenUnwrapper = NativeTokenUnwrapper(payable(deployment));
    }
}
