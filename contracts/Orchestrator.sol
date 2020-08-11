pragma solidity 0.4.24;

import "openzeppelin-eth/contracts/ownership/Ownable.sol";

import "./UFragmentsPolicy.sol";


/**
 * @title Orchestrator
 * @notice The orchestrator is the main entry point for rebase operations. It coordinates the policy
 * actions with external consumers.
 */
contract Orchestrator is Ownable {

    struct Transaction {
        bool enabled;
        address destination;
        bytes data;
        uint256 gasLimit; // todo: is it ok to modify struct storage layout?
        mapping (bytes32 => bool) revertOK; // todo: is it ok to leave garbage on transaction removal?
    }

    event TransactionFailed(address indexed destination, uint index, bytes data, string reason);

    // Stable ordering is not guaranteed.
    Transaction[] public transactions;

    UFragmentsPolicy public policy;

    /**
     * @param policy_ Address of the UFragments policy.
     */
    constructor(address policy_) public {
        Ownable.initialize(msg.sender);
        policy = UFragmentsPolicy(policy_);
    }

    /**
     * @notice Main entry point to initiate a rebase operation.
     *         The Orchestrator calls rebase on the policy and notifies downstream applications.
     *         Contracts are guarded from calling, to avoid flash loan attacks on liquidity
     *         providers.
     *         If a transaction in the transaction list reverts, it is swallowed and the remaining
     *         transactions are executed.
     */
    function rebase()
        external
    {
        require(msg.sender == tx.origin);  // solhint-disable-line avoid-tx-origin

        // call monetary policy rebase, always revert on failure
        policy.rebase();

        // call peripheral contracts, handle reverts based on policy
        for (uint index = 0; index < transactions.length; index++) {
            _executePeripheralTransaction(index);
        }
    }

    /**
     * @notice Get the revert message and code from a call.
     * @param index uint256 Index of the transaction.
     * @return revertMessage string Revert message.
     * @return revertCode bytes32 Revert code.
     */
    function _executePeripheralTransaction(uint256 index) internal returns (bool, bytes[] memory) {
        // declare storage reference
        Transaction storage transaction = transactions[index];

        // validate sufficient gas left
        require(gasleft() > transaction.gasLimit);

        // perform external call
        // todo: @thegostep solc v0.4 does not return revert string on call
        // todo: @thegostep solc v0.4 does not support specifying gaslimit on call
        // decide if upgrade solc or implement in assembly
        // https://solidity.readthedocs.io/en/v0.4.24/units-and-global-variables.html#address-related
        (bool success, bytes memory res) = address(transaction.destination).call(transaction.data);

        // Check if any of the atomic transactions failed, if not, decode return data
        bytes[] memory returnData;
        if (!success) {
            // parse revert message
            (string memory revertMessage, bytes32 revertCode) = _getRevertMsg(res);
            // if approved revert, log it and continue
            if (transaction.revertOK[revertCode]) {
                emit TransactionFailed(transaction.destination, index, transaction.data, revertMessage);
            } 
            // else revert batch
            else {
                revert("Transaction Failed");
            }
        } else {
            // decode and return call return values
            returnData = abi.decode(res, (bytes[]));
        }

        // explicit return
        return (success, returnData);
	}

    /**
     * @notice Get the revert message and code from a call.
     * @param res bytes Response of the call.
     * @return revertMessage string Revert message.
     * @return revertCode bytes32 Revert code.
     */
	function _getRevertMsg(bytes memory res) internal pure returns (string memory revertMessage, bytes32 revertCode) {
        // If there is no prefix to the revert reason, we know it was an OOG error
        if (res.length == 0) {
            revertMessage = "Transaction out of gas";
        }
		// If the revert reason length is less than 68, then the transaction failed silently (without a revert message)
		else if (res.length < 68) {
            revertMessage = "Transaction reverted silently";
        }
        // Else extract revert message
        else {
	        bytes memory revertData = res.slice(4, res.length - 4); // Remove the selector which is the first 4 bytes
		    revertMessage = abi.decode(revertData, (string)); // All that remains is the revert string
        }
        // obtain revert code
        revertCode = keccak256(revertMessage);
        // explicit return
        return (revertMessage, revertCode);
	}

    /**
     * @notice Adds a transaction that gets called for a downstream receiver of rebases
     * @param destination Address of contract destination
     * @param data Transaction data payload
     * @param gasLimit Transaction gas limit
     * @param revertOKs Transaction approved revert codes
     */
    function addTransaction(address destination, bytes data, uint256 gasLimit, bytes32[] revertOKs)
        external
        onlyOwner
    {
        // craft transaction object
        Transaction memory transaction = Transaction({
            enabled: true,
            destination: destination,
            data: data,
            gasLimit: gasLimit
        });
        // push transaction to storage
        transactions.push(transaction);
        // assign valid revert strings
        for (uint256 index = 0; index < revertOKs.length; index++) {
            transactions[transactions.length - 1].revertOK[revertOKs[index]] = true;
        }
    }

    /**
     * @param index Index of transaction to remove.
     *              Transaction ordering may have changed since adding.
     */
    function removeTransaction(uint index)
        external
        onlyOwner
    {
        require(index < transactions.length, "index out of bounds");

        if (index < transactions.length - 1) {
            transactions[index] = transactions[transactions.length - 1];
        }

        transactions.length--;
    }

    /**
     * @param index Index of transaction. Transaction ordering may have changed since adding.
     * @param enabled True for enabled, false for disabled.
     */
    function setTransactionEnabled(uint index, bool enabled)
        external
        onlyOwner
    {
        require(index < transactions.length, "index must be in range of stored tx list");
        transactions[index].enabled = enabled;
    }

    /**
     * @return Number of transactions, both enabled and disabled, in transactions list.
     */
    function transactionsSize()
        external
        view
        returns (uint256)
    {
        return transactions.length;
    }

    /**
     * @dev wrapper to call the encoded transactions on downstream consumers.
     * @param destination Address of destination contract.
     * @param data The encoded data payload.
     * @return True on success
     */
    function externalCall(address destination, bytes data)
        internal
        returns (bool)
    {
        bool result;
        assembly {  // solhint-disable-line no-inline-assembly
            // "Allocate" memory for output
            // (0x40 is where "free memory" pointer is stored by convention)
            let outputAddress := mload(0x40)

            // First 32 bytes are the padded length of data, so exclude that
            let dataAddress := add(data, 32)

            result := call(
                // 34710 is the value that solidity is currently emitting
                // It includes callGas (700) + callVeryLow (3, to pay for SUB)
                // + callValueTransferGas (9000) + callNewAccountGas
                // (25000, in case the destination address does not exist and needs creating)
                sub(gas, 34710),


                destination,
                0, // transfer value in wei
                dataAddress,
                mload(data),  // Size of the input, in bytes. Stored in position 0 of the array.
                outputAddress,
                0  // Output is ignored, therefore the output size is zero
            )
        }
        return result;
    }
}
