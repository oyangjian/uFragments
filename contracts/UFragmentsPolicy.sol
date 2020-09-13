pragma solidity ^0.4.24;

import "openzeppelin-eth/contracts/math/SafeMath.sol";
import "openzeppelin-eth/contracts/ownership/Ownable.sol";

import "./lib/SafeMathInt.sol";
import "./lib/UInt256Lib.sol";
import "./UFragments.sol";


interface IOracle {
    function getData() external returns (uint256, bool);
}


/**
 * @title uFragments Monetary Supply Policy
 * @dev This is an implementation of the uFragments Ideal Money protocol.
 *      uFragments operates symmetrically on expansion and contraction. It will both split and
 *      combine coins to maintain a stable unit price.
 *
 *      This component regulates the token supply of the uFragments ERC20 token in response to
 *      market oracles.
 */
contract UFragmentsPolicy is Ownable {
    using SafeMath for uint256;
    using SafeMathInt for int256;
    using UInt256Lib for uint256;

    event LogRebase(
        uint256 indexed epoch,
        uint256 exchangeRate,
        uint256 cpi,
        uint256 cryptoRate,
        int256 requestedSupplyAdjustment,
        uint256 timestampSec
    );

    UFragments public uFrags;

    // Provides the current CPI, as an 18 decimal fixed point number.
    IOracle public cpiOracle;

    // Market oracle provides the token/USD exchange rate as an 18 decimal fixed point number.
    // (eg) An oracle value of 1.5e18 it would mean 1 Ample is trading for $1.50.
    IOracle public marketOracle;

    // Crypto oracle provides the main cryptocurrency market value daily change as an 18 decimal fixed point number.
    // (eg) An oracle value of 1.5e18 it would mean the main cryptocurrency market value has increased 50% for the last day.
    // (eg) An oracle value of 0.8e18 it would mean down 20%.
    IOracle public cryptoOracle;

    // the main cryptocurrency market value daily changement influence percentage weight
    // as an 18 decimal fixed point number.
    // (eg) An cryptoWeight value of 0.5e18 means 50%.
    // (eg) An cryptoWeight value of 0.2e18 means 20%.
    uint256 public cryptoWeight;

    // CPI value at the time of launch, as an 18 decimal fixed point number.
    uint256 private baseCpi;

    // If the current exchange rate is within this fractional distance from the target, no supply
    // update is performed. Fixed point number--same format as the rate.
    // (ie) abs(rate - targetRate) / targetRate < deviationThreshold, then no supply change.
    // DECIMALS Fixed point number.
    uint256 public deviationThreshold;

    // The rebase lag parameter, used to dampen the applied supply adjustment by 1 / rebaseLag
    // Check setRebaseLag comments for more details.
    // Natural number, no decimal places.
    // rebaseLag= 10
    uint256 public rebaseLag;

    // More than this much time must pass between rebase operations.
    // 24hours
    uint256 public minRebaseTimeIntervalSec;

    // Block timestamp of last rebase operation
    uint256 public lastRebaseTimestampSec;

    // The rebase window begins this many seconds into the minRebaseTimeInterval period.
    // For example if minRebaseTimeInterval is 24hrs, it represents the time of day in seconds.
    // 7200sec = 2hours 2:00 am
    // 2:00 AM (2:00) International = 10:00 AM (10:00) China
    uint256 public rebaseWindowOffsetSec;

    // The length of the time window where a rebase operation is allowed to execute, in seconds.
    // 20min
    uint256 public rebaseWindowLengthSec;

    // The number of rebase cycles since inception
    uint256 public epoch;

    uint256 private constant DECIMALS = 18;

    // Due to the expression in computeSupplyDelta(), MAX_RATE * MAX_SUPPLY must fit into an int256.
    // Both are 18 decimals fixed point numbers.
    uint256 private constant MAX_RATE = 10**6 * 10**DECIMALS;
    // MAX_SUPPLY = MAX_INT256 / MAX_RATE
    uint256 private constant MAX_SUPPLY = ~(uint256(1) << 255) / MAX_RATE;
    // crypto rate limit to (0-100%)
    uint256 private constant MAX_CRYPTO_RATE_ORIGINAL = 2 * 10**DECIMALS;

    // This module orchestrates the rebase execution and downstream notification.
    address public orchestrator;

    modifier onlyOrchestrator() {
        require(msg.sender == orchestrator);
        _;
    }

    /**
     * @notice Initiates a new rebase operation, provided the minimum time period has elapsed.
     *
     * @dev The supply adjustment equals (_totalSupply * DeviationFromTargetRate) / rebaseLag
     *      Where DeviationFromTargetRate is (MarketOracleRate - targetRate) / targetRate
     *      and targetRate is CpiOracleRate / baseCpi
     */
    function rebase() external onlyOrchestrator {
        require(inRebaseWindow());

        // This comparison also ensures there is no reentrancy.
        require(lastRebaseTimestampSec.add(minRebaseTimeIntervalSec) < now);

        // Snap the rebase time to the start of this window.
        lastRebaseTimestampSec = now.sub(
            now.mod(minRebaseTimeIntervalSec)).add(rebaseWindowOffsetSec);

        epoch = epoch.add(1);

        uint256 cpi;
        bool cpiValid;
        // cpi=110.21e18
        (cpi, cpiValid) = cpiOracle.getData();
        require(cpiValid);

        // targetRate=1.003239393939394e+18
        uint256 targetRate = cpi.mul(10 ** DECIMALS).div(baseCpi);

        uint256 exchangeRate;
        bool rateValid;
        // exchangeRage=0.7694186438892614e+18
        (exchangeRate, rateValid) = marketOracle.getData();
        require(rateValid);

        if (exchangeRate > MAX_RATE) {
            exchangeRate = MAX_RATE;
        }

        uint256 cryptoRate = 1 * 10 ** DECIMALS;
        bool cryptoRateValid;
        (cryptoRate, cryptoRateValid) = cryptoOracle.getData();
        require(cryptoRateValid);

        // cryptoRate-1 limit to (-1, 1), means (-100%, 100%)
        if (cryptoRate > MAX_CRYPTO_RATE_ORIGINAL) {
            cryptoRate = MAX_CRYPTO_RATE_ORIGINAL;
        }

        int256 supplyDelta = computeSupplyDelta2(exchangeRate, targetRate, cryptoRate);

        // Apply the Dampening factor.
        supplyDelta = supplyDelta.div(rebaseLag.toInt256Safe());

        if (supplyDelta > 0 && uFrags.totalSupply().add(uint256(supplyDelta)) > MAX_SUPPLY) {
            supplyDelta = (MAX_SUPPLY.sub(uFrags.totalSupply())).toInt256Safe();
        }

        uint256 supplyAfterRebase = uFrags.rebase(epoch, supplyDelta);
        assert(supplyAfterRebase <= MAX_SUPPLY);
        emit LogRebase(epoch, exchangeRate, cpi, cryptoRate, supplyDelta, now);
    }

    /**
     * @notice Sets the reference to the CPI oracle.
     * @param cpiOracle_ The address of the cpi oracle contract.
     */
    function setCpiOracle(IOracle cpiOracle_)
        external
        onlyOwner
    {
        cpiOracle = cpiOracle_;
    }

    /**
     * @notice Sets the reference to the market oracle.
     * @param marketOracle_ The address of the market oracle contract.
     */
    function setMarketOracle(IOracle marketOracle_)
        external
        onlyOwner
    {
        marketOracle = marketOracle_;
    }

    function setCryptoOracle(IOracle cryptoOracle_)
        external
        onlyOwner
    {
        cryptoOracle = cryptoOracle_;
    }

    function setCryptoWeight(uint256 cryptoWeight_)
        external
        onlyOwner
    {
        require(cryptoWeight_ <= 1 * 10 ** DECIMALS);
        cryptoWeight = cryptoWeight_;
    }

    /**
     * @notice Sets the reference to the orchestrator.
     * @param orchestrator_ The address of the orchestrator contract.
     */
    function setOrchestrator(address orchestrator_)
        external
        onlyOwner
    {
        orchestrator = orchestrator_;
    }

    /**
     * @notice Sets the deviation threshold fraction. If the exchange rate given by the market
     *         oracle is within this fractional distance from the targetRate, then no supply
     *         modifications are made. DECIMALS fixed point number.
     * @param deviationThreshold_ The new exchange rate threshold fraction.
     */
    function setDeviationThreshold(uint256 deviationThreshold_)
        external
        onlyOwner
    {
        deviationThreshold = deviationThreshold_;
    }

    /**
     * @notice Sets the rebase lag parameter.
               It is used to dampen the applied supply adjustment by 1 / rebaseLag
               If the rebase lag R, equals 1, the smallest value for R, then the full supply
               correction is applied on each rebase cycle.
               If it is greater than 1, then a correction of 1/R of is applied on each rebase.
     * @param rebaseLag_ The new rebase lag parameter.
     */
    function setRebaseLag(uint256 rebaseLag_)
        external
        onlyOwner
    {
        require(rebaseLag_ > 0);
        rebaseLag = rebaseLag_;
    }

    /**
     * @notice Sets the parameters which control the timing and frequency of
     *         rebase operations.
     *         a) the minimum time period that must elapse between rebase cycles.
     *         b) the rebase window offset parameter.
     *         c) the rebase window length parameter.
     * @param minRebaseTimeIntervalSec_ More than this much time must pass between rebase
     *        operations, in seconds.
     * @param rebaseWindowOffsetSec_ The number of seconds from the beginning of
              the rebase interval, where the rebase window begins.
     * @param rebaseWindowLengthSec_ The length of the rebase window in seconds.
     */
    function setRebaseTimingParameters(
        uint256 minRebaseTimeIntervalSec_,
        uint256 rebaseWindowOffsetSec_,
        uint256 rebaseWindowLengthSec_)
        external
        onlyOwner
    {
        require(minRebaseTimeIntervalSec_ > 0);
        require(rebaseWindowOffsetSec_ < minRebaseTimeIntervalSec_);

        minRebaseTimeIntervalSec = minRebaseTimeIntervalSec_;
        rebaseWindowOffsetSec = rebaseWindowOffsetSec_;
        rebaseWindowLengthSec = rebaseWindowLengthSec_;
    }

    /**
     * @dev ZOS upgradable contract initialization method.
     *      It is called at the time of contract creation to invoke parent class initializers and
     *      initialize the contract's state variables.
     */
    function initialize(address owner_, UFragments uFrags_, uint256 baseCpi_)
        public
        initializer
    {
        Ownable.initialize(owner_);

        // deviationThreshold = 0.05e18 = 5e16
        deviationThreshold = 5 * 10 ** (DECIMALS-2);

        rebaseLag = 30;
        minRebaseTimeIntervalSec = 1 days;
        rebaseWindowOffsetSec = 72000;  // 8PM UTC
        rebaseWindowLengthSec = 15 minutes;
        lastRebaseTimestampSec = 0;
        epoch = 0;

        uFrags = uFrags_;
        // baseCpi_ = 100e18
        baseCpi = baseCpi_;
        // cryptoWeight = 50% = 0.5e18 = 50e16
        cryptoWeight = 50 * 10 ** (DECIMALS-2);
    }

    /**
     * @return If the latest block timestamp is within the rebase time window it, returns true.
     *         Otherwise, returns false.
     */
    function inRebaseWindow() public view returns (bool) {
        return (
            now.mod(minRebaseTimeIntervalSec) >= rebaseWindowOffsetSec &&
            now.mod(minRebaseTimeIntervalSec) < (rebaseWindowOffsetSec.add(rebaseWindowLengthSec))
        );
    }

    /**
     * @return Computes the total supply adjustment in response to the exchange rate
     *         and the targetRate.
     */
    function computeSupplyDelta(uint256 rate, uint256 targetRate)
        private
        view
        returns (int256)
    {
        if (withinDeviationThreshold(rate, targetRate)) {
            return 0;
        }

        // supplyDelta = totalSupply * (rate - targetRate) / targetRate
        int256 targetRateSigned = targetRate.toInt256Safe();
        return uFrags.totalSupply().toInt256Safe()
            .mul(rate.toInt256Safe().sub(targetRateSigned))
            .div(targetRateSigned);
    }

    /**
     * @param rate The current exchange rate, an 18 decimal fixed point number.
     * @param targetRate The target exchange rate, an 18 decimal fixed point number.
     * @return If the rate is within the deviation threshold from the target rate, returns true.
     *         Otherwise, returns false.
     */
    function withinDeviationThreshold(uint256 rate, uint256 targetRate)
        private
        view
        returns (bool)
    {
        uint256 absoluteDeviationThreshold = targetRate.mul(deviationThreshold)
            .div(10 ** DECIMALS);

        return (rate >= targetRate && rate.sub(targetRate) < absoluteDeviationThreshold)
            || (rate < targetRate && targetRate.sub(rate) < absoluteDeviationThreshold);
    }

    function computeSupplyDelta2(uint256 rate, uint256 targetRate, uint256 cryptoRate)
        private
        view
        returns (int256)
    {
        int256 oneUnit = (10 ** DECIMALS).toInt256Safe();
        int256 cryptoRateSigned = cryptoRate.toInt256Safe().sub(oneUnit);
        int256 rateSigned = rate.toInt256Safe();
        int256 targetRateSigned = targetRate.toInt256Safe();
        int256 totalSupply = uFrags.totalSupply().toInt256Safe();

        // supplyDeltaRate1 = (10**18 - cryptoWeight) * (rate - targetRate) / targetRate
        int256 supplyDeltaRate1 = oneUnit.sub(cryptoWeight.toInt256Safe())
            .mul(rateSigned.sub(targetRateSigned)).div(targetRateSigned);

        // supplyDeltaRate2 = cryptoWeight * cryptoRate / 10**18
        int256 supplyDeltaRate2 = cryptoWeight.toInt256Safe().mul(cryptoRateSigned).div(oneUnit);

        int256 supplyDeltaRateResult = supplyDeltaRate1.add(supplyDeltaRate2);

        if (supplyDeltaRateResult >= 0 && supplyDeltaRateResult < deviationThreshold.toInt256Safe()) {
            return 0;
        }
        if (supplyDeltaRateResult < 0 && supplyDeltaRateResult.abs() < deviationThreshold.toInt256Safe()) {
            return 0;
        }
        return totalSupply.mul(supplyDeltaRateResult).div(oneUnit);
    }
}
