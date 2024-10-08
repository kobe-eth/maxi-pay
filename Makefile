-include .env

# Forge Scripts

default:
	forge build

test:
	forge test

production-deployment:
	forge script script/Deploy.s.sol --rpc-url ${ARBNODEURL} --broadcast --etherscan-api-key ${ETHERSCAN_TOKEN} --verify

dryrun-deployment:
	forge script script/Deploy.s.sol --rpc-url ${ARBNODEURL}


.PHONY: default test 