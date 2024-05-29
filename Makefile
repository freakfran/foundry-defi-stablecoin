-include .env

.PHONY: test,svg

#install dependencies
dependencies:
	forge install Cyfrin/foundry-devops --no-commit
	forge install OpenZeppelin/openzeppelin-contracts --no-commit

#install
install:
	forge te $(filter-out $@,$(MAKECMDGOALS)) --no-commit

#forge fmt
fmt:
	@forge fmt

#forge build
build:
	@forge build

.PHONY: test
#forge test
test:
ifdef MT
	@forge test --mt $(MT) -vvvv
else
	@forge test -vvvv
endif

#deploy to sepolia
deploy:
ifeq ($(NET),sepolia)
	forge script script/DeployBasicNft.s.sol --rpc-url $(SEPOLIA_URL) --broadcast --private-key $(SEPOLIA_PRIVATE_KEY) --legacy --verify --etherscan-api-key $(ETHERSCAN_API_KEY) -vvvv
else
	forge script script/DeployBasicNft.s.sol --rpc-url $(GANACHE_URL) --broadcast --private-key $(PRIVATE_KEY) -vvvv
endif

#mint
mint:
ifeq ($(NET),sepolia)
	forge script script/Interactions.s.sol:MintBaseNft --rpc-url $(SEPOLIA_URL) --broadcast --private-key $(SEPOLIA_PRIVATE_KEY) --legacy --verify --etherscan-api-key $(ETHERSCAN_API_KEY) -vvvv
else
	forge script script/Interactions.s.sol:MintBaseNft --rpc-url $(GANACHE_URL) --broadcast --private-key $(PRIVATE_KEY) -vvvv
endif

#convert svg
svg:
	@echo "data:image/svg+xml;base64,"
	@base64 -i img/$(IMG).svg