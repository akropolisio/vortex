import brownie
import constants
import constants_bsc
import random
from brownie import network


def data():
    if network.show_active() == "hardhat-arbitrum-fork":
        constant = constants
    else:
        constant = constants_bsc
    return constant


def test_yield_harvest_withdraw(
    oracle,
    vault_deposited,
    users,
    deployer,
    test_strategy_deposited,
    token,
    long,
    mcLiquidityPool,
):
    test_strategy_deposited.harvest({"from": deployer})
    price = oracle.priceTWAPLong({"from": deployer}).return_value[0]
    whale_buy_long(deployer, token, mcLiquidityPool, price)
    for n in range(100):

        brownie.chain.sleep(28801)
        test_strategy_deposited.harvest({"from": deployer})
        print(test_strategy_deposited.getMarginAccount())

    for n, user in enumerate(users):

        bal_before = token.balanceOf(user)
        to_burn = vault_deposited.balanceOf(user)
        marg_pos_before = test_strategy_deposited.getMarginPositions()
        marg_before = test_strategy_deposited.getMargin()
        long_before = long.balanceOf(test_strategy_deposited)
        tx = vault_deposited.withdraw(
            vault_deposited.balanceOf(user), user, {"from": user}
        )
        assert vault_deposited.balanceOf(user) == 0
        assert token.balanceOf(user) > bal_before
        assert "Withdraw" in tx.events
        assert tx.events["Withdraw"]["user"] == user
        assert tx.events["Withdraw"]["withdrawal"] == (
            token.balanceOf(user) - bal_before
        )
        assert tx.events["Withdraw"]["shares"] == to_burn
        assert (
            test_strategy_deposited.getMarginPositions()
            == test_strategy_deposited.positions()["perpContracts"]
        )
        assert (
            test_strategy_deposited.getMargin()
            == test_strategy_deposited.positions()["margin"]
        )
        assert test_strategy_deposited.getMargin() < marg_before
        assert test_strategy_deposited.getMarginPositions() > marg_pos_before
        assert long.balanceOf(test_strategy_deposited) < long_before
    assert vault_deposited.balanceOf(deployer) > 0
    bal_before = token.balanceOf(deployer)
    test_strategy_deposited.remargin({"from": deployer})
    tx = vault_deposited.withdraw(
        vault_deposited.balanceOf(deployer), deployer, {"from": deployer}
    )
    print(test_strategy_deposited.getMarginAccount())
    assert test_strategy_deposited.getMargin() < marg_before
    assert test_strategy_deposited.getMarginPositions() > marg_pos_before
    assert long.balanceOf(test_strategy_deposited) < long_before
    assert token.balanceOf(test_strategy_deposited) == 0
    if network.show_active() == "hardhat-arbitrum-fork":
        assert token.balanceOf(vault_deposited) == 0
    assert vault_deposited.balanceOf(deployer) == 0
    assert token.balanceOf(deployer) > bal_before
    assert vault_deposited.totalLent() == 0
    assert vault_deposited.totalSupply() == 0


