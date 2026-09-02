// SPDX-License-Identifier: BUSL-1.1
// ArchetypeBatchV100 v1.0.0
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-v4/token/ERC20/IERC20.sol";
import {IERC721} from "openzeppelin-v4/token/ERC721/IERC721.sol";
import {IERC1155} from "openzeppelin-v4/token/ERC1155/IERC1155.sol";
import {Ownable} from "openzeppelin-v4/access/Ownable.sol";
import {SafeERC20} from "openzeppelin-v4/token/ERC20/utils/SafeERC20.sol";
import {RoyaltyPolicyRegistry} from "./RoyaltyPolicyRegistry.sol";
import {MintConstraints} from "./MintConstraints.sol";

interface IArchetypeV100Collection {
    struct ArchetypeAddresses {
        address platform;
        address payouts;
        address batch;
    }

    function archetypeAddresses() external view returns (ArchetypeAddresses memory);
}

interface IArchetypeV100Mint {
    struct Auth {
        bytes32 key;
        bytes32[] proof;
    }

    function mint(
        Auth calldata auth,
        uint256 quantity,
        address affiliate,
        bytes calldata affiliateAuthorization,
        MintConstraints calldata constraints
    ) external payable;

    function mintToken(
        Auth calldata auth,
        uint256 quantity,
        uint256 tokenId,
        address affiliate,
        bytes calldata affiliateAuthorization,
        MintConstraints calldata constraints
    ) external payable;
}

contract ArchetypeBatchV100 is Ownable {
    using SafeERC20 for IERC20;

    uint256 private constant _CURRENT_CALLER_SLOT = 0xa635c9f4c283427ea6864a49a31b6433e5a3c534efd58c9e71bb8c7d5e50ec76;

    RoyaltyPolicyRegistry public immutable royaltyPolicyRegistry;

    error InvalidOwner();
    error InvalidRoyaltyPolicyRegistry();
    error BatchLengthMismatch();
    error BatchValueMismatch();
    error UnsupportedCollection(address target);
    error UnsupportedMintCall(bytes4 selector);
    error BatchBalanceDecreased();
    error NativeTransferFailed();

    constructor(address owner_, RoyaltyPolicyRegistry royaltyPolicyRegistry_) {
        if (owner_ == address(0)) revert InvalidOwner();
        if (address(royaltyPolicyRegistry_) == address(0) || address(royaltyPolicyRegistry_).code.length == 0) {
            revert InvalidRoyaltyPolicyRegistry();
        }

        royaltyPolicyRegistry = royaltyPolicyRegistry_;
        _transferOwnership(owner_);
    }

    function currentCaller() public view returns (address value) {
        assembly ("memory-safe") {
            value := tload(_CURRENT_CALLER_SLOT)
        }
    }

    /// @notice Executes a multi-list mint cart against registered V100 collections.
    function executeBatch(address[] calldata targets, uint256[] calldata values, bytes[] calldata datas)
        external
        payable
    {
        if (targets.length != values.length || targets.length != datas.length) {
            revert BatchLengthMismatch();
        }

        uint256 totalValue;
        for (uint256 i = 0; i < targets.length; ++i) {
            totalValue += values[i];
        }
        if (totalValue != msg.value) revert BatchValueMismatch();

        uint256 balanceBefore = address(this).balance - msg.value;
        address previousCaller = currentCaller();
        assembly ("memory-safe") {
            tstore(_CURRENT_CALLER_SLOT, caller())
        }

        for (uint256 i = 0; i < targets.length; ++i) {
            address target = targets[i];
            if (
                !royaltyPolicyRegistry.scatterCollections(target)
                    || IArchetypeV100Collection(target).archetypeAddresses().batch != address(this)
            ) {
                revert UnsupportedCollection(target);
            }

            bytes4 selector = bytes4(datas[i]);
            if (selector != IArchetypeV100Mint.mint.selector && selector != IArchetypeV100Mint.mintToken.selector) {
                revert UnsupportedMintCall(selector);
            }

            (bool success, bytes memory returnData) = target.call{value: values[i]}(datas[i]);
            if (!success) {
                assembly ("memory-safe") {
                    revert(add(returnData, 32), mload(returnData))
                }
            }
        }

        assembly ("memory-safe") {
            tstore(_CURRENT_CALLER_SLOT, previousCaller)
        }

        if (address(this).balance < balanceBefore) revert BatchBalanceDecreased();
    }

    function rescueETH(address recipient) external onlyOwner {
        (bool success,) = payable(recipient).call{value: address(this).balance}("");
        if (!success) revert NativeTransferFailed();
    }

    function rescueERC20(IERC20 asset, address recipient) external onlyOwner {
        asset.safeTransfer(recipient, asset.balanceOf(address(this)));
    }

    function rescueERC721(IERC721 asset, uint256[] calldata ids, address recipient) external onlyOwner {
        for (uint256 i = 0; i < ids.length; ++i) {
            asset.transferFrom(address(this), recipient, ids[i]);
        }
    }

    function rescueERC1155(IERC1155 asset, uint256[] calldata ids, uint256[] calldata amounts, address recipient)
        external
        onlyOwner
    {
        for (uint256 i = 0; i < ids.length; ++i) {
            asset.safeTransferFrom(address(this), recipient, ids[i], amounts[i], "");
        }
    }
}
