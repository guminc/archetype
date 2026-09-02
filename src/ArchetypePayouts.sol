// SPDX-License-Identifier: BUSL-1.1
// ArchetypePayouts v0.8.0
//
//        d8888                 888               888
//       d88888                 888               888
//      d88P888                 888               888
//     d88P 888 888d888 .d8888b 88888b.   .d88b.  888888 888  888 88888b.   .d88b.
//    d88P  888 888P"  d88P"    888 "88b d8P  Y8b 888    888  888 888 "88b d8P  Y8b
//   d88P   888 888    888      888  888 88888888 888    888  888 888  888 88888888
//  d8888888888 888    Y88b.    888  888 Y8b.     Y88b.  Y88b 888 888 d88P Y8b.
// d88P     888 888     "Y8888P 888  888  "Y8888   "Y888  "Y88888 88888P"   "Y8888
//                                                            888 888
//                                                       Y8b d88P 888
//
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

error InvalidLength();
error InvalidSplitShares();
error InvalidRecipient();
error TransferFailed();
error BalanceEmpty();
error NotApprovedToWithdraw();
error InvalidNativeValue();
error UnexpectedTokenBalanceChange();
error InvalidPayouts();

struct NativeMintCredit {
    uint256 payoutAmount;
    uint128 affiliateAmount;
    uint256 platformSurcharge;
    address affiliate;
    address platform;
}

contract ArchetypePayouts {
    using SafeERC20 for IERC20;

    event Withdrawal(address indexed src, address token, uint256 wad);
    event FundsAdded(address indexed source, address indexed recipient, address token, uint256 amount);

    mapping(address => mapping(address => uint256)) private _balance;
    mapping(address => mapping(address => bool)) private _approvals;

    function updateBalances(uint256 totalAmount, address token, address[] calldata recipients, uint16[] calldata splits)
        public
        payable
    {
        _validateSplits(recipients, splits);

        if (token == address(0)) {
            // ETH payments
            _creditBalances(msg.value, token, recipients, splits);
        } else {
            // ERC20 payments
            IERC20 paymentToken = IERC20(token);
            uint256 balanceBefore = paymentToken.balanceOf(address(this));
            paymentToken.safeTransferFrom(msg.sender, address(this), totalAmount);
            if (paymentToken.balanceOf(address(this)) != balanceBefore + totalAmount) {
                revert UnexpectedTokenBalanceChange();
            }

            _creditBalances(totalAmount, token, recipients, splits);
        }
    }

    function creditMint(NativeMintCredit calldata credit, address[] calldata recipients, uint16[] calldata splits)
        external
        payable
    {
        if (msg.value != credit.payoutAmount + credit.affiliateAmount + credit.platformSurcharge) {
            revert InvalidNativeValue();
        }
        if (credit.affiliate == address(0) && credit.affiliateAmount != 0) revert InvalidRecipient();
        if (credit.platform == address(0) && credit.platformSurcharge != 0) revert InvalidRecipient();

        if (credit.payoutAmount != 0) {
            _validateSplits(recipients, splits);
            _creditBalances(credit.payoutAmount, address(0), recipients, splits);
        }

        if (credit.affiliate != address(0) && credit.affiliateAmount != 0) {
            _credit(credit.affiliate, address(0), credit.affiliateAmount);
        }

        if (credit.platformSurcharge != 0) {
            _credit(credit.platform, address(0), credit.platformSurcharge);
        }
    }

    function _validateSplits(address[] calldata recipients, uint16[] calldata splits) internal pure {
        if (recipients.length != splits.length) {
            revert InvalidLength();
        }

        uint256 totalShares = 0;
        for (uint256 i = 0; i < splits.length; i++) {
            if (splits[i] > 0 && recipients[i] == address(0)) {
                revert InvalidRecipient();
            }
            totalShares += splits[i];
        }
        if (totalShares != 10000) {
            revert InvalidSplitShares();
        }
    }

    function _creditBalances(
        uint256 totalAmount,
        address token,
        address[] calldata recipients,
        uint16[] calldata splits
    ) internal {
        uint256 residualIndex;
        while (splits[residualIndex] == 0) {
            residualIndex++;
        }

        uint256 residual = totalAmount;
        for (uint256 i = 0; i < recipients.length; i++) {
            if (splits[i] == 0 || i == residualIndex) continue;
            uint256 amount = (totalAmount * splits[i]) / 10000;
            residual -= amount;
            _credit(recipients[i], token, amount);
        }

        _credit(recipients[residualIndex], token, residual);
    }

    function _credit(address recipient, address token, uint256 amount) internal {
        _balance[recipient][token] += amount;
        emit FundsAdded(msg.sender, recipient, token, amount);
    }

    function withdraw() external {
        address msgSender = msg.sender;
        _withdraw(msgSender, msgSender, address(0));
    }

    function withdrawTokens(address[] calldata tokens) external {
        address msgSender = msg.sender;

        for (uint256 i = 0; i < tokens.length; i++) {
            _withdraw(msgSender, msgSender, tokens[i]);
        }
    }

    function withdrawFrom(address from, address to) public {
        if (from != msg.sender && !_approvals[from][to]) {
            revert NotApprovedToWithdraw();
        }
        _withdraw(from, to, address(0));
    }

    function withdrawTokensFrom(address from, address to, address[] calldata tokens) public {
        if (from != msg.sender && !_approvals[from][to]) {
            revert NotApprovedToWithdraw();
        }
        for (uint256 i = 0; i < tokens.length; i++) {
            _withdraw(from, to, tokens[i]);
        }
    }

    function _withdraw(address from, address to, address token) internal {
        uint256 wad;

        wad = _balance[from][token];
        _balance[from][token] = 0;

        if (wad == 0) {
            revert BalanceEmpty();
        }

        if (token == address(0)) {
            bool success = false;
            (success,) = to.call{value: wad}("");
            if (!success) {
                revert TransferFailed();
            }
        } else {
            IERC20 erc20Token = IERC20(token);
            erc20Token.safeTransfer(to, wad);
        }
        emit Withdrawal(from, token, wad);
    }

    function approveWithdrawal(address delegate, bool approved) external {
        _approvals[msg.sender][delegate] = approved;
    }

    function isApproved(address from, address delegate) external view returns (bool) {
        return _approvals[from][delegate];
    }

    function balance(address recipient) external view returns (uint256) {
        return _balance[recipient][address(0)];
    }

    function balanceToken(address recipient, address token) external view returns (uint256) {
        return _balance[recipient][token];
    }
}