def test_loss_harvest_withdraw(
    oracle,
    vault_deposited,
    users,
    deployer,
    test_strategy_deposited,
    token,
    long,
    mcLiquidityPool,
):

    test_strategy_deposited.harvest({"from": deployer})
    price = oracle.priceTWAPLong({"from": deployer}).return_value[0]
    whale_buy_short(deployer, token, mcLiquidityPool, price)

    for n in range(100):

        brownie.chain.sleep(28801)
        test_strategy_deposited.harvest({"from": deployer})

    for n, user in enumerate(users):

        bal_before = token.balanceOf(user)
        to_burn = vault_deposited.balanceOf(user)
        marg_pos_before = test_strategy_deposited.getMarginPositions()
        marg_before = test_strategy_deposited.getMargin()
        long_before = long.balanceOf(test_strategy_deposited)
        tx = vault_deposited.withdraw(
            vault_deposited.balanceOf(user), user, {"from": user}
        )
        assert vault_deposited.balanceOf(user) == 0
        assert token.balanceOf(user) > bal_before
        assert "Withdraw" in tx.events
        assert tx.events["Withdraw"]["user"] == user
        assert tx.events["Withdraw"]["withdrawal"] == (
            token.balanceOf(user) - bal_before
        )
        assert tx.events["Withdraw"]["shares"] == to_burn
        assert (
            test_strategy_deposited.getMarginPositions()
            == test_strategy_deposited.positions()["perpContracts"]
        )
        assert (
            test_strategy_deposited.getMargin()
            == test_strategy_deposited.positions()["margin"]
        )
        assert test_strategy_deposited.getMargin() < marg_before
        assert test_strategy_deposited.getMarginPositions() > marg_pos_before
        assert long.balanceOf(test_strategy_deposited) < long_before
    if network.show_active() == "hardhat-arbitrum-fork":
        assert vault_deposited.balanceOf(deployer) == 0
    test_strategy_deposited.harvest({"from": deployer})


def test_loss_harvest_remargin(
    oracle,
    vault_deposited,
    users,
    deployer,
    test_strategy_deposited,
    token,
    long,
    mcLiquidityPool,
):
    constant = data()
    test_strategy_deposited.harvest({"from": deployer})
    price = oracle.priceTWAPLong({"from": deployer}).return_value[0]
    whale_buy_short(deployer, token, mcLiquidityPool, price)

    for n in range(100):

        brownie.chain.sleep(28801)
        before_margin = test_strategy_deposited.getMargin()
        before_lent = vault_deposited.totalLent()
        mcLiquidityPool.forceToSyncState({"from": deployer})
        bal = test_strategy_deposited.getMargin() - before_margin
        pps_before = vault_deposited.pricePerShare()
        dep_bal_before = vault_deposited.balanceOf(deployer)
        tx = test_strategy_deposited.harvest({"from": deployer})
        print(test_strategy_deposited.getMarginAccount())
        assert tx.events["Harvest"]["longPosition"] == long.balanceOf(
            test_strategy_deposited
        )
        assert (
            tx.events["Harvest"]["perpContracts"]
            == test_strategy_deposited.getMarginPositions()
        )
        assert tx.events["Harvest"]["margin"] == test_strategy_deposited.getMargin()
        assert (
            abs(
                test_strategy_deposited.getMarginPositions()
                + long.balanceOf(test_strategy_deposited)
            )
            <= constant.ACCURACY_MC
        )
        assert (
            tx.events["Harvest"]["perpContracts"]
            == test_strategy_deposited.positions()["perpContracts"]
        )
        assert (
            test_strategy_deposited.positions()["margin"]
            == test_strategy_deposited.getMargin()
        )
        if network.show_active == "hardhat-arbitrum-fork":
            assert vault_deposited.totalLent() <= before_lent
            assert vault_deposited.balanceOf(deployer) == dep_bal_before
            assert vault_deposited.pricePerShare() <= pps_before

    price = oracle.priceTWAPLong({"from": deployer}).return_value[0]
    bal_before = long.balanceOf(test_strategy_deposited)
    margin_before = test_strategy_deposited.getMargin()
    K = (((constant.MAX_BPS - constant.BUFFER) / 2) * 1e18) / (
        ((constant.MAX_BPS - constant.BUFFER) / 2) + constant.BUFFER
    )
    test_strategy_deposited.setBuffer(100000, {"from": deployer})
    tx = test_strategy_deposited.remargin({"from": deployer})
    Z = tx.events["Remargined"]["unwindAmount"]
    assert "Remargined" in tx.events
    total = (
        long.balanceOf(test_strategy_deposited) * price / 1e18
        + test_strategy_deposited.getMargin()
    )
    l = (
        test_strategy_deposited.getMargin()
        + test_strategy_deposited.getMarginPositions() * price / 1e18
    )
    print("Buffer after remargin: " + str(l / total))
    assert round(l / total, 2) == 100000 / constant.MAX_BPS
    test_strategy_deposited.setBuffer(400000, {"from": deployer})
    tx = test_strategy_deposited.remargin({"from": deployer})
    total = (
        long.balanceOf(test_strategy_deposited) * price / 1e18
        + test_strategy_deposited.getMargin()
    )
    l = (
        test_strategy_deposited.getMargin()
        + test_strategy_deposited.getMarginPositions() * price / 1e18
    )
    assert "Remargined" in tx.events
    total = (
        long.balanceOf(test_strategy_deposited) * price / 1e18
        + test_strategy_deposited.getMargin()
    )
    l = (
        test_strategy_deposited.getMargin()
        + test_strategy_deposited.getMarginPositions() * price / 1e18
    )
    print("Buffer after second remargin: " + str(l / total))
    if network.show_active() == "hardhat-arbitrum-fork":
        assert round(l / total, 2) == 400000 / constant.MAX_BPS
    else:
        assert abs(round(l / total, 2) - 400000 / constant.MAX_BPS) < 0.43

    test_strategy_deposited.harvest({"from": deployer})


