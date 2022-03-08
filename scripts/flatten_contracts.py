import sys
from os import path
from brownie import *


def _flattener(contracts_to_flatten):
    for contract_obj in contracts_to_flatten:
        contract_obj.get_verification_info()
        flatten_file_name = path.join(
            "flattened", ".".join([contract_obj._name, "sol"])
        )
        with open(flatten_file_name, "w") as fl_file:
            fl_file.write(contract_obj._flattener.flattened_source)


def main():
    contracts_to_flatten = [
        BasisVault,
        BasisStrategy,
        VaultRegistry,
        Faucet,
        KeeperManager,
    ]
    _flattener(contracts_to_flatten)
