// https://etherscan.io/address/0x594a198048501a304267e63b3bad0f0638da7628#code

// SPDX-License-Identifier: MIT
pragma solidity ^0.6.2;

import "../../lib/erc20.sol";
import "../../lib/safe-math.sol";

import "./scrv-voter.sol";
import "./crv-locker.sol";

import "../../interfaces/jar.sol";
import "../../interfaces/curve.sol";
import "../../interfaces/uniswapv2.sol";
import "../../interfaces/controller.sol";

contract StrategyCurveSCRVv3 {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    // sCRV
    address public constant want = 0xC25a3A3b969415c80451098fa907EC722572917F;

    // susdv2 pool
    address public constant curve = 0xA5407eAE9Ba41422680e2e00537571bcC53efBfD;

    // tokens we're farming
    address public constant crv = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address public constant snx = 0xC011a73ee8576Fb46F5E1c5751cA3B9Fe0af2a6F;

    // curve dao
    address public constant gauge = 0xA90996896660DEcC6E997655E065b23788857849;
    address public constant mintr = 0xd061D61a4d941c39E5453435B6345Dc261C2fcE0;

    // stablecoins
    address public constant dai = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant usdt = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant susd = 0x57Ab1ec28D129707052df4dF418D58a2D46d5f51;

    // pickle token
    address public constant pickle = 0x429881672B9AE42b8EbA0E26cD9C73711b891Ca5;

    // weth (for uniswapv2 xfers)
    address public constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // burn address
    address public constant burn = 0x000000000000000000000000000000000000dEaD;

    // dex
    address public univ2Router2 = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    // How much CRV tokens to keep
    uint256 public keepCRV = 0;
    uint256 public constant keepCRVMax = 10000;

    // Perfomance fee 4.5%
    uint256 public performanceFee = 450;
    uint256 public constant performanceMax = 10000;

    // Withdrawal fee 0.5%
    // - 0.375% to treasury
    // - 0.125% to dev fund
    uint256 public treasuryFee = 375;
    uint256 public constant treasuryMax = 100000;

    uint256 public devFundFee = 125;
    uint256 public constant devFundMax = 100000;

    address public governance;
    address public controller;
    address public timelock;
    address public strategist;

    constructor(
        address _governance,
        address _strategist,
        address _timelock,
        address _controller
    ) public {
        governance = _governance;
        strategist = _strategist;
        timelock = _timelock;
        controller = _controller;
    }

    // **** Views ****

    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    function balanceOfPool() public view returns (uint256) {
        return ICurveGauge(gauge).balanceOf(address(this));
    }

    function balanceOf() public view returns (uint256) {
        return balanceOfWant().add(balanceOfPool());
    }

    function getName() external pure returns (string memory) {
        return "StrategyCurveSCRVv3";
    }

    function getHarvestable() external returns (uint256) {
        return ICurveGauge(gauge).claimable_tokens(address(this));
    }

    function getMostPremiumStablecoin() public view returns (address, uint256) {
        uint256[] memory balances = new uint256[](4);
        balances[0] = ICurveFi(curve).balances(0); // DAI
        balances[1] = ICurveFi(curve).balances(1).mul(10**12); // USDC
        balances[2] = ICurveFi(curve).balances(2).mul(10**12); // USDT
        balances[3] = ICurveFi(curve).balances(3); // sUSD

        // DAI
        if (
            balances[0] < balances[1] &&
            balances[0] < balances[2] &&
            balances[0] < balances[3]
        ) {
            return (dai, 0);
        }

        // USDC
        if (
            balances[1] < balances[0] &&
            balances[1] < balances[2] &&
            balances[1] < balances[3]
        ) {
            return (usdc, 1);
        }

        // USDT
        if (
            balances[2] < balances[0] &&
            balances[2] < balances[1] &&
            balances[2] < balances[3]
        ) {
            return (usdt, 2);
        }

        // SUSD
        if (
            balances[3] < balances[0] &&
            balances[3] < balances[1] &&
            balances[3] < balances[2]
        ) {
            return (susd, 3);
        }

        // If they're somehow equal, we just want DAI
        return (dai, 0);
    }

    // **** Setters ****

    function setDevFundFee(uint256 _devFundFee) external {
        require(msg.sender == governance, "!governance");
        devFundFee = _devFundFee;
    }

    function setTreasuryFee(uint256 _treasuryFee) external {
        require(msg.sender == governance, "!governance");
        treasuryFee = _treasuryFee;
    }

    function setPerformanceFee(uint256 _performanceFee) external {
        require(msg.sender == governance, "!governance");
        performanceFee = _performanceFee;
    }

    function setStrategist(address _strategist) external {
        require(msg.sender == governance, "!governance");
        strategist = _strategist;
    }

    function setGovernance(address _governance) external {
        require(msg.sender == governance, "!governance");
        governance = _governance;
    }

    function setTimelock(address _timelock) external {
        require(msg.sender == timelock, "!timelock");
        timelock = _timelock;
    }

    function setController(address _controller) external {
        require(msg.sender == timelock, "!timelock");
        controller = _controller;
    }

    function setKeepCRV(uint256 _keepCRV) external {
        require(msg.sender == governance, "!governance");
        keepCRV = _keepCRV;
    }

    // **** State Mutations ****

    function deposit() public {
        uint256 _want = IERC20(want).balanceOf(address(this));
        if (_want > 0) {
            IERC20(want).safeApprove(gauge, 0);
            IERC20(want).approve(gauge, _want);
            ICurveGauge(gauge).deposit(_want);
        }
    }

    // Controller only function for creating additional rewards from dust
    function withdraw(IERC20 _asset) external returns (uint256 balance) {
        require(msg.sender == controller, "!controller");
        require(want != address(_asset), "want");
        require(crv != address(_asset), "crv");
        require(snx != address(_asset), "snx");
        require(dai != address(_asset), "dai");
        require(usdc != address(_asset), "usdc");
        require(usdt != address(_asset), "usdt");
        require(susd != address(_asset), "susd");
        balance = _asset.balanceOf(address(this));
        _asset.safeTransfer(controller, balance);
    }

    // Withdraw partial funds, normally used with a jar withdrawal
    function withdraw(uint256 _amount) external {
        require(msg.sender == controller, "!controller");
        uint256 _balance = IERC20(want).balanceOf(address(this));
        if (_balance < _amount) {
            _amount = _withdrawSome(_amount.sub(_balance));
            _amount = _amount.add(_balance);
        }

        uint256 _feeDev = _amount.mul(devFundFee).div(devFundMax);
        IERC20(want).safeTransfer(IController(controller).devfund(), _feeDev);

        uint256 _feeTreasury = _amount.mul(treasuryFee).div(treasuryMax);
        IERC20(want).safeTransfer(
            IController(controller).treasury(),
            _feeTreasury
        );

        address _jar = IController(controller).jars(address(want));
        require(_jar != address(0), "!jar"); // additional protection so we don't burn the funds

        IERC20(want).safeTransfer(_jar, _amount.sub(_feeDev).sub(_feeTreasury));
    }

    // Withdraw all funds, normally used when migrating strategies
    function withdrawAll() external returns (uint256 balance) {
        require(msg.sender == controller, "!controller");
        _withdrawAll();

        balance = IERC20(want).balanceOf(address(this));

        address _jar = IController(controller).jars(address(want));
        require(_jar != address(0), "!jar"); // additional protection so we don't burn the funds
        IERC20(want).safeTransfer(_jar, balance);
    }

    function _withdrawAll() internal {
        ICurveGauge(gauge).withdraw(
            ICurveGauge(gauge).balanceOf(address(this))
        );
    }

    function _withdrawSome(uint256 _amount) internal returns (uint256) {
        ICurveGauge(gauge).withdraw(_amount);
        return _amount;
    }

    function brine() public {
        harvest();
    }

    function harvest() public {
        // Anyone can harvest it at any given time.
        // I understand the possibility of being frontrun
        // But ETH is a dark forest, and I wanna see how this plays out
        // i.e. will be be heavily frontrunned?
        //      if so, a new strategy will be deployed.

        // stablecoin we want to convert to
        (address to, uint256 toIndex) = getMostPremiumStablecoin();

        // Collects crv tokens
        // Don't bother voting in v1
        ICurveMintr(mintr).mint(gauge);
        uint256 _crv = IERC20(crv).balanceOf(address(this));
        if (_crv > 0) {
            // x% is sent back to the rewards holder
            // to be used to lock up in as veCRV in a future date
            uint256 _keepCRV = _crv.mul(keepCRV).div(keepCRVMax);
            if (_keepCRV > 0) {
                IERC20(crv).safeTransfer(
                    IController(controller).treasury(),
                    _keepCRV
                );
            }
            _crv = _crv.sub(_keepCRV);
            _swap(crv, to, _crv);
        }

        // Collects SNX tokens
        ICurveGauge(gauge).claim_rewards(address(this));
        uint256 _snx = IERC20(snx).balanceOf(address(this));
        if (_snx > 0) {
            _swap(snx, to, _snx);
        }

        // Adds liquidity to curve.fi's susd pool
        // to get back want (scrv)
        uint256 _to = IERC20(to).balanceOf(address(this));
        if (_to > 0) {
            IERC20(to).safeApprove(curve, 0);
            IERC20(to).safeApprove(curve, _to);
            uint256[4] memory liquidity;
            liquidity[toIndex] = _to;
            ICurveFi(curve).add_liquidity(liquidity, 0);
        }

        // We want to get back sCRV
        uint256 _want = IERC20(want).balanceOf(address(this));
        if (_want > 0) {
            // Fees 4.5% goes to treasury
            IERC20(want).safeTransfer(
                IController(controller).treasury(),
                _want.mul(performanceFee).div(performanceMax)
            );

            deposit();
        }
    }

    function _swap(
        address _from,
        address _to,
        uint256 _amount
    ) internal {
        // Swap with uniswap
        IERC20(_from).safeApprove(univ2Router2, 0);
        IERC20(_from).safeApprove(univ2Router2, _amount);

        address[] memory path = new address[](3);
        path[0] = _from;
        path[1] = weth;
        path[2] = _to;

        UniswapRouterV2(univ2Router2).swapExactTokensForTokens(
            _amount,
            0,
            path,
            address(this),
            now.add(60)
        );
    }

    // Proxy pattern
    // Implementation is only settable by timelock
    function execute(address _target, bytes memory _data)
        public
        payable
        returns (bytes memory response)
    {
        require(msg.sender == timelock, "!timelock");
        require(_target != address(0), "!target");

        // call contract in current context
        assembly {
            let succeeded := delegatecall(
                sub(gas(), 5000),
                _target,
                add(_data, 0x20),
                mload(_data),
                0,
                0
            )
            let size := returndatasize()

            response := mload(0x40)
            mstore(
                0x40,
                add(response, and(add(add(size, 0x20), 0x1f), not(0x1f)))
            )
            mstore(response, size)
            returndatacopy(add(response, 0x20), 0, size)

            switch iszero(succeeded)
                case 1 {
                    // throw if delegatecall failed
                    revert(add(response, 0x20), size)
                }
        }
    }
}