def test_harvest_unwind(
    oracle,
    vault_deposited,
    users,
    deployer,
    test_strategy_deposited,
    token,
    long,
    mcLiquidityPool,
):
    test_strategy_deposited.harvest({"from": deployer})
    tx = test_strategy_deposited.unwind({"from": deployer})
    assert "StrategyUnwind" in tx.events
    assert test_strategy_deposited.isUnwind() == True
    assert tx.events["StrategyUnwind"]["positionSize"] == token.balanceOf(
        test_strategy_deposited
    )
    assert test_strategy_deposited.positions()["perpContracts"] == 0
    assert test_strategy_deposited.positions()["margin"] == 0
    tx = test_strategy_deposited.harvest({"from": deployer})
    brownie.chain.sleep(1000000)
    mcLiquidityPool.forceToSyncState({"from": deployer})
    tx = test_strategy_deposited.harvest({"from": deployer})


def test_harvest(
    oracle, vault_deposited, users, deployer, test_strategy_deposited, token, long
):
    constant = data()
    full_deposit = constant.DEPOSIT_AMOUNT * len(users) * constant.DECIMAL_SHIFT
    tx = test_strategy_deposited.harvest({"from": deployer})
    margin_account = test_strategy_deposited.getMarginAccount()
    price = oracle.priceTWAPLong({"from": deployer}).return_value[0]
    assert token.balanceOf(vault_deposited) == 0
    assert token.balanceOf(test_strategy_deposited) == 0
    assert "Harvest" in tx.events
    assert tx.events["Harvest"]["longPosition"] == long.balanceOf(
        test_strategy_deposited
    )
    assert vault_deposited.totalLent() == full_deposit / constant.DECIMAL_SHIFT
    assert (
        abs(margin_account[1] / price + long.balanceOf(test_strategy_deposited) / price)
        <= constant.ACCURACY_USDC
    )
    assert (
        tx.events["Harvest"]["perpContracts"]
        == test_strategy_deposited.getMarginPositions()
        == test_strategy_deposited.positions()["perpContracts"]
    )
    assert (
        tx.events["Harvest"]["margin"]
        == test_strategy_deposited.getMargin()
        == test_strategy_deposited.positions()["margin"]
    )


