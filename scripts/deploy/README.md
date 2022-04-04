## Add deployer account to brownie

- Import a private key
  ```bash
  $ brownie accounts new vortex_deployer
  ```
- Or import a .json keystore
  ```bash
  $ brownie accounts import vortex_deployer keystore.json
  ```

## Scripts

### deploy/0_deploy_utils.py

Deploys CreateCall contract and saves address in `addresses/{chain.id}/utils.json`

- use `default` Python environment + `ganache`
- use production network (not fork)
- run script
  ```bash
  brownie run deploy/0_deploy_utils.py --network arbitrum-main
  ```

### deploy/1_deploy_contracts.py

Creates transaction in Gnosis Safe to deploy VaultsRegistry (if needed), KeeperManager (if needed), BasisVault and BasisStrategy

- use `ape_safe` Python environment + `ganache-cli`
- use fork network
- configure deployment in `config/{chain.id}/deploy.json`
- add `gnosis_safe` addresses to `addresses/{chain.id}/utils.json`
- if `deploy_config['use_alchemy_keeper'] == True`
  - add `upkeep_registry` addresses to `addresses/{chain.id}/utils.json`. You can find registry address [here](https://keepers.chain.link/)
- run script
  ```bash
  brownie run deploy/1_deploy_contracts.py --network arbitrum-main-fork
  ```

### deploy/2_verify_contracts.py

Adds VaultRegistry and KeeperManager addresses to `addresses/{chain.id}/utils.json`, adds BasisVault and BasisStrategy addresses to `addresses/{chain.id}/vaults.json`, tries to verify contracts, displays instructions for manual verification if automatic verification is not available

- use `default` Python environment + `ganache`
- use production network (not fork)
- don't change anything in `addresses/{chain.id}/utils.json` and `config/{chain.id}/deploy.json`
- set tx hash of confirmed Gnosis Safe transaction (`DEPLOY_TX_HASH`) in `scripts/deploy/2_verify_contracts.py`
- run script
  ```bash
  brownie run deploy/2_verify_contracts.py --network arbitrum-main
  ```

### deploy/3_initialize_contracts.py

Initializes the VaultRegistry and last deployed BasisVault and BasisStrategy

- use `ape_safe` Python environment + `ganache-cli`
- use fork network
- don't change anything in `addresses/{chain.id}/utils.json` and `config/{chain.id}/deploy.json`
- run script
  ```bash
  brownie run deploy/3_initialize_contracts.py --network arbitrum-main-fork
  ```

## Switch environments

### Python virtual environments

- activate `default` environment
  ```bash
  source venvs/default/bin/activate
  ```
- activate `ape_safe` environment
  ```bash
  source venvs/ape_safe/bin/activate
  ```

### Ganache versions

- switch to `ganache-cli`
  - install `ganache-cli`
    ```bash
    make switch-to-ganache-cli
    ```
  - use `ganache-cli` instead of `ganache` in `network-config.yaml`
  - update brownie networks
    ```bash
    brownie networks import network-config.yaml true
    ```
- switch to `ganache`
  - install `ganache`
    ```bash
    make switch-to-ganache
    ```
  - use `ganache` instead of `ganache-cli` in `network-config.yaml`
  - update brownie networks
    ```bash
    brownie networks import network-config.yaml true
    ```