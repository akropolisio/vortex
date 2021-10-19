import pytest
import constants
from brownie import (
    BasisVault,
    BasicERC20,
    TestStrategy,
    accounts,
    network,
    Contract,
    interface,
)


@pytest.fixture(scope="function", autouse=True)
def isolate_func(fn_isolation):
    # perform a chain rewind after completing each test, to ensure proper isolation
    # https://eth-brownie.readthedocs.io/en/v1.10.3/tests-pytest-intro.html#isolation-fixtures
    pass


@pytest.fixture(scope="function", autouse=True)
def token(deployer, users, usdc_whale):
    if network.show_active() == "development":
        toke = BasicERC20.deploy("Test", "TT", {"from": deployer})
        toke.mint(1_000_000_000_000e18, {"from": deployer})
        for user in users:
            toke.mint(1_000_000e18, {"from": user})
    else:
        toke = interface.IERC20(constants.BUSD)
        for user in users:
            toke.transfer(user, constants.DEPOSIT_AMOUNT * 10, {"from": usdc_whale})
    # usdc
    yield toke


@pytest.fixture(scope="function", autouse=True)
def long():
    toke = interface.IERC20(constants.LONG_ASSET)
    yield toke


@pytest.fixture(scope="function", autouse=True)
def oracle():
    oracle = interface.IOracle(constants.MCDEX_ORACLE)
    yield oracle


@pytest.fixture(scope="function", autouse=True)
def mcLiquidityPool():
    mc = interface.IMCLP(constants.MCLIQUIDITY)
    yield mc


@pytest.fixture(scope="function")
def usdc_whale():
    yield accounts.at(constants.BUSD_WHALE, force=True)


@pytest.fixture
def deployer(accounts):
    if network.show_active() == "development":
        yield accounts[0]
    else:
        yield accounts.at(constants.BUSD_WHALE, force=True)


@pytest.fixture
def governance(accounts):
    yield accounts[1]


@pytest.fixture
def users(accounts):
    yield accounts[1:10]


@pytest.fixture(scope="function")
def randy():
    yield accounts.at(constants.RANDOM, force=True)


@pytest.fixture(scope="function")
def vault(deployer, token):
    yield BasisVault.deploy(token, constants.DEPOSIT_LIMIT, {"from": deployer})


@pytest.fixture(scope="function")
def vault_deposited(deployer, token, users, vault):
    for user in users:
        token.approve(vault, constants.DEPOSIT_AMOUNT, {"from": user})
        vault.deposit(constants.DEPOSIT_AMOUNT, user, {"from": user})
    yield vault


@pytest.fixture(scope="function")
def test_strategy(vault, deployer, governance):
    strategy = TestStrategy.deploy(
        constants.LONG_ASSET,
        constants.UNI_POOL,
        vault,
        constants.MCDEX_ORACLE,
        constants.ROUTER,
        governance,
        constants.MCLIQUIDITY,
        constants.PERP_INDEX,
        True,
        {"from": deployer},
    )
    strategy.setBuffer(constants.BUFFER, {"from": deployer})
    vault.setStrategy(strategy, {"from": deployer})
    vault.setProtocolFees(2000, 100, {"from": deployer})
    yield strategy


@pytest.fixture(scope="function")
def test_strategy_deposited(vault_deposited, deployer, governance):
    strategy = TestStrategy.deploy(
        constants.LONG_ASSET,
        constants.UNI_POOL,
        vault_deposited,
        constants.MCDEX_ORACLE,
        constants.ROUTER,
        governance,
        constants.MCLIQUIDITY,
        constants.PERP_INDEX,
        True,
        {"from": deployer},
    )
    strategy.setBuffer(constants.BUFFER, {"from": deployer})
    vault_deposited.setStrategy(strategy, {"from": deployer})
    strategy.setSlippageTolerance(constants.TRADE_SLIPPAGE, {"from": deployer})
    vault_deposited.setProtocolFees(2000, 200, {"from": deployer})
    yield strategy


@pytest.fixture(scope="function")
def test_other_strategy(token, deployer, governance, users):
    vaulty = BasisVault.deploy(token, constants.DEPOSIT_LIMIT, {"from": deployer})
    for user in users:
        token.approve(vaulty, constants.DEPOSIT_AMOUNT, {"from": user})
        vaulty.deposit(constants.DEPOSIT_AMOUNT, user, {"from": user})
    strategy = TestStrategy.deploy(
        constants.LONG_ASSET,
        constants.UNI_POOL,
        vaulty,
        constants.MCDEX_ORACLE,
        constants.ROUTER,
        governance,
        constants.MCLIQUIDITY,
        constants.PERP_INDEX,
        True,
        {"from": deployer},
    )
    strategy.setBuffer(constants.BUFFER, {"from": deployer})
    vaulty.setStrategy(strategy, {"from": deployer})
    strategy.setSlippageTolerance(constants.TRADE_SLIPPAGE, {"from": deployer})
    yield strategy