def test_harvest_deposit_withdraw(
    oracle, vault_deposited, users, deployer, test_strategy_deposited, token, long
):
    constant = data()
    full_deposit = constant.DEPOSIT_AMOUNT * len(users) * constant.DECIMAL_SHIFT
    tx = test_strategy_deposited.harvest({"from": deployer})
    token.approve(vault_deposited, constant.DEPOSIT_AMOUNT, {"from": users[-1]})
    vault_deposited.deposit(constant.DEPOSIT_AMOUNT, users[-1], {"from": users[-1]})
    for n, user in enumerate(users):
        bal_before = token.balanceOf(user)
        to_burn = vault_deposited.balanceOf(user)
        tx = vault_deposited.withdraw(to_burn, user, {"from": user})
        assert vault_deposited.balanceOf(user) == 0
        assert token.balanceOf(user) > bal_before
        assert "Withdraw" in tx.events
        assert tx.events["Withdraw"]["user"] == user
        assert tx.events["Withdraw"]["withdrawal"] == (
            token.balanceOf(user) - bal_before
        )
        assert tx.events["Withdraw"]["shares"] == to_burn
        assert (
            test_strategy_deposited.getMarginPositions()
            == test_strategy_deposited.positions()["perpContracts"]
        )
        assert (
            test_strategy_deposited.getMargin()
            == test_strategy_deposited.positions()["margin"]
        )


def test_yield_harvest(
    oracle,
    vault_deposited,
    users,
    deployer,
    test_strategy_deposited,
    token,
    long,
    mcLiquidityPool,
):
    constant = data()
    test_strategy_deposited.harvest({"from": deployer})
    price = oracle.priceTWAPLong({"from": deployer}).return_value[0]
    whale_buy_long(deployer, token, mcLiquidityPool, price)

    for n in range(100):

        brownie.chain.sleep(28801)
        before_margin = test_strategy_deposited.getMargin()
        before_lent = vault_deposited.totalLent()
        mcLiquidityPool.forceToSyncState({"from": deployer})
        bal = test_strategy_deposited.getMargin() - before_margin
        pps_before = vault_deposited.pricePerShare()
        dep_bal_before = vault_deposited.balanceOf(deployer)
        tx = test_strategy_deposited.harvest({"from": deployer})
        print(test_strategy_deposited.getMarginAccount())
        assert tx.events["Harvest"]["longPosition"] == long.balanceOf(
            test_strategy_deposited
        )
        assert (
            tx.events["Harvest"]["perpContracts"]
            == test_strategy_deposited.getMarginPositions()
        )
        assert tx.events["Harvest"]["margin"] == test_strategy_deposited.getMargin()
        assert vault_deposited.totalLent() > before_lent
        assert (
            abs(
                test_strategy_deposited.getMarginPositions()
                + long.balanceOf(test_strategy_deposited)
            )
            <= constant.ACCURACY_MC
        )
        assert (
            tx.events["Harvest"]["perpContracts"]
            == test_strategy_deposited.positions()["perpContracts"]
        )
        assert (
            test_strategy_deposited.positions()["margin"]
            == test_strategy_deposited.getMargin()
        )
        assert vault_deposited.balanceOf(deployer) > dep_bal_before
        assert vault_deposited.pricePerShare() > pps_before


def test_loss_harvest(
    oracle,
    vault_deposited,
    users,
    deployer,
    test_strategy_deposited,
    token,
    long,
    mcLiquidityPool,
):
    constant = data()
    test_strategy_deposited.harvest({"from": deployer})
    price = oracle.priceTWAPLong({"from": deployer}).return_value[0]
    whale_buy_short(deployer, token, mcLiquidityPool, price)

    for n in range(100):

        brownie.chain.sleep(28801)
        before_margin = test_strategy_deposited.getMargin()
        before_lent = vault_deposited.totalLent()
        mcLiquidityPool.forceToSyncState({"from": deployer})
        bal = test_strategy_deposited.getMargin() - before_margin
        pps_before = vault_deposited.pricePerShare()
        dep_bal_before = vault_deposited.balanceOf(deployer)
        tx = test_strategy_deposited.harvest({"from": deployer})
        assert tx.events["Harvest"]["longPosition"] == long.balanceOf(
            test_strategy_deposited
        )
        assert (
            tx.events["Harvest"]["perpContracts"]
            == test_strategy_deposited.getMarginPositions()
        )
        assert tx.events["Harvest"]["margin"] == test_strategy_deposited.getMargin()
        # assert vault_deposited.totalLent() <= before_lent
        assert (
            abs(
                test_strategy_deposited.getMarginPositions()
                + long.balanceOf(test_strategy_deposited)
            )
            <= constant.ACCURACY_MC
        )
        assert (
            tx.events["Harvest"]["perpContracts"]
            == test_strategy_deposited.positions()["perpContracts"]
        )
        assert (
            test_strategy_deposited.positions()["margin"]
            == test_strategy_deposited.getMargin()
        )
        if network.show_active() == "hardhat-arbitrum-fork":
            assert vault_deposited.balanceOf(deployer) == dep_bal_before
            assert vault_deposited.pricePerShare() <= pps_before


