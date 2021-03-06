// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.6.10;
pragma experimental ABIEncoderV2;

import "../../lib/EIP712.sol";
import "../../lib/SignatureUtil.sol";
import "../base/BaseModule.sol";


/// @title ForwarderModule
/// @dev Base contract for all smart wallet modules.
///
/// @author Daniel Wang - <daniel@loopring.org>
contract ForwarderModule is BaseModule
{
    using SignatureUtil for bytes32;

    uint    public constant GAS_OVERHEAD = 100000;
    bytes32 public DOMAIN_SEPARATOR;

    constructor(ControllerImpl _controller)
        public
        BaseModule(_controller)
    {
        DOMAIN_SEPARATOR = EIP712.hash(
            EIP712.Domain("ForwarderModule", "1.1.0", address(this))
        );
    }

    event MetaTxExecuted(
        address indexed relayer,
        address indexed from,
        uint            nonce,
        bool            success,
        uint            gasUsed
    );

    struct MetaTx {
        address from;
        address to;
        uint    nonce;
        address gasToken;
        uint    gasPrice;
        uint    gasLimit;
        bytes32 txAwareHash;
        bytes   data;
    }

    bytes32 constant public META_TX_TYPEHASH = keccak256(
        "MetaTx(address from,address to,uint256 nonce,address gasToken,uint256 gasPrice,uint256 gasLimit,bytes32 txAwareHash,bytes data)"
    );

    function validateMetaTx(
        address from,
        address to,
        uint    nonce,
        address gasToken,
        uint    gasPrice,
        uint    gasLimit,
        bytes32 txAwareHash,
        bytes   memory data,
        bytes   memory signature
        )
        public
        view
    {
        require(
            (to == from) ||
            (to == controller.walletFactory()) ||
            (to != address(this) && Wallet(from).hasModule(to)),
            "INVALID_DESTINATION"
        );

        // If a non-zero txAwareHash is provided, we do not verify signature against
        // the `data` field. The actual function call in the real transaction will have to
        // check that txAwareHash is indeed valid.
        bytes memory data_ = (txAwareHash == 0) ? data : bytes("");
        bytes memory encoded = abi.encode(
            META_TX_TYPEHASH,
            from,
            to,
            nonce,
            gasToken,
            gasPrice,
            gasLimit,
            txAwareHash,
            keccak256(data_)
        );

        bytes32 metaTxHash = EIP712.hashPacked(DOMAIN_SEPARATOR, encoded);
        require(metaTxHash.verifySignature(from, signature), "INVALID_SIGNATURE");
    }

    function executeMetaTx(
        MetaTx calldata metaTx,
        bytes  calldata signature
        )
        external
        nonReentrant
        returns (
            bool         success,
            bytes memory ret
        )
    {
        require(
            gasleft() >= (metaTx.gasLimit.mul(64) / 63).add(GAS_OVERHEAD),
            "INSUFFICIENT_GAS"
        );

        controller.nonceStore().verifyAndUpdate(metaTx.from, metaTx.nonce);

        validateMetaTx(
            metaTx.from,
            metaTx.to,
            metaTx.nonce,
            metaTx.gasToken,
            metaTx.gasPrice,
            metaTx.gasLimit,
            metaTx.txAwareHash,
            metaTx.data,
            signature
        );

        uint gasLeft = gasleft();

        // The trick is to append the really logical message sender and the
        // transaction-aware hash to the end of the call data.
        (success, ret) = metaTx.to.call{gas : metaTx.gasLimit, value : 0}(
            abi.encodePacked(metaTx.data, metaTx.from, metaTx.txAwareHash)
        );

        if (address(this).balance > 0) {
            payable(controller.collectTo()).transfer(address(this).balance);
        }

        uint gasUsed = gasLeft - gasleft();
        uint gasAmount = gasUsed < metaTx.gasLimit ? gasUsed : metaTx.gasLimit;

        emit MetaTxExecuted(
            msg.sender,
            metaTx.from,
            metaTx.nonce,
            success,
            gasUsed
        );

        if (metaTx.gasPrice > 0) {
            reimburseGasFee(
                metaTx.from,
                controller.collectTo(),
                metaTx.gasToken,
                metaTx.gasPrice,
                gasAmount.add(GAS_OVERHEAD)
            );
        }

    }
}
