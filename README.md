# Archetype Contracts

Solidity contracts for Scatter's NFT launchpad and marketplace.

## Source and verification

The published launchpad and marketplace contracts mirror Scatter monorepo commit `271351d7685816838cfa5a5faf93a863ec5638b2` on `master`. Legacy `BURGERS404` contracts retain their previously published v0.8.0 versions. This is not a statement that every contract is deployed on every chain.

Use Foundry 1.8.0 to run the self-contained contract tests:

```sh
git submodule update --init --recursive
forge build
forge test
```

Deployment scripts, deployment tests, and RPC-dependent fork tests remain in the monorepo.

## Licensing

Creator-deployed implementations, logic libraries, interfaces, test helpers, and tests are available under the MIT License in `LICENSES/MIT.txt`.

Scatter-operated contracts, including Batch, Payouts, Factory, registry, and marketplace contracts, are available under the Business Source License 1.1 in `LICENSES/BUSL-1.1.txt`. Each Solidity file's SPDX identifier is authoritative. BUSL-1.1 versions change to the MIT License four years after publication.

## Security

Report vulnerabilities privately through [GitHub Security Advisories](https://github.com/guminc/archetype/security/advisories/new). Do not open a public issue for an undisclosed vulnerability.