def test_harvest_withdraw_all(
    oracle, vault, users, deployer, test_strategy, token, long
):
    constant = data()
    user = users[0]
    token.approve(vault, constant.DEPOSIT_AMOUNT, {"from": user})
    vault.deposit(constant.DEPOSIT_AMOUNT, user, {"from": user})
    test_strategy.harvest({"from": deployer})
    bal_before = token.balanceOf(user)
    to_burn = vault.balanceOf(user)
    tx = vault.withdraw(to_burn, user, {"from": user})
    assert token.balanceOf(user) - bal_before <= constant.DEPOSIT_AMOUNT
    assert vault.totalLent() == 0
    assert long.balanceOf(test_strategy) == 0
    assert "Withdraw" in tx.events
    assert tx.events["Withdraw"]["user"] == user
    assert tx.events["Withdraw"]["withdrawal"] == (token.balanceOf(user) - bal_before)
    assert tx.events["Withdraw"]["shares"] == to_burn
    assert test_strategy.positions()["perpContracts"] == 0
    assert test_strategy.positions()["margin"] == 0


def test_harvest_withdraw(
    oracle, vault_deposited, users, deployer, test_strategy_deposited, token, long
):
    test_strategy_deposited.harvest({"from": deployer})
    for n, user in enumerate(users):
        bal_before = token.balanceOf(user)
        to_burn = vault_deposited.balanceOf(user)
        marg_pos_before = test_strategy_deposited.getMarginPositions()
        marg_before = test_strategy_deposited.getMargin()
        long_before = long.balanceOf(test_strategy_deposited)
        tx = vault_deposited.withdraw(to_burn, user, {"from": user})
        assert vault_deposited.balanceOf(user) == 0
        assert token.balanceOf(user) > bal_before
        assert "Withdraw" in tx.events
        assert tx.events["Withdraw"]["user"] == user
        assert tx.events["Withdraw"]["withdrawal"] == (
            token.balanceOf(user) - bal_before
        )
        assert tx.events["Withdraw"]["shares"] == to_burn
        assert (
            test_strategy_deposited.positions()["perpContracts"]
            == test_strategy_deposited.getMarginPositions()
        )
        assert (
            test_strategy_deposited.positions()["margin"]
            == test_strategy_deposited.getMargin()
        )
        assert test_strategy_deposited.getMargin() < marg_before
        assert test_strategy_deposited.getMarginPositions() > marg_pos_before
        assert long.balanceOf(test_strategy_deposited) < long_before
    assert vault_deposited.totalLent() == 0
    assert test_strategy_deposited.getMarginPositions() == 0
    assert long.balanceOf(test_strategy_deposited) == 0
    assert test_strategy_deposited.positions()["perpContracts"] == 0
    assert test_strategy_deposited.positions()["margin"] == 0


def test_harvest_emergency_exit(
    governance,
    oracle,
    vault_deposited,
    users,
    deployer,
    test_strategy_deposited,
    token,
    long,
):
    tx = test_strategy_deposited.harvest({"from": deployer})
    gov_bal = token.balanceOf(governance)
    tx = test_strategy_deposited.emergencyExit({"from": governance})
    assert "EmergencyExit" in tx.events
    assert test_strategy_deposited.isUnwind() == True
    assert (
        token.balanceOf(governance)
        == tx.events["EmergencyExit"]["positionSize"] + gov_bal
    )


def whale_buy_long(deployer, token, mcLiquidityPool, price):
    constant = data()
    if network.show_active() == "hardhat-arbitrum-fork":
        if mcLiquidityPool.getMarginAccount(0, deployer)[0] == 0:
            token.approve(
                mcLiquidityPool, token.balanceOf(deployer), {"from": deployer}
            )
            mcLiquidityPool.setTargetLeverage(0, deployer, 1e18, {"from": deployer})
            mcLiquidityPool.deposit(
                0,
                deployer,
                (token.balanceOf(deployer) * constant.DECIMAL_SHIFT - 1),
                {"from": deployer},
            )
        mcLiquidityPool.trade(
            0,
            deployer,
            ((mcLiquidityPool.getMarginAccount(0, deployer)[3] / 100) * 1e18) / price,
            price,
            brownie.chain.time() + 10000,
            deployer,
            0x40000000,
            {"from": deployer},
        )
    else:
        if mcLiquidityPool.getMarginAccount(1, deployer)[0] == 0:
            token.approve(
                mcLiquidityPool, token.balanceOf(deployer), {"from": deployer}
            )
            mcLiquidityPool.setTargetLeverage(1, deployer, 1e18, {"from": deployer})
            mcLiquidityPool.deposit(
                1,
                deployer,
                (token.balanceOf(deployer) * constant.DECIMAL_SHIFT - 1),
                {"from": deployer},
            )
        mcLiquidityPool.trade(
            1,
            deployer,
            ((mcLiquidityPool.getMarginAccount(1, deployer)[3] / 100) * 1e18) / price,
            # ((2_800_000) * 1e18) / price,
            price,
            brownie.chain.time() + 10000,
            deployer,
            0x40000000,
            {"from": deployer},
        )


def whale_buy_short(deployer, token, mcLiquidityPool, price):
    constant = data()
    if network.show_active() == "hardhat-arbitrum-fork":

        if mcLiquidityPool.getMarginAccount(0, deployer)[0] == 0:
            token.approve(
                mcLiquidityPool, token.balanceOf(deployer), {"from": deployer}
            )
            mcLiquidityPool.setTargetLeverage(0, deployer, 1e18, {"from": deployer})
            mcLiquidityPool.deposit(
                0,
                deployer,
                (token.balanceOf(deployer) * constant.DECIMAL_SHIFT - 1),
                {"from": deployer},
            )
        mcLiquidityPool.trade(
            0,
            deployer,
            -((mcLiquidityPool.getMarginAccount(0, deployer)[3] / 100) * 1e18) / price,
            price,
            brownie.chain.time() + 10000,
            deployer,
            0x40000000,
            {"from": deployer},
        )
    else:
        if mcLiquidityPool.getMarginAccount(1, deployer)[0] == 0:
            token.approve(
                mcLiquidityPool, token.balanceOf(deployer), {"from": deployer}
            )
            mcLiquidityPool.setTargetLeverage(1, deployer, 1e18, {"from": deployer})
            mcLiquidityPool.deposit(
                1,
                deployer,
                (token.balanceOf(deployer) * constant.DECIMAL_SHIFT - 1),
                {"from": deployer},
            )
        mcLiquidityPool.trade(
            1,
            deployer,
            -((mcLiquidityPool.getMarginAccount(1, deployer)[3] / 100) * 1e18) / price,
            # -((2_800_000) * 1e18) / price,
            price,
            brownie.chain.time() + 10000,
            deployer,
            0x40000000,
            {"from": deployer},
        )
